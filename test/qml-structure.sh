#!/usr/bin/env bash
# Structural checks on the QML files.
#
# Runners.qml and its callers import Quickshell.Io, which does not exist
# outside the Quickshell runtime, so they cannot be executed headless. What
# CAN be held is the shape: absolute interpreters, every command through a
# helper, a producer limit on both collecting helpers, and a teardown that
# covers every declared Process. These are the five properties that closed the
# fourth review finding on smartalb.vpn v1.3.1.
set -uo pipefail
cd "$(dirname "$0")/.."

run=0; failed=0
ok()   { run=$((run+1)); printf 'ok   %s\n' "$1"; }
bad()  { run=$((run+1)); failed=$((failed+1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

qml_files() { ls -1 ./*.qml 2>/dev/null; }

# 1 -- no PATH-resolved interpreter anywhere.
hits="$(grep -nE '"(bash|sh|timeout|hyprctl|head|jq)"' ./*.qml 2>/dev/null || true)"
[[ -z "$hits" ]] && ok "no PATH-resolved interpreter in any qml file" \
                 || bad "no PATH-resolved interpreter in any qml file" "$hits"

# 2 -- the three absolute binaries are the only ones named.
for expected in /usr/bin/timeout /usr/bin/bash /usr/bin/hyprctl; do
  grep -q "\"$expected\"" Runners.qml \
    && ok "Runners.qml names $expected absolutely" \
    || bad "Runners.qml names $expected absolutely" "not found"
done

# 3 -- both collecting helpers carry a producer limit.
grep -A2 'function runnerOut' Runners.qml | grep -q 'head -c' \
  && ok "runnerOut carries a producer byte limit" \
  || bad "runnerOut carries a producer byte limit" "no head -c near runnerOut"
grep -A2 'function runnerErr' Runners.qml | grep -q 'head -c' \
  && ok "runnerErr carries a producer byte limit" \
  || bad "runnerErr carries a producer byte limit" "no head -c near runnerErr"

# 4 -- runnerErr uses process substitution, not a pipe: a pipe would replace
#      the exit status of the command, which callers read.
grep -A2 'function runnerErr' Runners.qml | grep -q '2> >(' \
  && ok "runnerErr keeps the command exit status (process substitution)" \
  || bad "runnerErr keeps the command exit status (process substitution)" "no '2> >(' found"

# 5 -- every Process command: goes through a helper, never a bare array.
hits="$(grep -nE '^\s*command:\s*\[' ./*.qml 2>/dev/null || true)"
[[ -z "$hits" ]] && ok "every Process command goes through a helper" \
                 || bad "every Process command goes through a helper" "$hits"

# 6 -- teardown covers every declared Process. A wall-clock deadline would end
#      them eventually, but "eventually" is up to two minutes of work nobody
#      is waiting for.
for file in $(qml_files); do
  ids="$(awk '/^[[:space:]]*Process[[:space:]]*\{/ {inproc=1}
              inproc && /id:[[:space:]]*[A-Za-z_]/ {
                  match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
                  s = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
                  print s; inproc=0 }' "$file")"
  [[ -z "$ids" ]] && continue
  teardown="$(awk '/Component.onDestruction/,/^[[:space:]]*\}/' "$file")"
  for id in $ids; do
    grep -q "\b$id\b" <<<"$teardown" \
      && ok "$file: teardown stops $id" \
      || bad "$file: teardown stops $id" "not mentioned in Component.onDestruction"
  done
done

# 7a -- Lua rule construction lives in Model.js only. A qml file must not
#       build rules at all; it only passes strings through. (hl.dsp. may
#       appear there -- the panel sniffs it to choose the hyprctl verb.)
hits="$(grep -nE 'hl\.(window_rule|workspace_rule)' ./*.qml 2>/dev/null || true)"
[[ -z "$hits" ]] && ok "no rule construction in any qml file" \
                 || bad "no rule construction in any qml file" "$hits"

# 7b -- and in Model.js every rule construction encodes its values via
#       luaBytes. A quoted value there would be code inside the compositor.
# Only lines that CONSTRUCT something -- an hl call immediately followed by a
# table literal. verbFor() mentions the string "hl.dsp." for a comparison and
# is not a construction, so it must not be caught here.
#
# The luaBytes() call for a construction's value is not always on the same
# source line as the "hl.foo({" opener -- windowMoveExpression() puts them on
# consecutive lines of one string concatenation. A same-line-only check is
# therefore a false positive against that (correct, already-tested) code, so
# each match is judged over a small window starting at its own line rather
# than the single line alone.
hits=""
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  lineno="${m%%:*}"
  window="$(sed -n "${lineno},$((lineno + 2))p" Model.js)"
  grep -q 'luaBytes(' <<<"$window" || hits="$hits
$m"
done < <(grep -nE 'hl\.(window_rule|workspace_rule|dsp\.[a-z_.]+)\(\{' Model.js 2>/dev/null || true)
hits="$(sed '/^$/d' <<<"$hits")"
[[ -z "$hits" ]] && ok "every rule-building line in Model.js uses luaBytes" \
                 || bad "every rule-building line in Model.js uses luaBytes" "$hits"

printf '\nqml structure: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
