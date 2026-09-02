import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "Model.js" as Model

// Applies the configuration at session start and puts it back after a config
// reload. Touches no file of the user's Hyprland configuration: under the Lua
// configuration `hyprctl keyword` is off, and a require line in hyprland.lua
// would not survive the next Omarchy upgrade.
Item {
    id: root

    Runners { id: run }

    property var model: ({ programs: [], workspaces: [] })
    property var rejected: []
    // Contradictions validate() can see (two programs of the same class
    // wanting different placements) -- see the block below that stops on
    // this, not on rejected.
    property var blocked: []
    property string lastError: ""

    // Every call into load() belongs to a run, and a run started later
    // invalidates an earlier one's callbacks. Without this, a config
    // reload landing mid-startup -- `configreloaded` fires on every config
    // save, and Omarchy's own migrations call `hyprctl reload` too, not
    // only the user -- would let two chains of callbacks share the same
    // Process objects and stomp on each other: the reset chunk that always
    // opens buildRuleChunks()'s output could land AFTER an earlier run's
    // rule chunks instead of before them, silently switching every rule
    // back off. The pending-chunk state belongs to the run context object
    // (ctx) passed through the chain below, not to this component,
    // precisely so an old run's leftover callback has its own copy to
    // read -- and the ctx.gen check in every handler still refuses to act
    // once a newer run exists, even reading its own copy.
    property int generation: 0

    // Session start (the claim + the launch) is a SEPARATE obligation from
    // "apply the rules", and generation is the wrong thing to carry it:
    // generation identifies the latest run, but a run that gets superseded
    // before it ever reaches claimAndLaunch must not take the obligation
    // down with it -- its successor has to pick it up, or the user's
    // programs never start for the whole session, exactly the original
    // defect this plugin exists to prevent. True until a claim attempt has
    // actually RUN and reported a real (not watchdog-killed) result --
    // see markerProc.onExited, which is the only place this turns false.
    property bool sessionStartOwed: true

    // Quickshell exposes no error signal for a Process, so one that never
    // emits `exited` -- a bad binDir resolution, a hung producer, an
    // environment where a `/usr/bin/...` tool is simply missing -- would
    // otherwise strand a run forever with no visible symptom. This does not
    // try to be clever about which Process is stuck; it stops all four for
    // the run in flight and reports once. Restarted on every load() and
    // cancelled at every point a run actually finishes, below.
    //
    // The kill itself must ALSO retire the run it just killed: bumping
    // generation first means every one of these four Processes' OWN
    // `onExited`/`onStreamFinished` -- which WILL still fire once each
    // process actually dies -- reads a ctx whose .gen no longer matches
    // root.generation, and returns immediately instead of resuming the
    // sequence it was just told to abandon. Before this, a killed evalProc
    // still called nextChunk(ctx), which still saw pendingIndex short of
    // pendingChunks.length (or fast-forwarded, but lastError already set,
    // which does not stop nextChunk itself) and carried on through
    // claimAndLaunch/launchAll -- the watchdog resuming the very sequence
    // it exists to end.
    readonly property int watchdogSeconds: 30
    Timer {
        id: watchdog
        interval: root.watchdogSeconds * 1000
        repeat: false
        onTriggered: {
            root.generation += 1
            root.lastError = "the apply sequence did not finish within "
                            + root.watchdogSeconds + "s -- a Process may be stuck"
            readProc.running = false
            evalProc.running = false
            markerProc.running = false
            launchProc.running = false
        }
    }

    Component.onDestruction: {
        readProc.running = false
        evalProc.running = false
        launchProc.running = false
        markerProc.running = false
    }

    Component.onCompleted: root.load()

    // Whether readProc is between being dispatched and its OWN onExited
    // firing for that dispatch. load() must never reassign runCtx/command
    // on a Process while this is true: a stale signal already queued for
    // the CURRENT dispatch would then be delivered after the reassignment
    // and read the NEW ctx, passing the ctx.gen check meant to catch it --
    // reachable exactly here, because load() is the one place that used to
    // stop and immediately re-dispatch the same Process in a single
    // synchronous block. Set true only in dispatchRead(), set false only
    // in readProc.onExited -- the actual terminal signal for a dispatch,
    // not merely "we asked it to stop".
    property bool readBusy: false
    // A load() that arrived while readBusy is true. readProc.onExited
    // consumes this once the in-flight dispatch has genuinely finished, so
    // the newer request is never dropped and never reassigned early.
    property var pendingLoad: null

    function load() {
        root.generation += 1
        var gen = root.generation
        root.lastError = ""
        watchdog.stop()
        watchdog.start()

        if (root.readBusy) {
            // Do not touch readProc.runCtx/command/running here -- it may
            // still emit one more signal for its CURRENT dispatch, and
            // reassigning now is exactly the F3(a) race. Ask it to stop and
            // let its own onExited hand off to this request once it is
            // genuinely free.
            root.pendingLoad = { gen: gen }
            readProc.running = false
            return
        }

        // evalProc/markerProc/launchProc are never re-dispatched from here
        // in the same synchronous block -- only readProc is, immediately
        // below -- so stopping them here and letting the FRESH readProc
        // cycle (a real subprocess round trip) reach them later leaves any
        // already-queued signal from their previous dispatch ample time to
        // arrive and be rejected by its own (still unchanged) ctx.gen
        // check before either Process is touched again.
        evalProc.running = false
        markerProc.running = false
        launchProc.running = false
        root.dispatchRead(gen)
    }

    function dispatchRead(gen) {
        root.readBusy = true
        var ctx = { gen: gen, rulesOnly: !root.sessionStartOwed, pendingChunks: [], pendingIndex: 0 }
        readProc.runCtx = ctx
        readProc.command = run.tool("omarchy-autostart-config", "read")
        readProc.running = true
    }

    Process {
        id: readProc
        property var runCtx: null
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var ctx = readProc.runCtx
                if (!ctx || ctx.gen !== root.generation) return

                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) {
                    root.lastError = "unreadable answer from the config reader"
                    watchdog.stop()
                    return
                }

                // Fail closed. A broken structure does not say what the user
                // wants -- no rule is better than half of one.
                if (!envelope.ok) {
                    root.lastError = String(envelope.error || "unknown") + ": "
                                   + String(envelope.detail || "")
                    watchdog.stop()
                    return
                }
                var checked = Model.validate(envelope.config)
                root.model = checked
                root.rejected = checked.rejected

                // A class conflict is a contradiction this code can see --
                // two programs of the same class wanting different places --
                // and applying anyway would pick a silent winner inside the
                // compositor. rejected is the other case: a named, visible
                // omission with the rest still applied. blocked stops the
                // whole apply instead -- sessionStartOwed is left untouched,
                // so a LATER run (once the user fixes the conflict) still
                // attempts the claim and launch this one never reached.
                if (checked.blocked && checked.blocked.length > 0) {
                    root.blocked = checked.blocked
                    root.lastError = "configuration blocked: " + checked.blocked.length
                                    + " conflicting placement(s) -- see blocked"
                    watchdog.stop()
                    return
                }
                root.blocked = []
                root.applyRules(ctx, checked)
            }
        }
        onExited: function(exitCode, exitStatus) {
            // The terminal signal for THIS dispatch, regardless of whether
            // it was stale (ctx.gen mismatch, handled above and in the
            // callers of this Process) -- readBusy comes down unconditionally
            // so a queued load() is never stuck waiting on a dispatch that
            // has, in fact, already finished.
            root.readBusy = false
            if (root.pendingLoad) {
                var p = root.pendingLoad
                root.pendingLoad = null
                evalProc.running = false
                markerProc.running = false
                launchProc.running = false
                root.dispatchRead(p.gen)
            }
        }
    }

    function applyRules(ctx, checked) {
        try { ctx.pendingChunks = Model.buildRuleChunks(checked) }
        catch (e) { root.lastError = String(e.message); watchdog.stop(); return }
        ctx.pendingIndex = 0
        root.nextChunk(ctx)
    }

    function nextChunk(ctx) {
        if (ctx.gen !== root.generation) return
        if (ctx.pendingIndex >= ctx.pendingChunks.length) {
            // Reached even after a rule chunk failed above (pendingIndex
            // was fast-forwarded to the end, see evalProc below): a mistake
            // in the PLACEMENT rules should not also stop the user's
            // programs from starting. ctx.rulesOnly reflects whether
            // session start was already owed when THIS run was dispatched
            // (see dispatchRead) -- not whether this run happens to be a
            // reload, so a startup run that gets superseded before this
            // point still leaves the obligation for its successor.
            if (!ctx.rulesOnly) root.claimAndLaunch(ctx)
            else watchdog.stop()
            return
        }
        var payload = ctx.pendingChunks[ctx.pendingIndex]
        evalProc.runCtx = ctx
        // The verb is Model.verbFor's call, not an inline comparison here --
        // Model.js documents why: the two verbs are not interchangeable and
        // keeping the decision in one tested function is the whole reason a
        // caller like this one does not carry it as its own string check.
        evalProc.command = run.hypr(Model.verbFor(payload), payload)
        ctx.pendingIndex += 1
        evalProc.running = true
    }

    Process {
        id: evalProc
        property var runCtx: null
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var ctx = evalProc.runCtx
                if (!ctx || ctx.gen !== root.generation) return
                // hyprctl answers "ok" when the Lua chunk PARSED AND RAN
                // without a Lua error -- a syntax-level guarantee only. The
                // project's own probe recorded the "ok" fallacy
                // (test/probe-hyprland-api.sh): hyprctl answered "ok" for a
                // dispatch that had no visible effect at all. So "ok" here
                // confirms the chunk was accepted, never that any rule
                // inside it actually applies. Anything else DOES mean the
                // chunk did not run, and that is still worth stopping for:
                // pendingIndex is fast-forwarded past the remaining chunks
                // so no FURTHER chunk is sent, but chunks already sent are
                // not rolled back -- this bounds how much more gets out of
                // sync, it is not an all-or-nothing guarantee.
                if (String(text || "").trim() !== "ok") {
                    root.lastError = "hyprctl eval refused a rule block"
                    ctx.pendingIndex = ctx.pendingChunks.length
                }
            }
        }
        onExited: function(exitCode, exitStatus) {
            var ctx = evalProc.runCtx
            if (!ctx || ctx.gen !== root.generation) return
            if (exitCode !== 0 && root.lastError === "") {
                root.lastError = "hyprctl eval exited " + exitCode
                ctx.pendingIndex = ctx.pendingChunks.length
            }
            root.nextChunk(ctx)
        }
    }

    function claimAndLaunch(ctx) {
        markerProc.runCtx = ctx
        markerProc.command = run.tool("omarchy-autostart-marker", "claim")
        markerProc.running = true
    }

    Process {
        id: markerProc
        property var runCtx: null
        onExited: function(exitCode, exitStatus) {
            var ctx = markerProc.runCtx
            if (!ctx || ctx.gen !== root.generation) return
            // Qt documents exitCode as meaningful only when exitStatus is a
            // NORMAL exit -- a process killed by a signal (the watchdog, or
            // a superseded generation stopping it) can still report an
            // exitCode of 0 from whatever partial state it was in when
            // killed, which would read as a GRANTED claim it never actually
            // made. The marker fails closed by design
            // (bin/omarchy-autostart-marker); this reader must not undo
            // that by trusting a code that is not meaningful here.
            //
            // NormalExit's exact QML spelling in the installed Quickshell.Io
            // API is UNVERIFIED from here (nothing in this tree can load
            // Quickshell.Io) -- 0 is QProcess::NormalExit's numeric value,
            // which Quickshell.Io's Process is modelled on; confirm the
            // named form resolves (or fall back to the literal 0) on the
            // manual checklist.
            if (exitStatus !== Process.NormalExit) {
                // Not a real attempt: the claim's actual outcome is
                // unknown, so sessionStartOwed stays true and the next run
                // retries it instead of silently skipping session start.
                return
            }
            root.sessionStartOwed = false
            if (exitCode === 0) root.launchAll(ctx)
            else watchdog.stop()
        }
    }

    function launchAll(ctx) {
        var programs = root.model.programs || []
        var commands = []
        for (var i = 0; i < programs.length; i++) {
            if (programs[i].enabled) commands.push(Model.launchCommand(programs[i].command))
        }
        if (commands.length === 0) { watchdog.stop(); return }
        // Each entry gets its own `bash -c`, and that is not a stylistic
        // choice. bash parses a whole line before it runs any of it, so with
        // every entry on one line a single malformed command would stop the
        // ENTIRE autostart -- the user logs in to an empty desktop and a
        // syntax error on stderr. Measured:
        //   all entries on one line:  syntax error -> nothing ran
        //   one bash -c per entry:    the good ones ran, only the bad reported
        //
        // Each entry is ALSO detached with `setsid -f`, and the outer shell
        // is launched through Runners.launcher(), not Runners.runner(): a
        // bare `timeout` puts its own child in a NEW process group and, at
        // the deadline, signals the WHOLE group -- reaching every program
        // this wrapper started, not just itself. Measured, two long-lived
        // backgrounded grandchildren: 0 of 2 survived the deadline without
        // `--foreground`, 2 of 2 with it. `--foreground` alone does not
        // cover a teardown of THIS Process (Component.onDestruction, or a
        // superseded generation, both call launchProc.running = false):
        // measured against a group-wide signal to the wrapper's own process
        // group (the realistic shape of that teardown, not a signal to one
        // pid), `--foreground` alone still lost 0 of 2, while `setsid -f`
        // -- alone or combined -- kept 2 of 2, because a detached entry is
        // no longer a member of any group the wrapper's own group-wide
        // signal reaches. Both are kept: `--foreground` for the deadline,
        // `setsid -f` for the teardown, matching what each was actually
        // measured to fix.
        //
        // "One short-lived process per program" was the wrong way to
        // describe this: what actually keeps `wait` from blocking on the
        // programs themselves is `setsid -f` forking and handing off -- the
        // TRACKED job exits once the program is launched, not once the
        // program quits.
        //
        // The redirection at the end of each entry -- `</dev/null >/dev/null
        // 2>&1` on the `setsid` invocation ITSELF, not only inside
        // launchCommand's own `{ ... }` group -- exists because launchCommand
        // only redirects the INNER compound command, never the `bash`
        // process in front of it. Without this, the fork+exec chain between
        // `setsid -f` and that inner group briefly (and, for the LIFETIME of
        // whatever it execs into, not briefly at all) keeps a copy of this
        // wrapper's own stdout/stderr open -- measured, an 8 s stand-in
        // program: wrapper process exits at 0 s, but stderr EOF (what
        // launchProc's own StdioCollector is waiting for) does not arrive
        // until 8 s, i.e. for as long as the program the entry started keeps
        // running. With `waitForEnd: true` below, that meant `exited` itself
        // waited on stream completion, so watchdog.stop() at the bottom of
        // launchProc's onExited was never reached until the LAST launched
        // program quit -- the 30 s watchdog firing a false error on every
        // login. Redirecting the `setsid` invocation's own stdio closes the
        // gap: measured, the same shape now shows stderr EOF at 0 s, and a
        // deliberate syntax error in the OUTER line (this wrapper's own
        // construction, not the entry's inner group) still reaches stderr
        // unaffected, because that redirection is per-entry, not on the
        // outer `bash -c '... & ... & wait'` this wrapper itself runs.
        var isolated = []
        for (var j = 0; j < commands.length; j++) {
            isolated.push(run.binSetsid + " -f " + run.binBash + " -c "
                        + Model.shellQuote(commands[j]) + " </dev/null >/dev/null 2>&1")
        }
        launchProc.runCtx = ctx
        launchProc.command = run.launcher(isolated.join(" & ") + " & wait")
        launchProc.running = true
    }

    Process {
        id: launchProc
        property var runCtx: null
        // waitForEnd stays true: with every entry's own stdio now
        // redirected away from this wrapper (see launchAll), the stream
        // reaches EOF as soon as the OUTER wrapper line itself finishes --
        // measured at 0 s, not gated on any launched program's lifetime any
        // more -- so this still reliably captures a genuine error from the
        // wrapper's OWN construction (a bad isolated.join(), a shellQuote
        // bug) without re-introducing the hang N3 fixed. What a user can
        // still see on this stream: any such outer-wrapper-level error.
        // What stays dropped, unchanged from before this round and by
        // launchCommand's own explicit design: each entry's OWN command's
        // stdout/stderr (the launched application's own output), which
        // launchCommand redirects to /dev/null on purpose so that
        // Quickshell tearing down ITS pipes can never reach the
        // application through them.
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var ctx = launchProc.runCtx
                if (!ctx || ctx.gen !== root.generation) return
                var message = String(text || "").trim()
                if (message !== "") root.lastError = message.split("\n").pop()
            }
        }
        onExited: function(exitCode, exitStatus) {
            var ctx = launchProc.runCtx
            if (!ctx || ctx.gen !== root.generation) return
            watchdog.stop()
        }
    }

    // hyprctl reload is not only something a user can run by hand --
    // Omarchy's own migrations call it too -- and it throws every runtime
    // rule away. This puts them back: rules only, never the programs, UNLESS
    // sessionStartOwed says an earlier run never got that far -- see
    // dispatchRead(). load()'s generation guard above is what keeps a
    // reload landing mid-startup from corrupting the run already in flight
    // instead of cleanly superseding it.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (String(event.name) === "configreloaded") root.load()
        }
    }
}
