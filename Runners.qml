import QtQuick
import Quickshell.Io
import "Model.js" as Model

// The call helpers. Every command in this plugin goes through one of them,
// because a limit that has to be remembered at each call site is one that gets
// forgotten at one of them.
Item {
    id: root

    // Absolute paths. A PATH-resolved interpreter is a different program on a
    // different machine, and tidying PATH protects nothing here: Omarchy lives
    // in /usr/bin too.
    readonly property string binTimeout: "/usr/bin/timeout"
    readonly property string binBash: "/usr/bin/bash"
    readonly property string binHyprctl: "/usr/bin/hyprctl"

    readonly property int shellSeconds: 120
    readonly property int hyprSeconds: 20

    // Anything past this is not an answer, it is a flood.
    readonly property int maxOutBytes: 262144

    readonly property string binDir:
        Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "") + "bin/"

    // With a shell -- for the autostart, whose command field is a shell
    // command line by design, and for our own bin/ scripts, whose stdout is
    // collected and therefore needs a producer limit.
    function runner(cmd) {
        return [root.binTimeout, "-k", "5", String(root.shellSeconds),
                root.binBash, "-c", cmd]
    }

    // The limit belongs on the producing side, so the bytes are never held in
    // the first place.
    function runnerOut(cmd) {
        return root.runner("{ " + cmd + " ; } | head -c " + root.maxOutBytes)
    }

    // Process substitution rather than a pipe: a pipe would replace the exit
    // status of the command itself, and callers read it.
    function runnerErr(cmd) {
        return root.runner("{ " + cmd + " ; } 2> >(head -c " + root.maxOutBytes + " >&2)")
    }

    // Without a shell. Both hyprctl verbs take a Lua string; handing it over as
    // one argv element means there is no second quoting question to get wrong.
    function hypr(verb, payload) {
        return [root.binTimeout, "-k", "5", String(root.hyprSeconds),
                root.binHyprctl, verb, payload]
    }

    // One of our own bin/ scripts. Its output is already bounded by the
    // script's own caps; runnerOut is the second belt.
    function tool(name, args) {
        return root.runnerOut(Model.shellQuote(root.binDir + name)
                              + (args ? " " + args : ""))
    }
}
