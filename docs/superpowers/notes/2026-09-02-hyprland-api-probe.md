# Hyprland Lua API probe -- results

Run with `test/probe-hyprland-api.sh` on Hyprland 0.56.2 (Omarchy Quattro),
three monitors (`HDMI-A-1`, `DP-3`, `DP-4`). This is the verbatim output of
the final, hardened version of the script (the one with the collateral-move
safety net described below -- it is chosen as the record run because it is
also the run where that safety net actually caught and fixed a real
collateral event, which is itself part of what this probe found):

```
=== Q1: does Lua state survive across separate eval calls? ===
  ..  second eval saw _G.__probe = 4711
PASS  Q1: state persists -- rule handles can live in _G

=== Q2 + Q3: need a real window ===
  ..  focused monitor (where an unmatched window lands by default): HDMI-A-1
  ..  Q2 target monitor (unfocused, so it differs from the focused monitor HDMI-A-1 and any effect can only come from the rule): DP-3
  ..  probe window address = 0x55a061c7cc10
  ..  window opened on monitor DP-3 (rule asked for DP-3; focused/default monitor was HDMI-A-1)
PASS  Q2: window_rule honours a monitor field

  ..  using workspace 51 as the disposable alternate target (verified not currently in use)
  !!  SAFETY: this call moved an unrelated window (0x55a0618b74a0) from workspace 10 to 51 -- restoring it now
Q3 -- form-by-form results (target alternates 50/51 so a hit can't be a leftover):
      did not work  hyprctl eval -- hl.dispatch(hl.dsp.window.move({ workspace = '50', window = '0x55a061c7cc10', follow = false }))
      worked        hyprctl eval -- hl.dispatch(hl.dsp.window.move({ workspace = '50', window = hl.get_window('0x55a061c7cc10'), follow = false }))
      did not work  hyprctl dispatch -- hl.dsp.window.move({ workspace = '51', window = '0x55a061c7cc10', follow = false })
      UNSAFE (moved a different window instead, restored)  hyprctl dispatch -- hl.dsp.window.move({ workspace = '51', window = hl.get_window('0x55a061c7cc10'), follow = false })

Q3b -- form-by-form results (target monitor alternates so a hit can't be a leftover):
      worked        hyprctl dispatch -- hl.dsp.workspace.move({ workspace = '50', monitor = 'HDMI-A-1' })
      worked        hyprctl eval -- hl.dispatch(hl.dsp.workspace.move({ workspace = '50', monitor = 'DP-3' }))
PASS  Q3b: at least one form moves an existing workspace to another monitor (see table above)
PASS  Q3: at least one form moves a specific window (see table above)

  ..  probe window closed (pid 3561327 terminated, verified gone from hyprctl -j clients)
```

Every run described below was verified clean afterwards: no leftover
`omarchy-autostart-probe` window, no leftover workspace >= 50, and (after
the safety net below existed) no other window left on the wrong workspace.

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
(while `HDMI-A-1` was focused) still made the window land on `DP-3`, PASS.
Task 9 can rely on `window_rule`'s `monitor` field directly for monitor
placement, the same way it already relies on `workspace`. (`HL.WindowRuleSpec`
in `/usr/share/hypr/stubs/hl.meta.lua` declares only `enabled?`, `match?` and
`name?` -- no `monitor`, and not even `workspace` -- so this remains
undocumented behaviour, confirmed only by measurement, not by the stub.)

If this machine ever has only one monitor, or every monitor reports
`focused = true`, Q2 cannot be isolated from default placement at all; the
probe reports that case as `INCONCLUSIVE` (not PASS, not FAIL) and Task 9
must then treat `monitor` as unproven rather than working.

## Q3 -- moving a specific, already-open window

The `break`-on-first-success from the first version of this probe was
removed. All four forms are now tried on every run, each one required to
cause an actual state transition (the target alternates between workspace
50 and a second, dynamically-verified-unused workspace, so a form that does
nothing can never be scored as a pass by finding the window already where
it asked). Results, tallied across seven runs (the run shown above, plus six
earlier ones during this fix):

| form | verb | `window` value | outcome across 7 runs |
| --- | --- | --- | --- |
| `hl.dsp.window.move({ ..., window = ADDR })` | `eval` (wrapped in `hl.dispatch(...)`) | plain address string | did not work, 7/7 -- consistent, safe no-op |
| `hl.dsp.window.move({ ..., window = hl.get_window(ADDR) })` | `eval` (wrapped in `hl.dispatch(...)`) | `hl.get_window()` object | **worked, 7/7** -- the reliable form |
| `hl.dsp.window.move({ ..., window = ADDR })` | `dispatch` (bare) | plain address string | did not work, 7/7 -- consistent, safe no-op |
| `hl.dsp.window.move({ ..., window = hl.get_window(ADDR) })` | `dispatch` (bare) | `hl.get_window()` object | **flaky and unsafe**: worked 2/7, silent no-op the rest, and on one run (shown above) it moved a *different, real window* (the user's Modelbox window) to the target workspace instead of the probe window |

**Task 11 should copy exactly this form, verbatim:**

```
hyprctl eval -- hl.dispatch(hl.dsp.window.move({ workspace = '<ws>', window = hl.get_window('<addr>'), follow = false }))
```

and must **not** use the bare `hyprctl dispatch -- hl.dsp.window.move({ ...,
window = hl.get_window(...) })` form even though it sometimes appears to
work -- it has been directly observed moving the wrong window. The two
plain-address-string forms are safe (they reliably do nothing) but useless.

This is a correction from the first version of these notes, which said "PASS
via `eval`, not `dispatch`" -- at that point `dispatch` had never actually
been tried, only assumed to have failed because `eval` won the race first.
It has now been tried, repeatedly, and the honest result is worse than
"does not work": it sometimes works and sometimes silently acts on the
wrong window.

## Q3b -- moving an already-existing workspace to another monitor

Same fix as Q3: both verbs are now tried every run (target monitor
alternates so neither can pass by finding the workspace already there).
Across all seven runs, both forms worked every time, with no flakiness and
no collateral movement of any other workspace:

| form | outcome across 7 runs |
| --- | --- |
| `hyprctl dispatch -- hl.dsp.workspace.move({ workspace = '<ws>', monitor = '<mon>' })` | worked, 7/7 |
| `hyprctl eval -- hl.dispatch(hl.dsp.workspace.move({ workspace = '<ws>', monitor = '<mon>' }))` | worked, 7/7 |

Task 11 can use either verb for relocating a workspace that already exists
to a different monitor; `dispatch` (bare, no `hl.dispatch(...)` wrapper) is
the shorter of the two and is the one worth copying by default, but `eval`
is an equally proven fallback if a caller is already inside an `eval` block
for other reasons. The first version of these notes said "via `dispatch`,
not `eval`" -- that "not" was also unsupported at the time (`eval` had never
been tried, `dispatch` had just won first); now both are supported by
seven-for-seven evidence.

## Safety finding: an unresolved `window` selector does not reliably no-op

This is the most important thing this probe found beyond the four graded
questions, because it changed the probe script itself, not just the notes.

While re-testing Q3 without the early `break`, a background watch of every
window's workspace (polled every 0.1-0.15 s throughout a run) caught the
user's real Modelbox window silently moving from workspace 10 to the
probe's scratch workspace during a `dispatch`-verb, object-selector
`window.move` call whose *own* target (the probe window) did not move. In a
separate, uninstrumented run before this was caught, the same thing
happened to the user's own `org.omarchy.claude.alb-2de7` terminal window
(moved to a scratch workspace and, once noticed, restored by hand to
workspace 4 based on the exact icon-prefix pattern shared with its two
sibling windows already there). Both were restored; the desktop was
confirmed clean afterwards.

Separately, `hl.get_window(addr)` -- the very selector that makes the
reliable Q3 form work -- was also observed returning `nil` for an address
that `hl.get_windows()` (the bulk listing) listed correctly moments later,
for two different real windows in two different moments. `get_window` is
not fully reliable either; a restore that depends on it should look the
window up via `hl.get_windows()` and filter by address instead.

Because of this, `test/probe-hyprland-api.sh` now wraps **every** dispatcher
call that could move a window or a workspace in a before/after snapshot of
every client's workspace (or every workspace's monitor, for the Q3b calls).
If anything other than the probe window/workspace changed, the guard
restores it immediately (via the `get_windows()`-filter lookup, not
`get_window()`) and reports it as `SAFETY: ... -- restoring it now` plus an
`UNSAFE (moved a different window instead, restored)` line in the outcome
table, instead of silently mislabelling that attempt "did not work". This
guard is a permanent part of the committed script, not a one-off manual
fix, because the script may be run again later by whoever implements
Task 11, on their own desktop, without anyone watching for collateral
damage the way this investigation did.

**Consequence for Task 9 and Task 11**: neither task should ever call
`hl.dsp.window.move` (or, by the same logic, any other `hl.dsp.*` dispatcher
that takes a `window` selector) with a plain address string, and Task 11
specifically must use the `eval` + `hl.get_window(addr)` form for
`window.move`, never the bare `dispatch` + `hl.get_window(addr)` form --
not because the latter is merely unproven, but because it has been caught
moving the wrong window on real hardware.

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
