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
# snapshot of every window's workspace (or every workspace's monitor, for
# the Q3b calls); if anything other than the probe moved, it is restored
# AND THE RESTORE IS VERIFIED before anything is reported "restored". If a
# collateral event happens at all, the whole run stops right there -- no
# further trials, no further forms -- because a loop that keeps going after
# the guard fired is a loop that can damage the desktop repeatedly.
#
# Each form is tried PROBE_TRIALS times (default 7, override via env var) so
# flakiness can actually be measured instead of asserted from a single run.
# The one form already known to be dangerous (dispatch + hl.get_window()
# object for window.move -- see the notes file, measured 2026-09-02) is
# skipped by default; set PROBE_INCLUDE_DANGEROUS_FORM=1 to run it anyway.
set -uo pipefail

PROBE_CLASS="omarchy-autostart-probe"
TRIALS="${PROBE_TRIALS:-7}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

pass()   { printf 'PASS  %s\n' "$1"; }
fail()   { printf 'FAIL  %s\n' "$1"; }
inconc() { printf 'INCONCLUSIVE  %s\n' "$1"; }
info()   { printf '  ..  %s\n' "$1"; }
warn()   { printf '  !!  %s\n' "$1" >&2; }

snapshot_client_ws() { hyprctl -j clients | jq -c '[.[] | {addr: .address, ws: .workspace.id}]'; }
snapshot_ws_mon()    { hyprctl -j workspaces | jq -c '[.[] | {id: .id, mon: .monitor}]'; }

# Restores one window's workspace using get_windows()+filter rather than
# get_window(addr) -- get_window(addr) proved flaky on this machine (nil for
# an address that get_windows() lists fine moments later), so the bulk
# lookup is the reliable path for a targeted restore. Reads the result back
# out of hyprctl -j clients before claiming anything: prints "ok" if the
# window is verified back on $ws, or "FAILED:<actual>" if not.
restore_window_ws() {
  local addr="$1" ws="$2" now
  hyprctl eval "hl.dispatch(hl.dsp.window.move({ workspace = '$ws', window = (function() for _,w in ipairs(hl.get_windows()) do if w.address == '$addr' then return w end end end)(), follow = false }))" >/dev/null 2>&1
  sleep 0.4
  now="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
  if [[ "$now" == "$ws" ]]; then echo "ok"; else echo "FAILED:${now:-<window not found>}"; fi
}

restore_ws_mon() {
  local ws="$1" mon="$2" now
  hyprctl dispatch "hl.dsp.workspace.move({ workspace = '$ws', monitor = '$mon' })" >/dev/null 2>&1
  sleep 0.4
  now="$(hyprctl -j workspaces | jq -r --argjson w "$ws" '.[] | select(.id == $w) | .monitor')"
  if [[ "$now" == "$mon" ]]; then echo "ok"; else echo "FAILED:${now:-<workspace not found>}"; fi
}

# GUARD_COLLATERAL / GUARD_RESTORE_OK / GUARD_DETAIL are set by the two
# guard_* functions below. Globals, not captured via $(...), because a
# previous version of this script captured a helper's whole stdout to read
# a yes/no signal and silently swallowed its warn() messages that way --
# exactly the kind of mistake this script exists to catch elsewhere.
GUARD_COLLATERAL="no"
GUARD_RESTORE_OK="yes"
GUARD_DETAIL=""

guard_clients() {
  local exclude="$1" before="$2" after collateral n
  GUARD_COLLATERAL="no"; GUARD_RESTORE_OK="yes"; GUARD_DETAIL=""
  after="$(snapshot_client_ws)"
  collateral="$(jq -n -c --argjson b "$before" --argjson a "$after" --arg ex "$exclude" '
    ($b | map({(.addr): .ws}) | add // {}) as $bm |
    ($a | map({(.addr): .ws}) | add // {}) as $am |
    [ ($bm|keys[]) as $k | select($k != $ex) | select($am[$k] != null) | select($bm[$k] != $am[$k]) | {addr:$k, before:$bm[$k], after:$am[$k]} ]
  ')"
  n="$(jq 'length' <<<"$collateral")"
  if [[ "$n" -gt 0 ]]; then
    GUARD_COLLATERAL="yes"
    while IFS= read -r row; do
      local c_addr c_before c_after result actual
      c_addr="$(jq -r '.addr' <<<"$row")"
      c_before="$(jq -r '.before' <<<"$row")"
      c_after="$(jq -r '.after' <<<"$row")"
      result="$(restore_window_ws "$c_addr" "$c_before")"
      if [[ "$result" == "ok" ]]; then
        warn "SAFETY: this call moved an unrelated window ($c_addr) from workspace $c_before to $c_after -- restored and VERIFIED back on workspace $c_before"
        GUARD_DETAIL="${GUARD_DETAIL}window $c_addr moved $c_before->$c_after, restored and verified back on $c_before. "
      else
        actual="${result#FAILED:}"
        GUARD_RESTORE_OK="no"
        warn "SAFETY -- MANUAL FIX NEEDED: window $c_addr was moved from workspace $c_before to $c_after by this call. The automatic restore did NOT verify -- hyprctl now reports it on workspace '$actual'. Move window $c_addr to workspace $c_before by hand."
        fail "MANUAL FIX NEEDED: window $c_addr belongs on workspace $c_before, was moved to $c_after, and the automatic restore attempt did not verify -- it is now reportedly on '$actual'. Please move it by hand."
        GUARD_DETAIL="${GUARD_DETAIL}window $c_addr moved $c_before->$c_after, RESTORE NOT VERIFIED (now reportedly on '$actual') -- MANUAL FIX NEEDED. "
      fi
    done < <(jq -c '.[]' <<<"$collateral")
  fi
}

guard_workspaces() {
  local exclude_ws="$1" before="$2" after collateral n
  GUARD_COLLATERAL="no"; GUARD_RESTORE_OK="yes"; GUARD_DETAIL=""
  after="$(snapshot_ws_mon)"
  collateral="$(jq -n -c --argjson b "$before" --argjson a "$after" --arg ex "$exclude_ws" '
    ($b | map({(.id|tostring): .mon}) | add // {}) as $bm |
    ($a | map({(.id|tostring): .mon}) | add // {}) as $am |
    [ ($bm|keys[]) as $k | select($k != $ex) | select($am[$k] != null) | select($bm[$k] != $am[$k]) | {id:$k, before:$bm[$k], after:$am[$k]} ]
  ')"
  n="$(jq 'length' <<<"$collateral")"
  if [[ "$n" -gt 0 ]]; then
    GUARD_COLLATERAL="yes"
    while IFS= read -r row; do
      local c_id c_before c_after result actual
      c_id="$(jq -r '.id' <<<"$row")"
      c_before="$(jq -r '.before' <<<"$row")"
      c_after="$(jq -r '.after' <<<"$row")"
      result="$(restore_ws_mon "$c_id" "$c_before")"
      if [[ "$result" == "ok" ]]; then
        warn "SAFETY: this call moved an unrelated workspace ($c_id) from monitor $c_before to $c_after -- restored and VERIFIED back on monitor $c_before"
        GUARD_DETAIL="${GUARD_DETAIL}workspace $c_id moved $c_before->$c_after, restored and verified back on $c_before. "
      else
        actual="${result#FAILED:}"
        GUARD_RESTORE_OK="no"
        warn "SAFETY -- MANUAL FIX NEEDED: workspace $c_id was moved from monitor $c_before to $c_after by this call. The automatic restore did NOT verify -- hyprctl now reports it on monitor '$actual'. Move workspace $c_id to monitor $c_before by hand."
        fail "MANUAL FIX NEEDED: workspace $c_id belongs on monitor $c_before, was moved to $c_after, and the automatic restore attempt did not verify -- it is now reportedly on '$actual'. Please move it by hand."
        GUARD_DETAIL="${GUARD_DETAIL}workspace $c_id moved $c_before->$c_after, RESTORE NOT VERIFIED (now reportedly on '$actual') -- MANUAL FIX NEEDED. "
      fi
    done < <(jq -c '.[]' <<<"$collateral")
  fi
}

ABORT="no"
ABORT_REASON=""

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

setsid uwsm-app -- termpane --class "$PROBE_CLASS" -e sleep 180 </dev/null >/dev/null 2>&1 &
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
# Q3: move this specific window, not the active one. Each form below is
# tried $TRIALS times so flakiness is measured, not guessed; each trial
# alternates its target between two disposable workspaces (target_ws and
# alt_ws) based on where the window currently is, so a form that does
# nothing can never be scored as a pass by finding the window already
# there. The known-dangerous dispatch+object form is skipped unless
# PROBE_INCLUDE_DANGEROUS_FORM=1 (see header comment and the notes file).
target_ws=50
# alt_ws must be genuinely unused, not just "probably" -- 51 turned out to
# already be one of the user's own workspaces on this machine once. Pick the
# first id from 51 upward that hyprctl does not currently report.
existing_ws_ids="$(hyprctl -j workspaces | jq -r '.[].id')"
alt_ws=51
while grep -qx "$alt_ws" <<<"$existing_ws_ids"; do
  alt_ws=$((alt_ws + 1))
done
info "using workspace $alt_ws as the disposable alternate target (verified not currently in use)"

q3_any_ok="no"
LAST_WORKING_Q3_VERB=""
LAST_WORKING_Q3_TEMPLATE=""

# Runs one Q3 form up to $TRIALS times (fewer if the run aborts partway),
# tallies worked/no-op/collateral, and prints the tally. Aborts the whole
# run immediately on the first collateral event.
run_q3_form() {
  local label="$1" verb="$2" template="$3"
  local worked=0 noop=0 collateral=0 trial cur want form before_snap now
  for (( trial=1; trial<=TRIALS; trial++ )); do
    [[ "$ABORT" == "yes" ]] && break
    cur="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
    if [[ "$cur" == "$target_ws" ]]; then want="$alt_ws"; else want="$target_ws"; fi
    form="${template//__WS__/$want}"
    before_snap="$(snapshot_client_ws)"
    hyprctl "$verb" "$form" >/dev/null 2>&1
    sleep 0.4
    guard_clients "$addr" "$before_snap"
    if [[ "$GUARD_COLLATERAL" == "yes" ]]; then
      collateral=$((collateral + 1))
      ABORT="yes"
      ABORT_REASON="Q3 form '$label', trial $trial: $GUARD_DETAIL"
      break
    fi
    now="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
    if [[ "$now" == "$want" ]]; then
      worked=$((worked + 1))
      LAST_WORKING_Q3_VERB="$verb"
      LAST_WORKING_Q3_TEMPLATE="$template"
      q3_any_ok="yes"
    else
      noop=$((noop + 1))
    fi
  done
  local ran=$((worked + noop + collateral))
  printf '      %-58s %d/%d worked, %d no-op, %d collateral\n' "$label" "$worked" "$ran" "$noop" "$collateral"
}

echo "Q3 -- per-form tallies, up to $TRIALS trials each (target alternates $target_ws/$alt_ws so a hit can't be a leftover):"
run_q3_form "eval + plain address string" \
  eval "hl.dispatch(hl.dsp.window.move({ workspace = '__WS__', window = '$addr', follow = false }))"
[[ "$ABORT" == "no" ]] && run_q3_form "eval + hl.get_window() object" \
  eval "hl.dispatch(hl.dsp.window.move({ workspace = '__WS__', window = hl.get_window('$addr'), follow = false }))"
[[ "$ABORT" == "no" ]] && run_q3_form "dispatch + plain address string" \
  dispatch "hl.dsp.window.move({ workspace = '__WS__', window = '$addr', follow = false })"
if [[ "$ABORT" == "no" ]]; then
  if [[ "${PROBE_INCLUDE_DANGEROUS_FORM:-0}" == "1" ]]; then
    run_q3_form "dispatch + hl.get_window() object [OPT-IN, KNOWN DANGEROUS]" \
      dispatch "hl.dsp.window.move({ workspace = '__WS__', window = hl.get_window('$addr'), follow = false })"
  else
    info "skipping dispatch + hl.get_window() object for window.move: measured dangerous on 2026-09-02 (silently moved a real, unrelated window on at least one trial -- see the notes file). Set PROBE_INCLUDE_DANGEROUS_FORM=1 to re-run it deliberately."
  fi
fi

if [[ "$ABORT" == "yes" ]]; then
  fail "Q3: ABORTED after a collateral-movement event -- $ABORT_REASON"
  info "no further trials or forms will run this session"
elif [[ "$q3_any_ok" == "yes" ]]; then
  pass "Q3: at least one form moves a specific window (see tally above)"
else
  fail "Q3: no form moved it -- fall back to focus-then-move"
  info "fallback to try by hand: hl.dsp.focus({ window = '<addr>' }) then hl.dsp.window.move({ workspace = 'N' })"
fi

# Land the window back on workspace 50 specifically for the Q3b test below --
# reusing whichever form just proved it works, not a new guess. Skipped
# entirely if the run already aborted.
if [[ "$ABORT" == "no" && "$q3_any_ok" == "yes" ]]; then
  cur="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
  if [[ "$cur" != "$target_ws" ]]; then
    form="${LAST_WORKING_Q3_TEMPLATE//__WS__/$target_ws}"
    before_snap="$(snapshot_client_ws)"
    hyprctl "$LAST_WORKING_Q3_VERB" "$form" >/dev/null 2>&1
    sleep 0.4
    guard_clients "$addr" "$before_snap"
    if [[ "$GUARD_COLLATERAL" == "yes" ]]; then
      ABORT="yes"
      ABORT_REASON="landing the window back on workspace $target_ws for the Q3b setup step: $GUARD_DETAIL"
      fail "ABORTED after a collateral-movement event while setting up Q3b -- $ABORT_REASON"
    fi
  fi
fi

echo
# Q3b: does moving an already-existing workspace to another monitor work?
# Same principle as Q3: every form tried $TRIALS times, tallied, target
# monitor alternates so neither attempt can pass by finding it already
# there, same collateral guard (this time over every workspace's monitor
# assignment), same abort-on-first-collateral.
q3b_any_ok="no"

run_q3b_form() {
  local label="$1" verb="$2"
  local worked=0 noop=0 collateral=0 trial cur_mon want expr before_snap on
  for (( trial=1; trial<=TRIALS; trial++ )); do
    [[ "$ABORT" == "yes" ]] && break
    cur_mon="$(hyprctl -j workspaces | jq -r --argjson w "$target_ws" '.[] | select(.id == $w) | .monitor')"
    if [[ "$cur_mon" == "$FOCUSED_MON" ]]; then want="$TARGET_MON"; else want="$FOCUSED_MON"; fi
    expr="hl.dsp.workspace.move({ workspace = '$target_ws', monitor = '$want' })"
    [[ "$verb" == "eval" ]] && expr="hl.dispatch($expr)"
    before_snap="$(snapshot_ws_mon)"
    hyprctl "$verb" "$expr" >/dev/null 2>&1
    sleep 0.4
    guard_workspaces "$target_ws" "$before_snap"
    if [[ "$GUARD_COLLATERAL" == "yes" ]]; then
      collateral=$((collateral + 1))
      ABORT="yes"
      ABORT_REASON="Q3b form '$label', trial $trial: $GUARD_DETAIL"
      break
    fi
    on="$(hyprctl -j workspaces | jq -r --argjson w "$target_ws" '.[] | select(.id == $w) | .monitor')"
    if [[ "$on" == "$want" ]]; then
      worked=$((worked + 1))
      q3b_any_ok="yes"
    else
      noop=$((noop + 1))
    fi
  done
  local ran=$((worked + noop + collateral))
  printf '      %-58s %d/%d worked, %d no-op, %d collateral\n' "$label" "$worked" "$ran" "$noop" "$collateral"
}

if [[ "$ABORT" == "yes" ]]; then
  inconc "Q3b: skipped -- the run already aborted after a collateral-movement event"
elif [[ "$q2_measurable" == "yes" ]]; then
  echo "Q3b -- per-form tallies, up to $TRIALS trials each (target monitor alternates so a hit can't be a leftover):"
  run_q3b_form "dispatch (bare)" dispatch
  [[ "$ABORT" == "no" ]] && run_q3b_form "eval + hl.dispatch(...) wrap" eval
  if [[ "$ABORT" == "yes" ]]; then
    fail "Q3b: ABORTED after a collateral-movement event -- $ABORT_REASON"
    info "no further trials or forms will run this session"
  elif [[ "$q3b_any_ok" == "yes" ]]; then
    pass "Q3b: at least one form moves an existing workspace to another monitor (see tally above)"
  else
    fail "Q3b: no form moved workspace $target_ws -- reconcile cannot move workspaces"
  fi
else
  inconc "Q3b inconclusive-by-environment: fewer than two distinct (focused/unfocused) monitors were available to move workspace $target_ws between"
fi

echo
# Hyprland dispatchers are not needed to end this window -- the script started
# it itself, so hyprctl -j clients' .pid is enough to kill it directly. This
# also sidesteps the Lua API's "ok" fallacy on window.close/closewindow: eval
# and dispatch both answered "ok" for those without moving the needle (see
# the notes file), so this is not a trust-the-verb close, it is a checked one.
# Runs regardless of ABORT -- ending the probe's own window is unrelated to,
# and does not carry, the collateral-movement hazard (it is a plain kill by
# pid, not a Lua window selector).
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

[[ "$ABORT" == "yes" ]] && exit 1
exit 0
