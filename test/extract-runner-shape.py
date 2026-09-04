#!/usr/bin/env python3
# Extracts the exact shell text runnerOut()/runnerErr() in Runners.qml would
# build for a given `cmd`, from the SOURCE CHARACTERS of that file -- not
# from a hand-copied mirror of them. runners-shape.sh feeds the result to a
# real /usr/bin/bash and checks the exit code, so a mutation that removes
# the pipefail-equivalent fix (${PIPESTATUS[0]}) or the truncation guard
# from Runners.qml changes what actually gets executed here, not just what
# a separate, independently-maintained test claims about it.
#
# Quickshell.Io does not exist outside the Quickshell runtime, so the QML
# function itself cannot be called (see test/qml-structure.sh's header for
# the same constraint applied elsewhere in this project). What CAN be done
# without a parser is: tokenize the `return root.runner(...)` expression
# into string literals and the two known variable references (`cmd`,
# `root.maxOutBytes`), splice in a real value for each, and run the result.
#
# Usage: extract-runner-shape.py <runnerOut|runnerErr> <test-cmd> <maxbytes>
# Prints the reconstructed shell text on stdout, or "EXTRACT_FAILED: ..." on
# stderr with a non-zero exit if the source no longer has the expected shape.
import re
import sys

def main():
    if len(sys.argv) != 4:
        print("usage: extract-runner-shape.py <fn> <test-cmd> <maxbytes>", file=sys.stderr)
        return 2
    fn, test_cmd, maxbytes = sys.argv[1], sys.argv[2], sys.argv[3]

    with open("Runners.qml", encoding="utf-8") as f:
        src = f.read()

    m = re.search(r'function\s+' + re.escape(fn) + r'\s*\(cmd\)\s*\{', src)
    if not m:
        print("EXTRACT_FAILED: function %s not found in Runners.qml" % fn, file=sys.stderr)
        return 1
    start = m.end()
    depth = 1
    i = start
    while depth > 0:
        if i >= len(src):
            print("EXTRACT_FAILED: unbalanced braces in %s" % fn, file=sys.stderr)
            return 1
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
        i += 1
    body = src[start:i - 1]

    expr_m = re.search(r'return\s+root\.runner\((.*)\)\s*$', body, re.S)
    if not expr_m:
        print("EXTRACT_FAILED: no 'return root.runner(...)' in %s" % fn, file=sys.stderr)
        return 1
    expr = expr_m.group(1)

    tokens = []
    pos = 0
    str_re = re.compile(r'"((?:[^"\\]|\\.)*)"')
    while pos < len(expr):
        ch = expr[pos]
        if ch.isspace() or ch == '+':
            pos += 1
            continue
        if ch == '"':
            sm = str_re.match(expr, pos)
            if not sm:
                print("EXTRACT_FAILED: unterminated string literal in %s" % fn, file=sys.stderr)
                return 1
            tokens.append(("lit", sm.group(1).encode().decode("unicode_escape")))
            pos = sm.end()
            continue
        var_m = re.match(r'root\.maxOutBytes|root\.binHead|cmd', expr[pos:])
        if var_m:
            tokens.append(("var", var_m.group(0)))
            pos += var_m.end()
            continue
        print("EXTRACT_FAILED: unrecognised token in %s at %r" % (fn, expr[pos:pos + 20]), file=sys.stderr)
        return 1

    out = []
    for kind, val in tokens:
        if kind == "lit":
            out.append(val)
        elif val == "cmd":
            out.append(test_cmd)
        elif val == "root.maxOutBytes":
            out.append(maxbytes)
        elif val == "root.binHead":
            # READ OUT OF THE SOURCE, never hard-coded here: the producer
            # limit's tool is named absolutely in Runners.qml now, and a
            # mirror of that path in this file would be a second place to
            # forget. A declaration that has gone missing is an extraction
            # failure, not a silent fallback to `head`.
            hm = re.search(r'readonly\s+property\s+string\s+binHead\s*:\s*"([^"]*)"', src)
            if not hm:
                print("EXTRACT_FAILED: no binHead declaration in Runners.qml",
                      file=sys.stderr)
                return 1
            out.append(hm.group(1))
    sys.stdout.write("".join(out))
    return 0

if __name__ == "__main__":
    sys.exit(main())
