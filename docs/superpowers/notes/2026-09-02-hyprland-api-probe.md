# Hyprland Lua API probe -- results

Run with `test/probe-hyprland-api.sh` on Hyprland 0.56.2 (Omarchy Quattro),
three monitors (`HDMI-A-1`, `DP-3`, `DP-4`). The script tries each form of
each dispatcher call `PROBE_TRIALS` times (default 7, override via env var)
and tallies worked / no-op / collateral per form -- these are the
instrument's own counts, produced by the loop below, not a hand tally from
re-running the script. If any call moves a window or workspace other than
the one under test, the script restores it, **verifies the restore by
reading it back**, reports the event, and stops the whole run immediately --
no further trials, no further forms, on the theory that a loop which keeps
going after the guard fired is a loop that can damage the desktop
repeatedly. This is the verbatim output of the default-settings run kept as
the record (the first of three default-settings runs performed today, all
three of which show the identical pattern -- see the safety section below):

```
=== Q1: does Lua state survive across separate eval calls? ===
  ..  second eval saw _G.__probe = 4711
PASS  Q1: state persists -- rule handles can live in _G

=== Q2 + Q3: need a real window ===
  ..  focused monitor (where an unmatched window lands by default): HDMI-A-1
  ..  Q2 target monitor (unfocused, so it differs from the focused monitor HDMI-A-1 and any effect can only come from the rule): DP-3
  ..  probe window address = 0x55a061af9040
  ..  window opened on monitor DP-3 (rule asked for DP-3; focused/default monitor was HDMI-A-1)
PASS  Q2: window_rule honours a monitor field

  ..  using workspace 51 as the disposable alternate target (verified not currently in use)
Q3 -- per-form tallies, up to 7 trials each (target alternates 50/51 so a hit can't be a leftover):
      eval + plain address string                                0/7 worked, 7 no-op, 0 collateral
  !!  SAFETY: this call moved an unrelated window (0x55a061872770) from workspace 9 to 51 -- restored and VERIFIED back on workspace 9
      eval + hl.get_window() object                              1/2 worked, 0 no-op, 1 collateral
FAIL  Q3: ABORTED after a collateral-movement event -- Q3 form 'eval + hl.get_window() object', trial 2: window 0x55a061872770 moved 9->51, restored and verified back on 9.
  ..  no further trials or forms will run this session

INCONCLUSIVE  Q3b: skipped -- the run already aborted after a collateral-movement event

  ..  probe window closed (pid 3642535 terminated, verified gone from hyprctl -j clients)
```

Every run was verified clean afterwards: no leftover `omarchy-autostart-probe`
window, no leftover workspace >= 50, and the collaterally-moved window back
on its original workspace, confirmed against `hyprctl -j clients` after the
script exited, not just from the script's own claim.

## Q1 -- Lua state across separate `eval` calls

PASS: a second, independent `hyprctl eval` call saw the value a first call
wrote into `_G`. Task 9 can hold its rule handles in
`_G.__smartalb_autostart` and use them on re-apply/disable instead of the
name-based fallback.

## Q2 -- does `hl.window_rule()`'s `monitor` field work

PASS, but the first PASS this probe ever recorded for Q2 was not a real
measurement: the target monitor had been picked by array position
(`monitors[1]`), and on this machine array position 1 happened to be the
*focused* monitor -- exactly where an unmatched window lands by default
anyway. That PASS could not distinguish "the rule worked" from "nothing
worked and it landed there regardless".

Fixed: the probe now reads each monitor's `focused` flag and targets the
rule at a monitor that is explicitly **not** focused, so the rule is the
only thing that can explain the window landing there. Re-measured this way,
`hl.window_rule({ ..., monitor = 'DP-3' })` set before the window opened
(while `HDMI-A-1` was focused) still made the window land on `DP-3`, PASS,
reproduced identically across all three runs performed today. Task 9 can
rely on `window_rule`'s `monitor` field directly for monitor placement, the
same way it already relies on `workspace`. (`HL.WindowRuleSpec` in
`/usr/share/hypr/stubs/hl.meta.lua` declares only `enabled?`, `match?` and
`name?` -- no `monitor`, and not even `workspace` -- so this remains
undocumented behaviour, confirmed only by measurement, not by the stub.)

If this machine ever has only one monitor, or every monitor reports
`focused = true`, Q2 cannot be isolated from default placement at all; the
probe reports that case as `INCONCLUSIVE` (not PASS, not FAIL) and Task 9
must then treat `monitor` as unproven rather than working.

## Q3 -- moving a specific, already-open window

**Revised conclusion.** The previous version of these notes recommended one
specific form (`eval` + `hl.get_window(addr)`) as "the reliable form" based
on 7/7 across several separate single-trial runs. Running the *same* form
repeatedly, back to back, inside one script run (as `PROBE_TRIALS` now
does) surfaced something that separate single-trial runs never could: **that
form is not safe either.** In all three default-settings runs performed
today, it worked cleanly on its first trial and then, on its *second* trial
in the same run, silently moved a different real window (Chatterbox, then two
different Termpane windows across the three runs) instead of the probe
window. Every one of these was caught, restored, and the restore verified
by reading the window back off `hyprctl -j clients`; the run then stopped
itself per the abort rule below.

Because the abort rule (see the safety section) stops the whole run on the
first collateral event, no default-settings run has yet completed all four
forms' full `PROBE_TRIALS`. The tallies actually gathered, from the run
shown above (identical in shape across all three runs -- only the specific
collaterally-moved window differs):

| form | this run's tally |
| --- | --- |
| `eval` + plain address string | 0/7 worked, 7/7 no-op, 0 collateral -- consistently a safe no-op |
| `eval` + `hl.get_window(addr)` object | 1/2 worked, 0/2 no-op, 1/2 collateral -- **worked once, then moved a different real window; run aborted here** |
| `dispatch` (bare) + plain address string | not reached (run aborted first) |
| `dispatch` (bare) + `hl.get_window(addr)` object | not reached by default (also gated off, see below) |

**There is now no form of `window.move` this probe can call "safe".** The
plain-address-string forms are reliable no-ops (never move anything, in 21
total trials across the three runs' `eval`+string tests: 7+7+7 = 21, all
no-op, 0 collateral) but are therefore useless. The object form is the only
one that ever moves the window, and it has now caused collateral movement
on **three separate occasions**, on **both** verbs across this
investigation's full history (`dispatch` in the previous round, `eval` in
this one) -- always by the second call to `hl.get_window()` with the same
address in short succession. That timing detail matters: Task 11's
reconcile step calls this once per window per reconcile pass, not in a
tight repeated loop, so this may be less likely to bite there than it is in
this probe's own trial loop -- but "less likely" is not "safe", and nothing
measured here proves the single-call case is clean.

**Consequence for Task 9 and Task 11: never call a `window`-selecting
dispatcher (`hl.dsp.window.move`, and by the same logic anything else in
`hl.dsp.window.*` or `hl.dsp.group.*` that takes a `window` field) without
wrapping it in exactly the guard this probe now uses** -- snapshot before,
snapshot after, verify by reading the actual state back, restore-and-verify
anything unexpected. Do not trust a single `hyprctl eval`/`dispatch` call's
`ok` response, and do not trust that a form which worked in isolated,
single-trial testing stays safe under repetition. This replaces the earlier
"copy this one form verbatim" recommendation, which the trial data no
longer supports.

## Q3b -- moving an already-existing workspace to another monitor

Not reached in any of today's three default-settings runs: the abort rule
stops the whole run (including Q3b) on the first collateral event, and all
three runs hit one during Q3. `test/probe-hyprland-api.sh`'s own Q3b tallies
for today are therefore all `INCONCLUSIVE: skipped -- the run already
aborted after a collateral-movement event` -- not a measurement of Q3b
itself.

The last actual measurement of Q3b is from the previous round of this fix
(2026-09-02, before the trial-loop/abort redesign, still the same day): both
`dispatch` (bare) and `eval` + `hl.dispatch(...)` moved workspace 50 to the
requested monitor, 7 times out of 7 each, across seven single-trial runs,
with no flakiness and no collateral movement of any other workspace
observed at the time. That evidence stands, but it predates both the
tighter trial-in-one-run methodology and the discovery (above) that the
*window*-move object form is not reliably safe under repetition -- Q3b's own
forms take no `window` selector at all (only workspace id and monitor name,
both plain strings), so the mechanism that caused Q3's collateral events
does not obviously apply, but this has not been re-confirmed under the
current, more rigorous protocol. Task 11 should treat Q3b's "both verbs
work" as carried-forward, dated evidence, not as re-verified today, and
should still wrap any `workspace.move` call in the same before/after guard
as a matter of course.

## Safety finding: an unresolved `window` selector does not reliably no-op, and this is worse than first documented

This is the most important thing this probe found beyond the four graded
questions, because it changed the probe script itself, not just the notes,
twice.

**Round 1** (previous version of these notes): a background watch of every
window's workspace, polled every 0.1-0.15 s throughout a run, caught the
user's real Modelbox window silently moving to a scratch workspace during
a `dispatch`-verb, object-selector `window.move` call whose own target (the
probe window) did not move. A second real window, found displaced from an
earlier, uninstrumented run, was restored by hand.

**Round 2** (today): running the *same* form repeatedly inside one script
run -- which trial-based measurement requires -- showed the collateral
hazard is not specific to the `dispatch` verb or to a "wrong" form choice.
The `eval` + `hl.get_window(addr)` object form, previously documented as
"the reliable one", produced the identical failure mode on its second
successive call in three separate runs. Both restores in round 1 were done
by hand, unverified beyond a subsequent manual check; every restore in round
2 is done by the script itself and is read back from `hyprctl` before being
reported, closing that gap.

Separately, `hl.get_window(addr)` was also directly observed returning
`nil` for an address that `hl.get_windows()` (the bulk listing) resolved
correctly moments later, for two different real windows in two different
moments. `get_window` is not fully reliable in either direction: it can
resolve to nothing when the window exists, and (per the collateral events)
it can seemingly resolve to the *wrong* window rather than the one asked
for. A restore that depends on finding the right window looks it up via
`hl.get_windows()` and filters by address, never via `get_window()`.

Because of this, `test/probe-hyprland-api.sh` wraps **every** dispatcher
call that could move a window or a workspace in a before/after snapshot of
every client's workspace (or every workspace's monitor, for the Q3b calls).
If anything other than the thing under test changed, the guard:

1. restores it via the `get_windows()`-filter lookup (never `get_window()`),
2. **reads the result back** and only reports "restored" if the readback
   confirms it -- if the readback disagrees, it prints an unmissable
   `MANUAL FIX NEEDED` line (via both `warn` and the normal `fail` output
   channel) naming the window/workspace, where it belongs, and where it
   was last seen, so a human can finish the job,
3. and then **stops the whole run** -- no further trials of the current
   form, no further forms, no Q3b if the event happened during Q3. Seven
   trials across up to four forms is a lot of chances to touch the user's
   desktop; a loop that keeps going after the guard fired is a loop that
   can do this repeatedly instead of once.

This guard is a permanent part of the committed script, not a one-off
manual fix, because the script may be run again later by whoever implements
Task 11, on their own desktop, without anyone watching for collateral
damage the way this investigation did.

**The bare-`dispatch` + `hl.get_window(addr)` object form for `window.move`
is no longer run by default.** Its danger was established and documented in
round 1 (2026-09-02); re-confirming it on every future run is a hazard for
no new information, so it is now gated behind `PROBE_INCLUDE_DANGEROUS_FORM=1`.
The one-off measurement that established this stands as recorded above: 2026-09-02,
observed unsafe on at least one of several single-trial runs that day. Set
`PROBE_INCLUDE_DANGEROUS_FORM=1` when running the script to include it
again deliberately (for example, if Hyprland is upgraded and someone wants
to check whether the behaviour changed).

**Known limitation of the guard**: a before/after snapshot diff cannot tell
"this hyprctl call moved the window" apart from "the user moved it by hand,
or some other process moved it, in the same ~0.4-0.8 s window between the
two snapshots". On this machine, which is the user's live, actively-used
desktop, that possibility is real, not theoretical. This is an accepted
trade-off for this probe, not a bug to fix: the alternative (a much longer
observation window, or pausing all other activity) is not available to a
script that has to share the machine with its user. Nobody should read a
future `SAFETY: ...` line from this script as unconditional proof that the
dispatcher call -- rather than something else running on the desktop at the
same moment -- caused the move; it is the best attribution a snapshot diff
can offer, and it restores either way.

## Cleanup finding: `window.close` and the plain-string `window` selector

Not one of the four graded questions, but relevant to any later task that
needs to close/kill a specific window via the Lua API rather than the
process itself.

`hl.dsp.window.close({ window = addr })`, with `addr` given as a **plain
address string**, answered `ok` via both `eval` and `dispatch` but did not
close the window -- the window was still present in `hyprctl -j clients`
afterwards. That is the precise finding: **`window.move` honours
`window = hl.get_window(addr)` (an object), and `window.close` did not act
on a plain address string; whether `window.close` would honour the object
form was tested separately** (outside the committed probe run, on a scratch
window) and it did: `hl.dispatch(hl.dsp.window.close({ window =
hl.get_window(addr) }))` closed the window. So the object-vs-string
distinction, not "close ignores its window field", is the real lesson --
the committed probe script does not rely on this, though, because a
PID-based `kill` is simpler and does not depend on it, and (per the safety
finding above) does not risk closing the wrong window either.

The legacy fallback that was tried before that finding,
`hyprctl dispatch closewindow "address:$addr"`, did not silently no-op --
it answered with a Lua syntax error (`')' expected near 'address'`, with
a note that `dispatch` in Lua is shorthand for `hl.dispatch(...)`). That is
a second confirmed case, alongside `hyprctl keyword`, of the switch to the
Lua config making a legacy (non-Lua) dispatcher syntax inert under `eval`
and `dispatch`.

Because of this, the committed script no longer asks a Hyprland dispatcher
to end the probe window at all: it reads `.pid` for the window's address
out of `hyprctl -j clients` (the script started the process itself) and
kills that PID directly, then polls `hyprctl -j clients` for up to ~3 s to
confirm the window is actually gone before claiming so -- and reports a
`FAIL` with the PID for manual cleanup if it is not.
