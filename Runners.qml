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
    readonly property string binSetsid: "/usr/bin/setsid"

    // For the one command shape that needs a real file on disk to hand over:
    // bin/omarchy-autostart-windows --match-file asks `[[ -f ]]` before
    // reading, so a pipe and a process substitution are both refused -- and
    // silently, it answers "[]" and every program then reads as not running.
    // Named here rather than at that call site, because one place names the
    // tools.
    readonly property string binMktemp: "/usr/bin/mktemp"
    readonly property string binRm: "/usr/bin/rm"

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

    // The launch route's own runner. Plain `runner()` lets GNU `timeout` put
    // its child in a NEW process group and, at the deadline, signal the
    // WHOLE group -- fine for our own short bin/ scripts, fatal for the
    // autostarted programs, which are backgrounded grandchildren of that
    // group. Measured, two long-lived backgrounded grandchildren, 2 s
    // deadline: 0 of 2 survived without `--foreground`, 2 of 2 with it.
    // `--foreground` only stops TIMEOUT's own deadline from reaching them;
    // Service.qml additionally detaches each entry with `setsid -f` so a
    // teardown of this Process (Component.onDestruction, or a superseded
    // generation) cannot reach them either -- see launchAll() there.
    function launcher(cmd) {
        return [root.binTimeout, "--foreground", "-k", "5", String(root.shellSeconds),
                root.binBash, "-c", cmd]
    }

    // The limit belongs on the producing side, so the bytes are never held in
    // the first place.
    //
    // Terminated by a newline, not by "; }": the autostart command field is a
    // shell command line by design (see launchCommand in Model.js), and a
    // command legitimately ending in "&", ";", "&&" or a trailing #comment
    // makes "; }" after it a syntax error -- the group then never runs and
    // nothing is collected, silently. A newline closes the list in every one
    // of those cases, the same fix as launchCommand.
    //
    // A bare pipe reports HEAD's exit status, not the producer's -- head
    // always succeeds, so a caller reading exitCode after `cmd | head -c N`
    // alone never sees a failure. This is exactly how the marker's
    // claim/refuse gate went inert (Service.qml's markerProc): a refused
    // claim exits 1, but through this shape that 1 was thrown away.
    // ${PIPESTATUS[0]} recovers the producer's own status. `set -o
    // pipefail` was the other candidate and was rejected: it also rescores
    // any pipeline that happens to live INSIDE cmd, and nothing handed to
    // tool() has one, so PIPESTATUS is the narrower fix for what this
    // wrapper actually needs.
    //
    // head closes its read end after its Nth byte without draining the
    // rest, so a producer still writing past that point gets SIGPIPE --
    // status 141 (128 + SIGPIPE) -- for output that was simply longer than
    // expected, not for a failure. Reporting 141 as a failure would turn
    // "the answer was bigger than the cap" into a spurious error on every
    // caller that checks exitCode !== 0, so it is caught here and turned
    // into 0. Still worth being able to see, so it goes to stderr; never
    // the exit status a caller reads. Every other non-zero status is a real
    // failure and passes straight through.
    function runnerOut(cmd) {
        return root.runner("{ " + cmd + "\n} | head -c " + root.maxOutBytes
            + "\ns=${PIPESTATUS[0]}"
            + "\nif [ $s -eq 141 ]; then echo 'runnerOut: producer output exceeded the cap -- truncated, not a failure' >&2; exit 0; fi"
            + "\nexit $s")
    }

    // Process substitution rather than a pipe: a pipe would replace the exit
    // status of the command itself, and callers read it -- $? here already
    // is the producer's own status, no PIPESTATUS needed. Newline-terminated
    // for the same reason as runnerOut.
    //
    // The same truncation hazard reaches here by a different route: once
    // head has read its Nth byte and closed the read end, a command still
    // writing to stderr gets SIGPIPE itself, so $? becomes 141 directly --
    // and the same rule applies: 141 means truncated, not failed.
    function runnerErr(cmd) {
        return root.runner("{ " + cmd + "\n} 2> >(head -c " + root.maxOutBytes + " >&2)"
            + "\ns=$?"
            + "\nif [ $s -eq 141 ]; then echo 'runnerErr: producer output exceeded the cap -- truncated, not a failure' >&2; exit 0; fi"
            + "\nexit $s")
    }

    // Without a shell. Both hyprctl verbs take a Lua string; handing it over as
    // one argv element means there is no second quoting question to get wrong.
    function hypr(verb, payload) {
        return [root.binTimeout, "-k", "5", String(root.hyprSeconds),
                root.binHyprctl, verb, payload]
    }

    // One of our own bin/ scripts. Its output is already bounded by the
    // script's own caps; runnerOut is the second belt -- and, since the F1
    // fix, also the one that makes the script's own exit status visible at
    // all through this route.
    function tool(name, args) {
        return root.runnerOut(Model.shellQuote(root.binDir + name)
                              + (args ? " " + args : ""))
    }
}
