import QtQuick
import Quickshell
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
    // The producer limit's own tool. It was the one binary this file named
    // BARE -- it sits inside the command string runnerOut/runnerErr build, so
    // check 1's quoted-and-bare pattern could not see it -- and it was
    // therefore resolved through the ambient PATH like any other.
    readonly property string binHead: "/usr/bin/head"

    // THE ENVIRONMENT EVERY PROCESS OF THIS PLUGIN GETS, CONSTRUCTED HERE
    // RATHER THAN INHERITED FROM THE SESSION.
    //
    // A reported defect. Every route out of this plugin runs one of our own
    // bin/ scripts, each of them bash, and the whole ambient environment went
    // with them -- so a variable an attacker of the same user can set decided
    // what those scripts executed. MEASURED (bash 5.3.15): with
    // BASH_ENV=<file> in the environment, that file's code RAN BEFORE THE
    // SCRIPT BODY, in a non-interactive shell, and it still ran through
    // `/usr/bin/timeout`, which is the route below. A fixed `#!/bin/bash`
    // shebang does NOT close that -- measured too -- because bash consumes
    // BASH_ENV at startup, before the first line of the script is read. It
    // has to be ABSENT FROM THE ENVIRONMENT, and that is what this is.
    //
    // AN ALLOWLIST, NOT A DENYLIST, and that is the whole point: with
    // clearEnvironment the child starts from NOTHING and receives exactly
    // what is named here, so BASH_ENV, ENV, SHELLOPTS, BASHOPTS, LD_PRELOAD,
    // LD_LIBRARY_PATH and IFS are gone BY CONSTRUCTION rather than by being
    // remembered. A denylist would have to be extended for every variable
    // bash, ld.so or a coreutils tool ever learns to read.
    //
    // IT ALSO CLOSES THE TEST SEAMS AS AN INJECTION ROUTE, which was not the
    // reason for the change but is the largest single thing it buys.
    // bin/omarchy-autostart-windows honours HYPRCTL, WHICH NAMES A BINARY IT
    // EXECUTES, and bin/omarchy-autostart-hypr-write honours
    // OMARCHY_AUTOSTART_STAMP; both exist so the suites can reach what a
    // sandbox cannot otherwise reach. Neither is in this list, so through the
    // panel neither can be set at all and the production value is the only
    // one reachable.
    //
    // `clearEnvironment: true` ALONE WOULD BREAK THIS PLUGIN, which is why
    // every name below is here for a stated reason rather than for tidiness.
    // Each was measured by running the script under `env -i` plus the one
    // variable:
    //
    //   HOME                        the writer and the reader resolve
    //                               ${XDG_CONFIG_HOME:-$HOME/.config}
    //   XDG_CONFIG_HOME             the same expansion, when the user sets it
    //   XDG_DATA_HOME               the .desktop search path of
    //   XDG_DATA_DIRS               bin/omarchy-autostart-apps; without them
    //                               the "Add program" picker is empty
    //   HYPRLAND_INSTANCE_SIGNATURE `hyprctl -j clients` in
    //                               bin/omarchy-autostart-windows. MEASURED:
    //                               under `env -i` hyprctl answers
    //                               "HYPRLAND_INSTANCE_SIGNATURE not set! (is
    //                               hyprland running?)" and the running-
    //                               programs list comes back empty. This one
    //                               is in no finding and would have been the
    //                               silent breakage.
    //   XDG_RUNTIME_DIR             the socket hyprctl opens. Measured: it
    //                               resolves /run/user/<uid> without this on
    //                               this machine, so passing it is the
    //                               documented path rather than a guess.
    //   LANG                        `sort` is locale-sensitive and it orders
    //                               the application picker. Dropping it would
    //                               silently reorder that list for every user
    //                               outside the C locale, so it is passed to
    //                               keep the panel's behaviour UNCHANGED.
    //                               LC_ALL is deliberately not passed --
    //                               nothing here needs it -- and neither are
    //                               LOCPATH or GCONV_PATH, which name
    //                               loadable modules, for the same reason
    //                               LD_PRELOAD is not.
    //   TMPDIR                      bin/omarchy-autostart-hypr's mktemp. It
    //                               falls back to /tmp on its own, so this is
    //                               for the user who redirected it.
    //
    // PATH IS FIXED RATHER THAN PASSED: it is the one variable in the list
    // whose inherited value is itself the defect.
    readonly property string toolPath: "/usr/bin:/bin"
    readonly property var toolEnvPass: ["HOME", "XDG_CONFIG_HOME",
        "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_RUNTIME_DIR",
        "HYPRLAND_INSTANCE_SIGNATURE", "LANG", "TMPDIR"]

    // A variable that is not set stays UNSET rather than arriving as an empty
    // string. "Absent" is the honest translation of absent, and it is also
    // what the scripts are written against: ${XDG_CONFIG_HOME:-$HOME/.config}
    // substitutes for set-but-empty too, but nothing here should depend on
    // that reading.
    readonly property var toolEnv: root.buildToolEnv()

    function buildToolEnv() {
        var env = { "PATH": root.toolPath }
        for (var i = 0; i < root.toolEnvPass.length; i++) {
            var name = root.toolEnvPass[i]
            var value = Quickshell.env(name)
            if (value !== undefined && value !== null && String(value) !== "")
                env[name] = String(value)
        }
        return env
    }

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
        return root.runner("{ " + cmd + "\n} | " + root.binHead + " -c " + root.maxOutBytes
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
        return root.runner("{ " + cmd + "\n} 2> >(" + root.binHead + " -c " + root.maxOutBytes + " >&2)"
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

    // ONE OF OUR OWN bin/ SCRIPTS WITH NO SHELL ANYWHERE IN THE ROUTE, as an
    // argv list: the tool, then its arguments, each its own element.
    //
    // WHY THIS EXISTS, and it is a reported defect rather than a preference.
    // The autostart write used tool()/runnerOut(), which build a command
    // STRING for `bash -c`. The new autostart.lua went to the writer on
    // stdin -- but the shell that produced it carried the whole file in its
    // own argv, and /proc/<pid>/cmdline is world-readable: every process on
    // the machine could read the user's command lines once per save. The
    // comment at the call site said the content went in on stdin and was
    // true about the WRITER while missing the exposure one process earlier.
    // Passing an argv list removes the producing shell entirely, so there is
    // no command string for the content to be embedded in, and the quoting
    // question that comes with one does not arise at all.
    //
    // WHAT IS GIVEN UP, named rather than glossed over: runnerOut's `head -c`
    // second belt on the producer. There is no shell here to interpose one.
    // The one caller reads a bounded JSON envelope from a script that caps
    // its own output, so the remaining cap is the script's -- and a shell
    // whose argv holds the user's commands is the worse of the two exposures.
    //
    // The timeout stays: it is a program, not an interpreter, it passes stdin
    // straight through, and a call that never returns is what it is for.
    function toolArgv(name, args) {
        return [root.binTimeout, "-k", "5", String(root.shellSeconds),
                root.binDir + name].concat(args || [])
    }
}
