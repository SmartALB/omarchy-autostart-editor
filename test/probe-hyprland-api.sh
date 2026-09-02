#!/usr/bin/env bash
# Answers the three open Hyprland API questions from the design spec.
# Read-only with respect to the user's configuration: it creates one throwaway
# terminal window, moves it, and closes it again. Every rule it sets is inert
# (a class nobody uses) or scoped to the throwaway window, and all of them
# vanish at the next Hyprland start because they live in no file.
set -uo pipefail

PROBE_CLASS="omarchy-autostart-probe"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; }
info() { printf '  ..  %s\n' "$1"; }

echo "=== Q1: does Lua state survive across separate eval calls? ==="
# Reading a value back out of eval is not possible directly -- eval answers
# only "ok". So Lua writes to a file, which also tells us whether io is
# available inside the eval context at all.
hyprctl eval "_G.__probe = 4711" >/dev/null
hyprctl eval "local f = io.open('$OUT/q1', 'w'); if f then f:write(tostring(_G.__probe)); f:close() end" >/dev/null
if [[ ! -e "$OUT/q1" ]]; then
  fail "Q1 inconclusive: Lua could not write a file (io unavailable in eval?)"
else
  got="$(cat "$OUT/q1")"
  info "second eval saw _G.__probe = $got"
  [[ "$got" == "4711" ]] && pass "Q1: state persists -- rule handles can live in _G" \
                          || fail "Q1: state does NOT persist -- use the name-based fallback"
fi

echo
echo "=== Q2 + Q3: need a real window ==="
MON2="$(hyprctl -j monitors | jq -r '.[1].name // .[0].name')"
MON1="$(hyprctl -j monitors | jq -r '.[0].name')"
info "monitors: first=$MON1 second=$MON2"

# The monitor rule must exist BEFORE the window opens -- window rules are
# evaluated at map time, which is exactly why the plugin needs a reconcile
# step for windows that are already open.
hyprctl eval "hl.window_rule({ name = 'probe-mon', match = { class = '^($PROBE_CLASS)\$' }, monitor = '$MON2' })" >/dev/null

setsid uwsm-app -- termpane --class "$PROBE_CLASS" -e sleep 120 </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 40); do
  addr="$(hyprctl -j clients | jq -r --arg c "$PROBE_CLASS" '.[] | select(.class == $c) | .address' | head -1)"
  [[ -n "$addr" && "$addr" != "null" ]] && break
  sleep 0.25
done

if [[ -z "${addr:-}" || "$addr" == "null" ]]; then
  fail "Q2/Q3 inconclusive: the probe window never appeared"
  exit 1
fi
info "probe window address = $addr"

landed="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .monitor')"
landed_name="$(hyprctl -j monitors | jq -r --argjson i "$landed" '.[] | select(.id == $i) | .name')"
info "window opened on monitor $landed_name (rule asked for $MON2)"
[[ "$landed_name" == "$MON2" ]] && pass "Q2: window_rule honours a monitor field" \
                                || fail "Q2: monitor field ignored -- placement kind 'monitor' needs another route"

echo
# Q3: move this specific window, not the active one. Try the plausible forms
# in order and stop at the first that actually changes the workspace.
# Workspace 50, not 4: the probe moves this workspace to another monitor, and
# workspace 4 may hold the user's own windows. 50 comes into existence holding
# nothing but the probe window and disappears with it.
target_ws=50
moved=""
# Both verbs, because they are not interchangeable: eval runs a Lua chunk,
# dispatch takes a dispatcher expression. Notes from 2026-08-28 record
# `hyprctl dispatch 'hl.dsp.workspace.move({ workspace = "1", monitor = "DP-4" })'`
# working, so dispatch is the likelier of the two -- but the window variant
# needs its own answer.
for verb_form in \
  "eval|hl.dispatch(hl.dsp.window.move({ workspace = '$target_ws', window = '$addr', follow = false }))" \
  "eval|hl.dispatch(hl.dsp.window.move({ workspace = '$target_ws', window = hl.get_window('$addr'), follow = false }))" \
  "dispatch|hl.dsp.window.move({ workspace = '$target_ws', window = '$addr', follow = false })" \
  "dispatch|hl.dsp.window.move({ workspace = '$target_ws', window = hl.get_window('$addr'), follow = false })"
do
  verb="${verb_form%%|*}"
  form="${verb_form#*|}"
  hyprctl "$verb" "$form" >/dev/null 2>&1
  sleep 0.4
  now="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
  if [[ "$now" == "$target_ws" ]]; then moved="hyprctl $verb -- $form"; break; fi
done

# The workspace move has its own answer, and the same window is a fine probe
# for it: workspace 50 now exists and holds only the probe window, so moving it
# disturbs nothing of the user's.
ws_moved="no"
for verb in dispatch eval; do
  expr="hl.dsp.workspace.move({ workspace = '$target_ws', monitor = '$MON1' })"
  [[ "$verb" == "eval" ]] && expr="hl.dispatch($expr)"
  hyprctl "$verb" "$expr" >/dev/null 2>&1
  sleep 0.4
  on="$(hyprctl -j workspaces | jq -r --argjson w "$target_ws" '.[] | select(.id == $w) | .monitor')"
  if [[ "$on" == "$MON1" ]]; then ws_moved="hyprctl $verb -- $expr"; break; fi
done
if [[ "$ws_moved" != "no" ]]; then
  pass "Q3b: this form moves an existing workspace to another monitor:"
  printf '      %s\n' "$ws_moved"
else
  fail "Q3b: no form moved workspace $target_ws -- reconcile cannot move workspaces"
fi

if [[ -n "$moved" ]]; then
  pass "Q3: this form moves a specific window:"
  printf '      %s\n' "$moved"
else
  fail "Q3: none of the three forms moved it -- fall back to focus-then-move"
  info "fallback to try by hand: hl.dsp.focus({ window = '<addr>' }) then hl.dsp.window.move({ workspace = 'N' })"
fi

echo
# Hyprland dispatchers are not needed to end this window -- the script started
# it itself, so hyprctl -j clients' .pid is enough to kill it directly. This
# also sidesteps the Lua API's "ok" fallacy on window.close/closewindow: eval
# and dispatch both answered "ok" for those without moving the needle (see
# the notes file), so this is not a trust-the-verb close, it is a checked one.
close_pid="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .pid')"
if [[ -z "$close_pid" || "$close_pid" == "null" ]]; then
  fail "could not find a pid for $addr -- probe window needs manual cleanup"
else
  kill "$close_pid" 2>/dev/null
  closed="no"
  for _ in $(seq 1 12); do
    still="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .address')"
    [[ -z "$still" ]] && { closed="yes"; break; }
    sleep 0.25
  done
  if [[ "$closed" == "yes" ]]; then
    info "probe window closed (pid $close_pid terminated, verified gone from hyprctl -j clients)"
  else
    fail "probe window still present after kill $close_pid -- needs manual cleanup"
  fi
fi
