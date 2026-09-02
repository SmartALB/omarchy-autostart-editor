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
# Absolute paths, verified by actually running the candidate -- the same
# shape as the Qt6 resolution below, not a PATH lookup. A `luac` alias or
# wrapper earlier in PATH than the real binary would otherwise be trusted
# without ever being asked to prove it works.
for candidate in /usr/bin/luac5.1 /usr/bin/luac /usr/bin/luac5.4; do
  [[ -x "$candidate" ]] || continue
  "$candidate" -v 2>&1 | grep -q "^Lua " && { LUAC="$candidate"; break; }
done
if [[ -z "$LUAC" ]]; then
  echo "error: no working Lua compiler found (tried /usr/bin/luac5.1, /usr/bin/luac, /usr/bin/luac5.4)." >&2
  echo "       install lua51 -- it is part of omarchy-base.packages." >&2
  exit 2
fi

QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  "$candidate" --version 2>&1 | grep -q "Qml Runtime 6" && { QML="$candidate"; break; }
done
[[ -n "$QML" ]] || { echo "error: no Qt6 qml runtime found." >&2; exit 2; }

DEFAULT_CONFIG='{"schemaVersion":1,
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

# The default config above yields exactly two chunks: the reset block plus
# one rule block, because its five rule statements (three window rules, two
# workspace rules) fit under the 20-rule cap in a single chunk. That leaves
# the chunk-boundary behaviour -- a second CHUNK_PRELUDE, its own "end", the
# packing arithmetic at the seam -- exercised only in JavaScript (the
# 200-program stress test in harness.qml), never by a real compiler. 25
# programs, each with a distinct class so validate() never blocks any of
# them on a class conflict, pushes the 20-rule cap once: chunk 1 gets 20
# rules, chunk 2 gets the remaining 5, for three chunks total including the
# reset block. Measured, not assumed -- see task-9-report.md.
build_many_config() {
  local i entries=()
  for ((i = 1; i <= 25; i++)); do
    entries+=("{\"id\":\"p$i\",\"name\":\"Prog $i\",\"enabled\":true,\"command\":\"cmd$i\",\"class\":\"^(prog$i)\$\",\"placement\":{\"kind\":\"workspace\",\"value\":\"6\"}}")
  done
  local joined
  joined="$(IFS=,; echo "${entries[*]}")"
  printf '{"schemaVersion":1,"programs":[%s],"workspaces":[]}' "$joined"
}

# Argument handling: no argument runs the default config above; the literal
# word "many" runs the built-in 25-program config; anything else is taken
# as a caller-supplied JSON config, for ad-hoc manual runs.
case "${1:-}" in
  "")     CONFIG="$DEFAULT_CONFIG" ;;
  many)   CONFIG="$(build_many_config)" ;;
  *)      CONFIG="$1" ;;
esac

# teardown_sandbox (lib.sh) now restores TMPDIR itself, so this script does
# not depend on it any more when it runs as part of run-tests.sh. Kept as
# belt-and-braces anyway: this script can also be invoked directly, outside
# run-tests.sh, from a shell whose TMPDIR is someone else's business and may
# point anywhere. Force /tmp here regardless of who called it or why.
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
