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
    //
    // FOUR TOOLS WERE NAMED HERE AND ARE GONE: hyprctl and setsid belonged to
    // the removed apply and launch routes (this plugin issues no `hyprctl`
    // from QML any more and starts nothing), and mktemp/rm existed only to
    // hand a match file to `omarchy-autostart-windows --match-file`, which
    // went with the placement model. The one hyprctl left in this plugin is
    // `hyprctl -j clients` INSIDE bin/omarchy-autostart-windows, where the
    // running-programs picker needs it.
    readonly property string binTimeout: "/usr/bin/timeout"
    readonly property string binBash: "/usr/bin/bash"

    readonly property int shellSeconds: 120

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
    //
    // Terminated by a newline, not by "; }": an autostart command is a shell
    // command line by design, and a command legitimately ending in "&", ";",
    // "&&" or a trailing #comment makes "; }" after it a syntax error -- the
    // group then never runs and nothing is collected, silently. A newline
    // closes the list in every one of those cases.
    //
    // A bare pipe reports HEAD's exit status, not the producer's -- head
    // always succeeds, so a caller reading exitCode after `cmd | head -c N`
    // alone never sees a failure. This is exactly how the deleted start
    // marker's claim/refuse gate once went inert: a refused claim exits 1,
    // but through this shape that 1 was thrown away, so every login re-ran
    // the autostart. The marker is gone; the defect it taught is not, and
    // tool() still routes every bin/ call through this wrapper.
    //
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

    // One of our own bin/ scripts. Its output is already bounded by the
    // script's own caps; runnerOut is the second belt -- and, since the F1
    // fix, also the one that makes the script's own exit status visible at
    // all through this route.
    function tool(name, args) {
        return root.runnerOut(Model.shellQuote(root.binDir + name)
                              + (args ? " " + args : ""))
    }
}
