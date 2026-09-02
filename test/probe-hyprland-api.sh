#!/usr/bin/env bash
# Answers the three open Hyprland API questions from the design spec.
# Read-only with respect to the user's configuration: it creates one throwaway
# terminal window, moves it, and closes it again. Every rule it sets is inert
# (a class nobody uses) or scoped to the throwaway window, and all of them
# vanish at the next Hyprland start because they live in no file.
#
# Safety net: testing showed that a window.move call whose "window" selector
# does not resolve does NOT reliably no-op -- on this machine it silently
# moved an unrelated, real window instead (see the notes file). Every
# dispatcher call below is therefore bracketed by a full before/after
# snapshot of every window's workspace; if anything other than the probe
# window moved, it is restored immediately and the event is reported, not
# swallowed into a plain "did not work".
set -uo pipefail

PROBE_CLASS="omarchy-autostart-probe"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

pass()   { printf 'PASS  %s\n' "$1"; }
fail()   { printf 'FAIL  %s\n' "$1"; }
inconc() { printf 'INCONCLUSIVE  %s\n' "$1"; }
info()   { printf '  ..  %s\n' "$1"; }
warn()   { printf '  !!  %s\n' "$1" >&2; }  # stderr: guard_* below capture stdout for their yes/no signal

snapshot_client_ws() { hyprctl -j clients | jq -c '[.[] | {addr: .address, ws: .workspace.id}]'; }
snapshot_ws_mon()    { hyprctl -j workspaces | jq -c '[.[] | {id: .id, mon: .monitor}]'; }

# Restores one window's workspace using get_windows()+filter rather than
# get_window(addr) -- get_window(addr) proved flaky on this machine (nil for
# an address that get_windows() lists fine), so the bulk lookup is the
# reliable path for a targeted restore.
restore_window_ws() {
  local addr="$1" ws="$2"
  hyprctl eval "hl.dispatch(hl.dsp.window.move({ workspace = '$ws', window = (function() for _,w in ipairs(hl.get_windows()) do if w.address == '$addr' then return w end end end)(), follow = false }))" >/dev/null 2>&1
}

restore_ws_mon() {
  local ws="$1" mon="$2"
  hyprctl dispatch "hl.dsp.workspace.move({ workspace = '$ws', monitor = '$mon' })" >/dev/null 2>&1
}

# Compares a client-workspace snapshot to the current state, excluding
# $exclude_addr (the probe window, whose workspace is expected to change).
# Prints a JSON array of {addr, before, after} for anything else that moved,
# and restores each one immediately.
guard_clients() {
  local exclude="$1" before="$2" after collateral
  after="$(snapshot_client_ws)"
  collateral="$(jq -n -c --argjson b "$before" --argjson a "$after" --arg ex "$exclude" '
    ($b | map({(.addr): .ws}) | add // {}) as $bm |
    ($a | map({(.addr): .ws}) | add // {}) as $am |
    [ ($bm|keys[]) as $k | select($k != $ex) | select($am[$k] != null) | select($bm[$k] != $am[$k]) | {addr:$k, before:$bm[$k], after:$am[$k]} ]
  ')"
  if [[ "$(jq 'length' <<<"$collateral")" -gt 0 ]]; then
    while IFS= read -r row; do
      c_addr="$(jq -r '.addr' <<<"$row")"
      c_before="$(jq -r '.before' <<<"$row")"
      c_after="$(jq -r '.after' <<<"$row")"
      warn "SAFETY: this call moved an unrelated window ($c_addr) from workspace $c_before to $c_after -- restoring it now"
      restore_window_ws "$c_addr" "$c_before"
    done < <(jq -c '.[]' <<<"$collateral")
    echo "yes"
  else
    echo "no"
  fi
}

guard_workspaces() {
  local exclude_ws="$1" before="$2" after collateral
  after="$(snapshot_ws_mon)"
  collateral="$(jq -n -c --argjson b "$before" --argjson a "$after" --arg ex "$exclude_ws" '
    ($b | map({(.id|tostring): .mon}) | add // {}) as $bm |
    ($a | map({(.id|tostring): .mon}) | add // {}) as $am |
    [ ($bm|keys[]) as $k | select($k != $ex) | select($am[$k] != null) | select($bm[$k] != $am[$k]) | {id:$k, before:$bm[$k], after:$am[$k]} ]
  ')"
  if [[ "$(jq 'length' <<<"$collateral")" -gt 0 ]]; then
    while IFS= read -r row; do
      c_id="$(jq -r '.id' <<<"$row")"
      c_before="$(jq -r '.before' <<<"$row")"
      c_after="$(jq -r '.after' <<<"$row")"
      warn "SAFETY: this call moved an unrelated workspace ($c_id) from monitor $c_before to $c_after -- restoring it now"
      restore_ws_mon "$c_id" "$c_before"
    done < <(jq -c '.[]' <<<"$collateral")
    echo "yes"
  else
    echo "no"
  fi
}

echo "=== Q1: does Lua state survive across separate eval calls? ==="
# Reading a value back out of eval is not possible directly -- eval answers
# only "ok". So Lua writes to a file, which also tells us whether io is
# available inside the eval context at all.
hyprctl eval "_G.__probe = 4711" >/dev/null
hyprctl eval "local f = io.open('$OUT/q1', 'w'); if f then f:write(tostring(_G.__probe)); f:close() end" >/dev/null
if [[ ! -e "$OUT/q1" ]]; then
  inconc "Q1: Lua could not write a file (io unavailable in eval?) -- the instrument, not Hyprland, is broken; fix the probe before trusting any other answer"
else
  got="$(cat "$OUT/q1")"
  info "second eval saw _G.__probe = $got"
  [[ "$got" == "4711" ]] && pass "Q1: state persists -- rule handles can live in _G" \
                          || fail "Q1: state does NOT persist -- use the name-based fallback"
fi

echo
echo "=== Q2 + Q3: need a real window ==="
# Q2 must isolate the rule as the only possible cause: an unmatched new
# window lands on the currently focused monitor's active workspace by
# default, so the rule's target has to be a monitor that is NOT focused --
# otherwise a PASS could just be Hyprland's default placement agreeing with
# the rule by coincidence, which is exactly what happened the first time
# this probe ran (position-1-in-the-array != "not focused").
FOCUSED_MON="$(hyprctl -j monitors | jq -r '.[] | select(.focused == true) | .name' | head -1)"
TARGET_MON="$(hyprctl -j monitors | jq -r '.[] | select(.focused == false) | .name' | head -1)"
info "focused monitor (where an unmatched window lands by default): ${FOCUSED_MON:-<none reported>}"

q2_measurable="yes"
if [[ -z "$FOCUSED_MON" || -z "$TARGET_MON" ]]; then
  q2_measurable="no"
  inconc "Q2 inconclusive-by-environment: every monitor is focused, or there is only one monitor -- an unmatched window and a rule-targeted window would land in the same place here, so the rule's effect cannot be isolated on this machine. Task 9 must treat 'monitor' as unproven, not as passing."
else
  info "Q2 target monitor (unfocused, so it differs from the focused monitor $FOCUSED_MON and any effect can only come from the rule): $TARGET_MON"
fi

# The monitor rule must exist BEFORE the window opens -- window rules are
# evaluated at map time, which is exactly why the plugin needs a reconcile
# step for windows that are already open.
if [[ "$q2_measurable" == "yes" ]]; then
  hyprctl eval "hl.window_rule({ name = 'probe-mon', match = { class = '^($PROBE_CLASS)\$' }, monitor = '$TARGET_MON' })" >/dev/null
fi

setsid uwsm-app -- termpane --class "$PROBE_CLASS" -e sleep 120 </dev/null >/dev/null 2>&1 &
launch_pid=$!
for _ in $(seq 1 40); do
  addr="$(hyprctl -j clients | jq -r --arg c "$PROBE_CLASS" '.[] | select(.class == $c) | .address' | head -1)"
  [[ -n "$addr" && "$addr" != "null" ]] && break
  sleep 0.25
done

if [[ -z "${addr:-}" || "$addr" == "null" ]]; then
  inconc "Q2/Q3: the probe window never appeared -- the instrument, not Hyprland, is broken"
  # setsid made $launch_pid the process group leader, so this reaches
  # uwsm-app/termpane/sleep regardless of how they forked -- no orphan left
  # behind even though no window ever mapped for us to find a pid through.
  kill -- -"$launch_pid" 2>/dev/null
  sleep 0.5
  kill -9 -- -"$launch_pid" 2>/dev/null
  info "cleaned up the launched process group (pgid $launch_pid)"
  exit 1
fi
info "probe window address = $addr"

if [[ "$q2_measurable" == "yes" ]]; then
  landed="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .monitor')"
  landed_name="$(hyprctl -j monitors | jq -r --argjson i "$landed" '.[] | select(.id == $i) | .name')"
  info "window opened on monitor $landed_name (rule asked for $TARGET_MON; focused/default monitor was $FOCUSED_MON)"
  [[ "$landed_name" == "$TARGET_MON" ]] && pass "Q2: window_rule honours a monitor field" \
                                        || fail "Q2: monitor field ignored -- placement kind 'monitor' needs another route; Task 9 must treat 'monitor' as unproven"
fi

echo
# Q3: move this specific window, not the active one. Try every plausible
# form -- no early exit -- and record whether each one actually moved it, so
# "one form works" becomes a real "these work, these do not" table instead of
# a guess based on whichever form happened to run first.
#
# Each attempt alternates its target between two disposable workspaces
# (target_ws and alt_ws) based on where the window currently is, so every
# attempt demands an actual state transition: a form that does nothing
# cannot be scored as a pass just because a *previous* attempt already
# parked the window on the workspace being asked for. Every attempt is also
# wrapped by the collateral-window guard above.
target_ws=50
# alt_ws must be genuinely unused, not just "probably" -- 51 turned out to
# already be one of the user's own workspaces on this machine. Pick the
# first id from 51 upward that hyprctl does not currently report.
existing_ws_ids="$(hyprctl -j workspaces | jq -r '.[].id')"
alt_ws=51
while grep -qx "$alt_ws" <<<"$existing_ws_ids"; do
  alt_ws=$((alt_ws + 1))
done
info "using workspace $alt_ws as the disposable alternate target (verified not currently in use)"
q3_verbs=(eval eval dispatch dispatch)
q3_templates=(
  "hl.dispatch(hl.dsp.window.move({ workspace = '__WS__', window = '$addr', follow = false }))"
  "hl.dispatch(hl.dsp.window.move({ workspace = '__WS__', window = hl.get_window('$addr'), follow = false }))"
  "hl.dsp.window.move({ workspace = '__WS__', window = '$addr', follow = false })"
  "hl.dsp.window.move({ workspace = '__WS__', window = hl.get_window('$addr'), follow = false })"
)
q3_outcomes=()
q3_any_ok=""
for i in "${!q3_templates[@]}"; do
  verb="${q3_verbs[$i]}"
  cur="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
  if [[ "$cur" == "$target_ws" ]]; then want="$alt_ws"; else want="$target_ws"; fi
  form="${q3_templates[$i]//__WS__/$want}"
  before_snap="$(snapshot_client_ws)"
  hyprctl "$verb" "$form" >/dev/null 2>&1
  sleep 0.4
  collateral="$(guard_clients "$addr" "$before_snap")"
  now="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
  if [[ "$now" == "$want" ]]; then
    q3_outcomes+=("worked        hyprctl $verb -- $form")
    q3_any_ok="yes"
  elif [[ "$collateral" == "yes" ]]; then
    q3_outcomes+=("UNSAFE (moved a different window instead, restored)  hyprctl $verb -- $form")
  else
    q3_outcomes+=("did not work  hyprctl $verb -- $form")
  fi
done

echo "Q3 -- form-by-form results (target alternates $target_ws/$alt_ws so a hit can't be a leftover):"
for line in "${q3_outcomes[@]}"; do
  printf '      %s\n' "$line"
done

# Land the window back on workspace 50 specifically for the Q3b test below --
# reusing whichever form the loop above just proved works, not a new guess.
cur="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
if [[ "$cur" != "$target_ws" && "$q3_any_ok" == "yes" ]]; then
  for i in "${!q3_outcomes[@]}"; do
    if [[ "${q3_outcomes[$i]}" == worked* ]]; then
      verb="${q3_verbs[$i]}"
      form="${q3_templates[$i]//__WS__/$target_ws}"
      before_snap="$(snapshot_client_ws)"
      hyprctl "$verb" "$form" >/dev/null 2>&1
      sleep 0.4
      guard_clients "$addr" "$before_snap" >/dev/null
      break
    fi
  done
fi

echo
# Q3b: does moving an already-existing workspace to another monitor work?
# Same principle as Q3 -- try both verbs, no early exit, and alternate the
# target monitor based on where the workspace currently is so neither
# attempt can pass by finding it already there. Same collateral guard, this
# time over every workspace's monitor assignment.
q3b_outcomes=()
q3b_any_ok="no"
if [[ "$q2_measurable" == "yes" ]]; then
  mons=("$FOCUSED_MON" "$TARGET_MON")
  for verb in dispatch eval; do
    cur_mon="$(hyprctl -j workspaces | jq -r --argjson w "$target_ws" '.[] | select(.id == $w) | .monitor')"
    if [[ "$cur_mon" == "${mons[0]}" ]]; then want="${mons[1]}"; else want="${mons[0]}"; fi
    expr="hl.dsp.workspace.move({ workspace = '$target_ws', monitor = '$want' })"
    [[ "$verb" == "eval" ]] && expr="hl.dispatch($expr)"
    before_snap="$(snapshot_ws_mon)"
    hyprctl "$verb" "$expr" >/dev/null 2>&1
    sleep 0.4
    guard_workspaces "$target_ws" "$before_snap" >/dev/null
    on="$(hyprctl -j workspaces | jq -r --argjson w "$target_ws" '.[] | select(.id == $w) | .monitor')"
    if [[ "$on" == "$want" ]]; then
      q3b_outcomes+=("worked        hyprctl $verb -- $expr")
      q3b_any_ok="yes"
    else
      q3b_outcomes+=("did not work  hyprctl $verb -- $expr")
    fi
  done
  echo "Q3b -- form-by-form results (target monitor alternates so a hit can't be a leftover):"
  for line in "${q3b_outcomes[@]}"; do
    printf '      %s\n' "$line"
  done
else
  inconc "Q3b inconclusive-by-environment: fewer than two distinct (focused/unfocused) monitors were available to move workspace $target_ws between"
fi

if [[ "$q3b_any_ok" == "yes" ]]; then
  pass "Q3b: at least one form moves an existing workspace to another monitor (see table above)"
elif [[ "$q2_measurable" == "yes" ]]; then
  fail "Q3b: no form moved workspace $target_ws -- reconcile cannot move workspaces"
fi

if [[ "$q3_any_ok" == "yes" ]]; then
  pass "Q3: at least one form moves a specific window (see table above)"
else
  fail "Q3: no form moved it -- fall back to focus-then-move"
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
