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
    // THE WATCHDOG IS THE SECOND RELEASE PATH for both busy flags and both
    // pending slots -- onExited is the other, and the invariant below no
    // longer implies it is the only one. It has to be: a Process that never
    // emits `exited` is precisely the case this Timer exists for (Qt emits
    // no `finished()` on a FAILED START, and quickshell-io.qmltypes exposes
    // no error signal, so this is reachable, not theoretical), and a busy
    // flag that only its own onExited can clear would then stay true for the
    // rest of the session: every later load() would return at the readBusy
    // branch and the configuration would never be read again -- a permanent,
    // silent, total failure. So onTriggered clears readBusy/evalBusy and
    // discards pendingLoad/pendingChunkRun alongside the generation bump.
    //
    // Accepted residual, recorded rather than left implied: a Process that
    // was merely SLOW (not failed-to-start) does eventually emit `exited`
    // after `running = false` here. If a fresh load() re-dispatches that same
    // Process in the window before that queued signal is delivered, the stale
    // onExited clears the NEW dispatch's busy flag early -- narrowly
    // re-opening the reassignment window the flag exists to close. No
    // per-dispatch token can close it, because a QML signal handler can only
    // read the Process's CURRENT runCtx, never the one its own dispatch
    // carried. The trade is deliberate: a one-tick window for a reassignment
    // race, against a session-long total failure.
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
            // Release both queues. See the block comment above for why the
            // watchdog has to be a release path and what that costs.
            root.readBusy = false
            root.pendingLoad = null
            root.evalBusy = false
            root.pendingChunkRun = null
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

    // THE INVARIANT: one Process never carries two runs. A Process must
    // never have its runCtx/command reassigned while it may still emit one
    // more signal for a dispatch already in flight -- a stale signal
    // delivered after such a reassignment would read the NEW ctx and pass
    // the ctx.gen check meant to catch it. Two Processes enforce this
    // MECHANICALLY, with a busy flag plus a one-slot pending-request queue
    // that only the Process's own terminal signal (onExited, never merely
    // "we asked it to stop") is allowed to consume -- with exactly one other
    // release path, the watchdog's onTriggered, for the Process that never
    // emits that signal at all; see the watchdog comment above for why that
    // path exists and what it costs:
    //   - readProc: readBusy / pendingLoad, below.
    //   - evalProc: evalBusy / pendingChunkRun, near nextChunk() -- made
    //     mechanical in round 3 because it carries pendingIndex across a
    //     multi-step sequence, so a stale callback reassigned onto a NEWER
    //     ctx would not just be rejected, it would silently advance the
    //     WRONG ctx's pendingIndex: the shape in which resetChunk() (always
    //     chunk 0) lands after the rule chunks instead of before them,
    //     every rule silently switched off, no error anywhere.
    // markerProc and launchProc REST ON A TIMING ARGUMENT instead, recorded
    // here as an accepted assumption rather than left implied: each is only
    // ever reassigned after a full, real subprocess round trip through a
    // freshly (and by-then mechanically) dispatched readProc/evalProc
    // cycle, and any signal already queued for either at the moment it was
    // stopped is, in every realistic event-loop implementation, delivered
    // on the very next tick -- long before that round trip completes -- so
    // it is rejected by its own (still unchanged) ctx.gen check before
    // either Process is reassigned. This holds because the round trip
    // outlasts a queued signal's delivery, not because anything prevents
    // the reassignment; both carry only a single dispatch per run (no
    // pendingIndex-like state to corrupt), and the ctx.gen check plus
    // sessionStartOwed bound the outcome either way even if the timing
    // assumption were ever wrong.
    property bool readBusy: false
    // A load() that arrived while readBusy is true. readProc.onExited
    // consumes this once the in-flight dispatch has genuinely finished, so
    // the newer request is never dropped and never reassigned early.
    // requestedAtGen is a RECORD of which run queued it, for diagnosis only
    // -- never the generation the retry is dispatched under; see
    // readProc.onExited for why the retry re-enters through load() instead.
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
            root.pendingLoad = { requestedAtGen: gen }
            readProc.running = false
            return
        }

        // markerProc/launchProc are never re-dispatched from here in the
        // same synchronous block -- only readProc is, immediately below --
        // so stopping them here and letting the FRESH readProc cycle (a
        // real subprocess round trip) reach them later leaves any
        // already-queued signal from their previous dispatch ample time to
        // arrive and be rejected by its own (still unchanged) ctx.gen
        // check before either Process is touched again. See the invariant
        // comment above for why this is accepted for these two and made
        // mechanical instead for evalProc.
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
                // Re-enter through load(), NOT dispatchRead(pendingLoad's own
                // generation): a read dispatched under a RETIRED generation
                // runs, is thrown away by its own ctx.gen check, and leaves
                // the slot empty with nothing retrying it -- the queued
                // request silently lost. load() re-stamps the generation,
                // clears lastError, restarts the watchdog (so the queued run
                // gets a full window instead of inheriting the nearly-spent
                // remainder of the one that queued it) and stops the other
                // three Processes, which is exactly what this branch used to
                // do by hand. It cannot recurse: readBusy is false one line
                // above, so load() takes its dispatch path, not this one.
                root.pendingLoad = null
                root.load()
            }
        }
    }

    function applyRules(ctx, checked) {
        try { ctx.pendingChunks = Model.buildRuleChunks(checked) }
        catch (e) { root.lastError = String(e.message); watchdog.stop(); return }
        ctx.pendingIndex = 0
        root.nextChunk(ctx)
    }

    // Same shape as readBusy/pendingLoad above, and for evalProc
    // specifically (see the invariant comment above load()): true from
    // dispatchChunk() until evalProc's OWN onExited -- its actual terminal
    // signal -- fires for that dispatch.
    property bool evalBusy: false
    // A ctx whose nextChunk() arrived while evalBusy was true. evalProc's
    // onExited hands off to it once the in-flight dispatch has genuinely
    // finished, via nextChunk() again (which re-validates ctx.gen and the
    // chunk bounds rather than assuming they still hold).
    property var pendingChunkRun: null

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
        if (root.evalBusy) {
            // Do not touch evalProc.runCtx/command/running here -- see the
            // invariant comment above load(). Queue and let evalProc's own
            // onExited hand off once it is genuinely free.
            root.pendingChunkRun = ctx
            evalProc.running = false
            return
        }
        root.dispatchChunk(ctx)
    }

    function dispatchChunk(ctx) {
        root.evalBusy = true
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
            // The terminal signal for THIS dispatch, regardless of whether
            // it was stale -- evalBusy comes down unconditionally, same
            // reason as readBusy in readProc.onExited: a queued
            // pendingChunkRun must never be stuck waiting on a dispatch
            // that has, in fact, already finished.
            var ctx = evalProc.runCtx
            root.evalBusy = false
            if (ctx && ctx.gen === root.generation && exitCode !== 0 && root.lastError === "") {
                root.lastError = "hyprctl eval exited " + exitCode
                ctx.pendingIndex = ctx.pendingChunks.length
            }
            if (root.pendingChunkRun) {
                var next = root.pendingChunkRun
                root.pendingChunkRun = null
                root.nextChunk(next)
                return
            }
            if (ctx && ctx.gen === root.generation) root.nextChunk(ctx)
        }
    }

    function claimAndLaunch(ctx) {
        markerProc.runCtx = ctx
        markerProc.command = run.tool("omarchy-autostart-marker", "claim")
        markerProc.running = true
    }

    // QProcess::ExitStatus's NORMAL-exit value. Not `Process.NormalExit` --
    // checked against the installed Quickshell.Io type information
    // (/usr/lib/qt6/qml/Quickshell/Io/quickshell-io.qmltypes): the `exited`
    // signal declares `exitStatus` typed `QProcess::ExitStatus`, but the
    // `Process` Component in that file declares ZERO `Enum {}` blocks (the
    // file's only `Enum {}` belongs to the unrelated `FileViewError` type),
    // and the string "NormalExit" appears in no file at all under
    // /usr/lib/qt6/qml/. So `Process.NormalExit` is `undefined`, and
    // `exitStatus !== Process.NormalExit` was true for EVERY real value --
    // checked both: `0 !== undefined` and `1 !== undefined` both hold. The
    // guard below always took its early return with that spelling:
    // sessionStartOwed stayed true forever, launchAll() was never called,
    // and the autostart never ran, in any session, silently. It failed in
    // the safe direction -- no doubled session -- but the plugin's entire
    // purpose was dead and nothing in the test suite could see it, because
    // nothing here can load Quickshell.Io to notice `undefined`.
    // `QProcess::ExitStatus::NormalExit` is fixed at 0 by Qt; that is what
    // this compares against, named once here rather than as a bare literal
    // at the comparison site.
    readonly property int normalExit: 0

    Process {
        id: markerProc
        property var runCtx: null
        onExited: function(exitCode, exitStatus) {
            var ctx = markerProc.runCtx
            // ACCEPTED, DOCUMENTED, DELIBERATELY NOT FIXED. If this run was
            // superseded between the claim being GRANTED and this handler
            // running, the early return below leaves sessionStartOwed true.
            // The successor run then claims again, the marker refuses it
            // (the claim it does not know is already held), and the outcome
            // is: rules applied, programs never started. Closing this would
            // require the marker to record WHO holds the claim so a
            // successor could recognise its own predecessor's grant.
            //
            // It stays open on purpose. When the claim's outcome is
            // genuinely unknown to this side, the only two available errors
            // are a DOUBLED session and a session that DID NOT START, and
            // this project's rule -- stated in bin/omarchy-autostart-marker
            // itself -- is that a doubled session is worse. Leaving the
            // obligation owed picks the cheaper error every time, rather
            // than picking the cheaper error only when the guess is right.
            if (!ctx || ctx.gen !== root.generation) return
            // Qt documents exitCode as meaningful only when exitStatus is a
            // NORMAL exit -- a process killed by a signal (the watchdog, or
            // a superseded generation stopping it) can still report an
            // exitCode of 0 from whatever partial state it was in when
            // killed, which would read as a GRANTED claim it never actually
            // made. The marker fails closed by design
            // (bin/omarchy-autostart-marker); this reader must not undo
            // that by trusting a code that is not meaningful here. See
            // root.normalExit above for why this is a numeric constant and
            // not a named Process enum member.
            if (exitStatus !== root.normalExit) {
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
        // The entry's own shell line and the name to report it by, kept
        // together: the name is what makes a reported failure identifiable as
        // ONE program's rather than "something in the autostart". Whitespace
        // is folded because launchProc's stderr reader keeps only the LAST
        // line of the stream, and a name containing a newline would otherwise
        // push its own tail into that position.
        var entries = []
        for (var i = 0; i < programs.length; i++) {
            if (!programs[i].enabled) continue
            entries.push({ name: String(programs[i].name).replace(/\s+/g, " "),
                           line: Model.launchCommand(programs[i].command) })
        }
        if (entries.length === 0) { watchdog.stop(); return }
        // Each entry gets its own `bash -c`, and that is not a stylistic
        // choice. bash parses a whole line before it runs any of it, so with
        // every entry on one line a single malformed command would stop the
        // ENTIRE autostart -- the user logs in to an empty desktop and a
        // syntax error on stderr. Measured:
        //   all entries on one line:  syntax error -> nothing ran
        //   one bash -c per entry:    the good ones ran
        // Whether the bad one is REPORTED is a separate question, answered by
        // the `bash -n` pre-check below -- not by this split, and not by the
        // detached entry itself, whose stdio is closed.
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
        // THE `bash -n` PRE-CHECK, and why the detached entry cannot report
        // its own parse error. Closing the detached entry's stdio (the
        // paragraph above) also closes the channel the entry `bash` uses to
        // report a SYNTAX error in the command field -- and Model.validate
        // accepts an unbalanced quote, because that is a shell-syntax error,
        // not a field-shape error. Measured in this exact wrapper shape: with
        // the entry's stdio closed and no pre-check, a malformed command left
        // stderr EMPTY and the program simply never started, with nothing
        // told to the user.
        //
        // `bash -n -c '<entry>'` restores the report without reopening the
        // stream problem. Measured, same shape:
        //   unbalanced quote  -> exit 2, the syntax error on stderr
        //   valid command     -> exit 0, silent
        //   `touch <file>`    -> executes NOTHING (canary file never created)
        //   an 8 s program    -> wrapper exit 0 ms, stderr EOF 0 ms: `-n`
        //                        execs nothing, so it holds no pipe open and
        //                        the N3 hang cannot come back through it
        // Its stderr is deliberately NOT redirected -- that is the whole
        // point -- and it is bounded and closed by the time `-n` returns.
        // One extra short-lived process per entry.
        //
        // The identifying line after it is what launchProc's reader keeps
        // (that reader takes the LAST line), so lastError names the program
        // instead of quoting a bare `bash: -c: line 1: ...` whose wording is
        // locale-dependent; bash's own diagnostic still reaches the stream
        // ahead of it. The launch is gated on the check: an entry that does
        // not parse would not have run anyway (`bash -c` on it execs nothing
        // and exits 2), so gating costs no behaviour and keeps the two
        // outcomes -- reported, or launched -- mutually exclusive.
        var isolated = []
        for (var j = 0; j < entries.length; j++) {
            var quoted = Model.shellQuote(entries[j].line)
            isolated.push("if " + run.binBash + " -n -c " + quoted + "; then "
                        + run.binSetsid + " -f " + run.binBash + " -c " + quoted
                        + " </dev/null >/dev/null 2>&1; else echo "
                        + Model.shellQuote("autostart: " + entries[j].name
                            + ": the command is malformed and was not started")
                        + " >&2; fi")
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
        // bug) without re-introducing the hang N3 fixed.
        //
        // WHAT A USER CAN SEE on this stream, exactly:
        //   - an error from the outer wrapper's own construction;
        //   - each entry's `bash -n` PARSE diagnostic, plus the identifying
        //     "autostart: <name>: the command is malformed and was not
        //     started" line that follows it (see launchAll). Since only the
        //     LAST line survives into lastError, that identifying line is
        //     what lastError ends up holding; the rest is on the stream.
        // WHAT STAYS DROPPED -- this is NOT "unchanged from before this
        // round": the parse error above used to be dropped too, and the
        // pre-check is what recovered it. Still dropped, all of it silently:
        //   - the launched application's own stdout/stderr, by
        //     launchCommand's explicit design (redirected to /dev/null so
        //     that Quickshell tearing down ITS pipes can never reach the
        //     running application through them);
        //   - EVERYTHING THE ENTRY SHELL REPORTS AFTER THE PARSE. `bash -n`
        //     parses, it does not run: a command that does not exist
        //     ("command not found", exit 127), a program that starts and
        //     then fails, a redirection that fails at runtime -- measured
        //     silent, empty stderr, in this same wrapper shape. So a typo in
        //     a PROGRAM NAME is still invisible; only a typo in the shell
        //     SYNTAX is now reported;
        //   - `setsid`'s own failure to exec, whose diagnostic goes to the
        //     same per-entry /dev/null;
        //   - every entry's exit status: the `if` returns 0 whichever branch
        //     it takes, and `wait` reports only the last job's anyway.
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
