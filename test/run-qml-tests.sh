#!/usr/bin/env bash
# Runs the Model.js tests headless in the same engine that runs the plugin.
#
# Exit codes:
#   0 = all tests passed
#   1 = tests failed (one or more check or checkThrows failed)
#   2 = cannot run (no Qt6 qml binary found)
#   3 = harness broke (unexpected exception in test code)
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
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen exec /usr/bin/timeout -k 5 120 "$QML" harness.qml
