#!/usr/bin/env bash
# Runs the Model.js tests headless in the same engine that runs the plugin.
#
# Exit codes:
#   0 = all tests passed
#   1 = tests failed (one or more check or checkThrows failed)
#   2 = cannot run (no Qt6 qml binary found)
#   3 = harness broke (unexpected exception in test code)
#
# /usr/bin/qml on Arch is Qt 5.15 and fails SILENTLY with status 1 -- no output
# on stdout or stderr at all. Never fall back to it: a silent exit 1 looks
# exactly like a failing test suite. Resolve the Qt6 binary or refuse to run.
set -euo pipefail

QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" --version 2>&1 | grep -q "Qml Runtime 6"; then QML="$candidate"; break; fi
done

if [[ -z "$QML" ]]; then
  echo "error: no Qt6 qml runtime found." >&2
  echo "       /usr/bin/qml is Qt 5.15 here and exits 1 without a word." >&2
  echo "       install qt6-declarative or point QT6_QML at the Qt6 binary." >&2
  exit 2
fi

cd "$(dirname "$0")"
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen exec /usr/bin/timeout -k 5 120 "$QML" harness.qml
