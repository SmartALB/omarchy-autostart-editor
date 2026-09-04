#!/usr/bin/env python3
# Builds a runnable QML/JS probe out of the SOURCE CHARACTERS of Panel.qml and
# Runners.qml, so that the argv the panel would hand to the autostart writer
# can be evaluated for real instead of being described by a second,
# independently-maintained copy of it.
#
# WHAT IT IS FOR. The property under test is that the new autostart.lua NEVER
# APPEARS IN A COMMAND, because a command's argv is readable by every process
# on the machine through /proc/<pid>/cmdline. That is a property of the
# command the panel BUILDS, so it has to be measured on the thing the panel's
# own source produces -- not on a hand-written argv that would stay green
# after the call site grew a shell back.
#
# Quickshell.Io does not exist outside the Quickshell runtime, so Panel.qml
# cannot be loaded (test/qml-structure.sh's header explains the same
# constraint), and the same trick extract-runner-shape.py uses is used here:
# take the exact text of Runners.qml's argv helper and of the panel's command
# expression, put them in front of stand-ins for the four objects they name,
# and let the real Qt6 engine evaluate them. A mutation at either place
# changes what this probe executes.
#
# Usage: extract-write-argv.py <sentinel-content> <mtime> <bin-dir> <out.qml>
# The generated file prints one line, "ARGV_JSON:[...]", and exits.
# On stderr with a non-zero exit: EXTRACT_FAILED, when the source no longer
# has the shape this can read -- never a silent partial success.
import json
import re
import sys


def fail(msg):
    print("EXTRACT_FAILED: %s" % msg, file=sys.stderr)
    return 1


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def brace_block(src, start_index, opener="{", closer="}"):
    """The text from start_index (just past an opener) to its matching closer."""
    depth = 1
    i = start_index
    while depth > 0:
        if i >= len(src):
            return None
        if src[i] == opener:
            depth += 1
        elif src[i] == closer:
            depth -= 1
        i += 1
    return src[start_index:i - 1]


def main():
    if len(sys.argv) != 5:
        print("usage: extract-write-argv.py <sentinel> <mtime> <bin-dir> <out.qml>",
              file=sys.stderr)
        return 2
    sentinel, mtime, bin_dir, out_path = sys.argv[1:5]

    runners = read("Runners.qml")
    panel = read("Panel.qml")

    # 1 -- EVERY call helper Runners.qml defines, verbatim. Not only the argv
    #      one: the stand-in has to be a faithful Runners instance, or a
    #      mutation that puts the OLD shell-string route back (run.runnerOut,
    #      the shape v1.0.1 shipped) would fail here for the wrong reason --
    #      "the helper is not defined" rather than "the content is in the
    #      argv". The probe that reverts this fix depends on that.
    helpers = []
    for hm in re.finditer(r'function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*\{', runners):
        body = brace_block(runners, hm.end())
        if body is None:
            return fail("unbalanced braces in %s" % hm.group(1))
        helpers.append((hm.group(1), runners[hm.start():hm.end()] + body + "}"))
    if not any(name == "toolArgv" for name, _ in helpers):
        return fail("no 'function toolArgv(...)' in Runners.qml")

    # 2 -- and every literal property they name. A computed value is skipped
    #      rather than guessed at (binDir is computed and is passed in), and a
    #      helper that turns out to need one this cannot see fails loudly in
    #      the engine rather than quietly here.
    lit = {}
    for pm in re.finditer(r'property\s+string\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"([^"]*)"', runners):
        lit[pm.group(1)] = json.dumps(pm.group(2))
    for pm in re.finditer(r'property\s+int\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(\d+)', runners):
        lit[pm.group(1)] = pm.group(2)
    for required in ("binTimeout", "shellSeconds"):
        if required not in lit:
            return fail("no literal %s in Runners.qml" % required)

    # 3 -- the panel's command expression: everything from the assignment to
    #      the writer Process's command up to the end of its balanced
    #      parentheses. Parenthesis matching rather than "to end of line", so
    #      a call wrapped over several lines -- which this one is -- comes out
    #      whole, and so would a content argument spliced into it.
    am = re.search(r'autostartWriteProc\s*\.\s*command\s*=\s*', panel)
    if not am:
        return fail("no 'autostartWriteProc.command =' in Panel.qml")
    rest = panel[am.end():]
    open_paren = rest.find("(")
    if open_paren < 0:
        return fail("the command assignment in Panel.qml is not a call")
    inner = brace_block(rest, open_paren + 1, "(", ")")
    if inner is None:
        return fail("unbalanced parentheses in the command assignment")
    expr = rest[:open_paren + 1] + inner + ")"

    # 4 -- the stand-ins. `root` is the Runners instance the helper's own body
    #      addresses; `result` and `section` are what the panel's write
    #      function holds at the assignment. Model is the REAL Model.js, so a
    #      quoting call spliced into the expression would resolve to the
    #      function it names rather than to a stub of it.
    props = "".join("            %s: %s,\n" % (name, value)
                    for name, value in sorted(lit.items()))
    funcs = "".join("        run.%s = %s\n" % (name, text) for name, text in helpers)
    qml = """import QtQml
import "Model.js" as Model

// GENERATED by test/extract-write-argv.py -- do not edit, and do not commit.
QtObject {
    Component.onCompleted: {
        var run = {
%(props)s            binDir: %(binDir)s
        }
        var root = run
%(funcs)s        var result = { ok: true, text: %(sentinel)s }
        var section = { mtime: %(mtime)s, content: "", file: "autostart.lua" }
        var argv = %(expr)s
        console.log("ARGV_JSON:" + JSON.stringify(argv))
        Qt.exit(0)
    }
}
""" % {
        "props": props,
        "binDir": json.dumps(bin_dir),
        "funcs": funcs,
        "sentinel": json.dumps(sentinel),
        "mtime": json.dumps(mtime),
        "expr": expr,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(qml)
    return 0


if __name__ == "__main__":
    sys.exit(main())
