#!/usr/bin/env bash
# Compiles every generated Lua chunk with a real Lua compiler.
#
# A chunk that merely "looks right" is not the property under test -- the
# property is that Hyprland can load it. luac5.1 ships with the lua51 package,
# which is part of omarchy-base.packages, so this runs on any Omarchy install.
# Our chunks use no version-specific syntax (no goto, no integer division, no
# bitwise operators), so 5.1 is a sound stand-in for whatever Lua Hyprland
# embeds.
set -uo pipefail
cd "$(dirname "$0")"

LUAC=""
for candidate in luac5.1 luac luac5.4; do
  command -v "$candidate" >/dev/null 2>&1 && { LUAC="$candidate"; break; }
done
if [[ -z "$LUAC" ]]; then
  echo "error: no Lua compiler found (tried luac5.1, luac, luac5.4)." >&2
  echo "       install lua51 -- it is part of omarchy-base.packages." >&2
  exit 2
fi

QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  "$candidate" --version 2>&1 | grep -q "Qml Runtime 6" && { QML="$candidate"; break; }
done
[[ -n "$QML" ]] || { echo "error: no Qt6 qml runtime found." >&2; exit 2; }

CONFIG="${1:-}"
[[ -n "$CONFIG" ]] || CONFIG='{"schemaVersion":1,
  "programs":[
    {"id":"p1","name":"Cursor","enabled":true,"command":"cursor",
     "class":"^(cursor)$","placement":{"kind":"workspace","value":"6"}},
    {"id":"p2","name":"Modelbox","enabled":true,"command":"modelbox",
     "class":"LM[- ]?Studio","placement":{"kind":"monitor","value":"DP-4"}},
    {"id":"p3","name":"Nimbus mail","enabled":false,
     "command":"nimbus --app=https://mail.example.com/mail/",
     "class":"^(nimbus-webmail\\.office\\.com__mail_-Default)$",
     "placement":{"kind":"workspace","value":"2"}}],
  "workspaces":[{"workspace":"6","monitor":"HDMI-A-1"},{"workspace":"2","monitor":"DP-3"}]}'

# A prior test's setup_sandbox (see lib.sh) may leave TMPDIR exported and
# pointing at a sandbox teardown_sandbox has since deleted -- it removes the
# sandbox directory but never restores TMPDIR. Force /tmp here, the same
# workaround lib.sh's own setup_sandbox uses for the identical problem.
tmp="$(TMPDIR=/tmp mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Wrapped in timeout like run-qml-tests.sh: an uncaught exception in
# Component.onCompleted (e.g. Model.buildRuleChunks missing) never reaches
# Qt.exit(), and with no window and no timer the QML event loop then sits
# idle forever instead of failing fast. Confirmed by hanging indefinitely
# before this guard was added.
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen \
  /usr/bin/timeout -k 5 120 "$QML" dump-chunks.qml -- "$CONFIG" 2>&1 \
  | sed 's/^qml: //' > "$tmp/all"

# Split on the marker into $tmp/chunk.NN
awk -v out="$tmp" '
  /^----8<----$/ { n++; file = sprintf("%s/chunk.%02d", out, n); next }
  n > 0          { print >> file }
' "$tmp/all"

count=0; failed=0
for chunk in "$tmp"/chunk.*; do
  [[ -e "$chunk" ]] || continue
  count=$((count + 1))
  if "$LUAC" -p "$chunk" 2>"$tmp/err"; then
    printf 'ok   lua chunk %s compiles\n' "${chunk##*.}"
  else
    failed=$((failed + 1))
    printf 'FAIL lua chunk %s does not compile\n       %s\n' \
           "${chunk##*.}" "$(cat "$tmp/err")"
  fi
done

if (( count == 0 )); then
  echo "FAIL no chunks were produced -- the dumper is broken, not the chunks" >&2
  exit 1
fi
printf '\nlua chunks: total=%d failed=%d\n' "$count" "$failed"
(( failed == 0 ))
