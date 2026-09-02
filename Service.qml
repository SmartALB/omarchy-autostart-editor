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
    property string lastError: ""

    // Rules only; never the programs. A reload does not restart a session.
    property bool rulesOnly: false

    property var pendingChunks: []
    property int pendingIndex: 0

    Component.onDestruction: {
        readProc.running = false
        evalProc.running = false
        launchProc.running = false
        markerProc.running = false
    }

    Component.onCompleted: root.load(false)

    function load(onlyRules) {
        root.rulesOnly = onlyRules
        root.lastError = ""
        readProc.command = run.tool("omarchy-autostart-config", "read")
        readProc.running = true
    }

    Process {
        id: readProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) { root.lastError = "unreadable answer from the config reader"; return }

                // Fail closed. A broken structure does not say what the user
                // wants -- no rule is better than half of one.
                if (!envelope.ok) {
                    root.lastError = String(envelope.error || "unknown") + ": "
                                   + String(envelope.detail || "")
                    return
                }
                var checked = Model.validate(envelope.config)
                root.model = checked
                root.rejected = checked.rejected
                root.applyRules(checked)
            }
        }
    }

    function applyRules(checked) {
        try { root.pendingChunks = Model.buildRuleChunks(checked) }
        catch (e) { root.lastError = String(e.message); return }
        root.pendingIndex = 0
        root.nextChunk()
    }

    function nextChunk() {
        if (root.pendingIndex >= root.pendingChunks.length) {
            if (!root.rulesOnly) root.claimAndLaunch()
            return
        }
        evalProc.command = run.hypr("eval", root.pendingChunks[root.pendingIndex])
        root.pendingIndex += 1
        evalProc.running = true
    }

    Process {
        id: evalProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // hyprctl answers "ok" for a chunk that ran. Anything else
                // stops the run: half-applied rules are worse than none.
                if (String(text || "").trim() !== "ok") {
                    root.lastError = "hyprctl eval refused a rule block"
                    root.pendingIndex = root.pendingChunks.length
                }
            }
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 && root.lastError === "") {
                root.lastError = "hyprctl eval exited " + exitCode
                root.pendingIndex = root.pendingChunks.length
            }
            root.nextChunk()
        }
    }

    function claimAndLaunch() {
        markerProc.command = run.tool("omarchy-autostart-marker", "claim")
        markerProc.running = true
    }

    Process {
        id: markerProc
        onExited: function(exitCode, exitStatus) {
            // Only a successful claim launches anything. Every other outcome
            // skips the autostart on purpose.
            if (exitCode === 0) root.launchAll()
        }
    }

    function launchAll() {
        var programs = root.model.programs || []
        var commands = []
        for (var i = 0; i < programs.length; i++) {
            if (programs[i].enabled) commands.push(Model.launchCommand(programs[i].command))
        }
        if (commands.length === 0) return
        // Each entry gets its own `bash -c`, and that is not a stylistic
        // choice. bash parses a whole line before it runs any of it, so with
        // every entry on one line a single malformed command would stop the
        // ENTIRE autostart -- the user logs in to an empty desktop and a
        // syntax error on stderr. Measured:
        //   all entries on one line:  syntax error -> nothing ran
        //   one bash -c per entry:    the good ones ran, only the bad reported
        // The outer shell still starts them all in parallel and waits once, so
        // this costs one short-lived process per program, not one per program
        // kept alive.
        var isolated = []
        for (var j = 0; j < commands.length; j++) {
            isolated.push("/usr/bin/bash -c " + Model.shellQuote(commands[j]))
        }
        launchProc.command = run.runner(isolated.join(" & ") + " & wait")
        launchProc.running = true
    }

    Process {
        id: launchProc
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var message = String(text || "").trim()
                if (message !== "") root.lastError = message.split("\n").pop()
            }
        }
    }

    // A manual `hyprctl reload` throws runtime rules away -- nothing in
    // Omarchy calls it, but a user can. This puts them back, and only them.
    Connections {
        target: Hyprland
        ignoreUnknownSignals: true
        function onRawEvent(event) {
            if (String(event.name) === "configreloaded") root.load(true)
        }
    }
}
