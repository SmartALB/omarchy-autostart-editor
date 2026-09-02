#!/usr/bin/env bash
# Runs the Model.js tests headless in the same engine that runs the plugin.
#
# Exit codes:
#   0 = all tests passed
#   1 = tests failed (one or more check or checkThrows failed)
#   2 = cannot run (no Qt6 qml binary found)
#   3 = harness broke (unexpected exception in test code)
#   4 = the assertion-count guard failed: the harness CONTAINS assertions it
#       did not RUN, or the guard could not count any at all
#
# /usr/bin/qml on Arch is Qt 5.15 and does not load this harness at all: it
# rejects the versionless `import QtQml` and exits 2 with an error about
# loading no objects. Never fall back to it -- that failure reads like a
# tooling problem rather than "the logic under test is wrong", and its exit
# code collides with our own "cannot run". Resolve the Qt6 binary or refuse.
#
# The tool that fails SILENTLY with status 1 -- nothing on either stream --
# is /usr/bin/qmltestrunner, which is why it is not used here.
set -euo pipefail

QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" --version 2>&1 | grep -q "Qml Runtime 6"; then QML="$candidate"; break; fi
done

if [[ -z "$QML" ]]; then
  echo "error: no Qt6 qml runtime found." >&2
  echo "       /usr/bin/qml here is Qt 5.15 and cannot load the harness." >&2
  echo "       install qt6-declarative or point QT6_QML at the Qt6 binary." >&2
  exit 2
fi

cd "$(dirname "$0")"

# --- the assertion-count guard ----------------------------------------------
#
# EVERY assertion the harness CONTAINS must be one the harness RUNS.
#
# This is the shell suite's invocation guard (test/lib.sh) reaching the one
# other suite with the same exposure, through the shape this one actually has:
# the harness defines no test functions to leave uninvoked, it is a single long
# run of check() calls -- and a block of them can stop executing with nothing
# to show for it. Wrapped in a function nobody calls, placed after an early
# return, fenced behind a condition that is never true, or simply commented
# out: the reported total is then smaller, and "smaller" is invisible unless
# something compares it against what the file contains. That is exactly how the
# shell suite sat at 154 and green with two assertions silently not running.
#
# So: count the call sites in the file, run the harness, and require the two
# numbers to be equal.
#
# Counting reads the comment-stripped view (a commented-out check must not
# count as one), skips the two definitions of check/checkThrows, and skips
# occurrences preceded by a quote -- checkThrows names itself inside its own
# error message.
#
# FAIL-CLOSED: a count of zero is a failure, not a pass, because a guard over
# an empty set proves nothing -- that is the blind-test shape one level up. A
# missing total in the output is a failure too. And a future call site inside a
# loop would fail this as well: it would have to be made countable, which is
# the price of the guarantee and cheaper than the guarantee's absence.
stripped="$(awk -f strip-comments.awk harness.qml)"
occurrences="$(grep -oE "(^|[^A-Za-z0-9_\"'])(checkThrows|check)\\(" <<<"$stripped" | grep -c .)"
definitions="$(grep -cE 'function[[:space:]]+(checkThrows|check)[[:space:]]*\(' <<<"$stripped" || true)"
declared=$(( occurrences - definitions ))

if (( declared <= 0 )); then
  echo "error: the assertion-count guard counted $declared call sites in harness.qml." >&2
  echo "       a guard over an empty set proves nothing -- the counting pattern is broken," >&2
  echo "       not the harness. Fix the pattern before trusting any run." >&2
  exit 4
fi

if output="$(QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen \
             /usr/bin/timeout -k 5 120 "$QML" harness.qml 2>&1)"; then
  status=0
else
  status=$?
fi
printf '%s\n' "$output"

# A failing or broken harness is the headline; the count is checked only once
# the run itself is sound.
[[ "$status" -ne 0 ]] && exit "$status"

ran="$(sed -n 's/.*total=\([0-9]*\) failed=.*/\1/p' <<<"$output" | tail -1)"
if [[ -z "$ran" ]]; then
  echo "error: the harness exited 0 but printed no total, so nothing can be compared." >&2
  exit 4
fi
if (( ran != declared )); then
  echo "error: harness.qml contains $declared assertions but ran $ran." >&2
  echo "       $(( declared - ran )) assertion(s) are in the file and were not executed --" >&2
  echo "       an assertion that does not run looks exactly like one that passes." >&2
  echo "       (A call site inside a loop trips this too; make it countable.)" >&2
  exit 4
fi
echo "qml: assertions in the file: $declared, assertions run: $ran"
