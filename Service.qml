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
    // back off. rulesOnly and the pending-chunk state belong to the run
    // context object (ctx) passed through the chain below, not to this
    // component, precisely so an old run's leftover callback has its own
    // copy to read -- and the ctx.gen check in every handler still refuses
    // to act once a newer run exists, even reading its own copy.
    property int generation: 0

    // Quickshell exposes no error signal for a Process, so one that never
    // emits `exited` -- a bad binDir resolution, a hung producer, an
    // environment where a `/usr/bin/...` tool is simply missing -- would
    // otherwise strand a run forever with no visible symptom. This does not
    // try to be clever about which Process is stuck; it stops all four for
    // the run in flight and reports once. Restarted on every load() and
    // cancelled at every point a run actually finishes, below.
    readonly property int watchdogSeconds: 30
    Timer {
        id: watchdog
        interval: root.watchdogSeconds * 1000
        repeat: false
        onTriggered: {
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

    Component.onCompleted: root.load(false)

    function load(onlyRules) {
        root.generation += 1
        var gen = root.generation
        // Any earlier run's Processes are stopped outright, not just
        // out-voted by the generation check below: reassigning `command`
        // and `running` on a Process that is still actually running is not
        // something to rely on behaving cleanly, so the slate is cleared
        // first and the ctx.gen check only has to catch a callback that was
        // already queued before this line ran.
        readProc.running = false
        evalProc.running = false
        markerProc.running = false
        launchProc.running = false

        root.lastError = ""
        watchdog.stop()
        watchdog.start()

        var ctx = { gen: gen, rulesOnly: onlyRules, pendingChunks: [], pendingIndex: 0 }
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
                // whole apply instead.
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
            // programs from starting. rulesOnly (a reload) never reaches
            // here regardless -- a reload does not restart a session.
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
            // Only a successful claim launches anything. Every other
            // outcome skips the autostart on purpose -- see
            // bin/omarchy-autostart-marker: it fails closed, and a doubled
            // session is worse than one that did not start.
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
        var isolated = []
        for (var j = 0; j < commands.length; j++) {
            isolated.push(run.binSetsid + " -f " + run.binBash + " -c " + Model.shellQuote(commands[j]))
        }
        launchProc.runCtx = ctx
        launchProc.command = run.launcher(isolated.join(" & ") + " & wait")
        launchProc.running = true
    }

    Process {
        id: launchProc
        property var runCtx: null
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
    // rule away. This puts them back: rules only, never the programs (a
    // reload does not restart a session). load()'s generation guard above
    // is what keeps a reload landing mid-startup from corrupting the run
    // already in flight instead of cleanly superseding it.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (String(event.name) === "configreloaded") root.load(true)
        }
    }
}
