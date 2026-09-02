# Hyprland Lua API probe -- results

Run with `test/probe-hyprland-api.sh` on Hyprland 0.56.2 (Omarchy Quattro),
three monitors (`HDMI-A-1`, `DP-3`, `DP-4`).

How the instrument works, in one paragraph: it opens one throwaway terminal
window of its own class, then tries each candidate form of each dispatcher
call `PROBE_TRIALS` times (default 7, override via env var) and tallies
worked / no-op / collateral per form -- these are the instrument's own
counts, produced by its loop, not a hand tally from re-running the script.
Every form that moves the window then gets a **negative control**: the same
call once more with an address that certainly does not exist
(`0xdeadbeef`). A correct form must then do nothing at all, because in
production the address always comes from a match taken moments earlier and
the window may have closed in between. If any call moves a window or
workspace other than the one under test, the script restores it, **verifies
the restore by reading it back**, reports the event, and stops the whole run
immediately -- no further trials, no further forms.

Q3's forms run least-dangerous-first, so that the abort rule cannot starve
the untested candidates of measurement (which is what happened in the
previous round).

## The verbatim output of the clean default run (run 5 of 5 today; runs 2-5 are identical in shape)

```
=== Q1: does Lua state survive across separate eval calls? ===
  ..  second eval saw _G.__probe = 4711
PASS  Q1: state persists -- rule handles can live in _G

=== Q2 + Q3: need a real window ===
  ..  focused monitor (where an unmatched window lands by default): HDMI-A-1
  ..  Q2 target monitor (unfocused, so it differs from the focused monitor HDMI-A-1 and any effect can only come from the rule): DP-3
  ..  probe window address = 0x55a05ffd9cc0
  ..  window opened on monitor DP-3 (rule asked for DP-3; focused/default monitor was HDMI-A-1)
PASS  Q2: window_rule honours a monitor field

=== Q3 preamble: what does each selector form actually RESOLVE to? ===
  ..  probe window is 0x55a05ffd9cc0; the window that was ACTIVE during this diagnostic was 0x55a05ffd9cc0
  ..  resolve  bare-string          	<nil>
  ..  resolve  prefixed-string      	0x55a05ffd9cc0	omarchy-autostart-probe
  ..  resolve  bare-string-bogus    	<nil>
  ..  resolve  prefixed-string-bogus	<nil>
  ..  resolve  enumerated-match     	0x55a05ffd9cc0	omarchy-autostart-probe
  ..  resolve  enumerated-count     	14

  ..  using workspace 51 as the disposable alternate target (verified not currently in use)
Q3 -- per-form tallies, up to 7 trials each (target alternates 50/51 so a hit can't be a leftover),
      each followed by its negative control. Forms run least-dangerous-first:
      eval + get_windows() enumerate, match w.address      7/7 worked, 0 no-op, 0 collateral
        -> negative control (0xdeadbeef): clean -- nothing moved (probe window still on workspace 50, no other window changed workspace)
      eval + get_window('address:..') + if-w-then guard    7/7 worked, 0 no-op, 0 collateral
        -> negative control (0xdeadbeef): clean -- nothing moved (probe window still on workspace 51, no other window changed workspace)
      eval + plain 'address:<hex>' string in window field  7/7 worked, 0 no-op, 0 collateral
        -> negative control (0xdeadbeef): clean -- nothing moved (probe window still on workspace 50, no other window changed workspace)
      dispatch + plain 'address:<hex>' string in window field 7/7 worked, 0 no-op, 0 collateral
        -> negative control (0xdeadbeef): clean -- nothing moved (probe window still on workspace 51, no other window changed workspace)
      eval + plain address string                          0/7 worked, 7 no-op, 0 collateral
        -> negative control (0xdeadbeef): clean -- nothing moved (probe window still on workspace 51, no other window changed workspace)
      dispatch + plain address string                      0/7 worked, 7 no-op, 0 collateral
        -> negative control (0xdeadbeef): clean -- nothing moved (probe window still on workspace 51, no other window changed workspace)
  ..  skipping the three unresolved-selector forms (address:-prefix unguarded, and hl.get_window(bare string) via eval and via dispatch): all measured dangerous on 2026-09-02 -- each moved a real, unrelated window once its selector failed to resolve, because a nil window field makes window.move act on the ACTIVE window (see the resolve table above and the notes file). Set PROBE_INCLUDE_DANGEROUS_FORM=1 to re-run them deliberately.
PASS  Q3: at least one form moves a specific window (see tally above -- a form is only usable if its negative control is also clean)

Q3b -- per-form tallies, up to 7 trials each (target monitor alternates so a hit can't be a leftover):
      dispatch (bare)                                            7/7 worked, 0 no-op, 0 collateral
      eval + hl.dispatch(...) wrap                               7/7 worked, 0 no-op, 0 collateral
PASS  Q3b: at least one form moves an existing workspace to another monitor (see tally above)

  ..  probe window closed (pid 3765885 terminated, verified gone from hyprctl -j clients)
```

Every run was verified clean afterwards, by diffing every window's
address/workspace/class and every workspace's monitor against a snapshot
taken before the first run -- not by trusting the script's own claim. All
five of today's runs came back byte-identical to that baseline.

## Q1 -- Lua state across separate `eval` calls

PASS: a second, independent `hyprctl eval` call saw the value a first call
wrote into `_G`. Task 9 can hold its rule handles in
`_G.__smartalb_autostart` and use them on re-apply/disable instead of the
name-based fallback.

## Q2 -- does `hl.window_rule()`'s `monitor` field work

PASS. `hl.window_rule({ ..., monitor = '<name>' })`, set before the window
opened, made the window land on that monitor. The probe deliberately targets
a monitor whose `focused` flag is `false`, so Hyprland's default placement
(the focused monitor) cannot explain the result -- an earlier version of this
probe picked the target by array position, and on this machine array
position 1 happened to *be* the focused monitor, which is why that first
PASS was not a measurement at all. Reproduced 5/5 runs today, and on two
different monitor pairs (`HDMI-A-1`-focused/`DP-3`-target in four runs,
`DP-3`-focused/`HDMI-A-1`-target in one), which also rules out anything
specific to one output.

Task 9 can rely on `window_rule`'s `monitor` field directly for monitor
placement, the same way it already relies on `workspace`.
(`HL.WindowRuleSpec` in `/usr/share/hypr/stubs/hl.meta.lua` declares only
`enabled?`, `match?` and `name?` -- no `monitor`, and not even `workspace`
-- so this remains undocumented behaviour, confirmed only by measurement.)

If this machine ever has only one monitor, or every monitor reports
`focused = true`, Q2 cannot be isolated from default placement at all; the
probe reports that case as `INCONCLUSIVE` (not PASS, not FAIL) and Task 9
must then treat `monitor` as unproven rather than working.

## Q3 -- moving a specific, already-open window

**PASS, and the mechanism behind two rounds of unexplained collateral
window moves is now measured rather than guessed.**

### The finding that explains everything: what a selector string resolves to

`HL.WindowSelector` is declared `string|integer|HL.Window` in
`/usr/share/hypr/stubs/hl.meta.lua`, without saying what a valid *string*
looks like. The probe now answers that read-only, before it moves anything
(no dispatcher is called in that section, so nothing there can move):

| selector expression | resolves to |
| --- | --- |
| `hl.get_window("<bare hex>")` | **`nil`** -- always, for a window that demonstrably exists |
| `hl.get_window("address:<bare hex>")` | the **correct** window (address and class read back and matched) |
| `hl.get_window("0xdeadbeef")` | `nil` |
| `hl.get_window("address:0xdeadbeef")` | `nil` |
| `hl.get_windows({})` + compare `w.address` | the **correct** window; the list covers every window on every workspace and monitor (14 entries with 13 user windows open) |

So a bare hex address is **not** a valid window selector string; the
`address:` prefix is. Reproduced identically in all five of today's runs.

That single fact explains the whole history of this question:

- `hl.get_window("<bare hex>")` returns `nil`, so
  `hl.dsp.window.move({ workspace = X, window = nil, ... })` is a table with
  **no `window` key at all**, and `window.move` then acts on **whatever
  window is ACTIVE**. On trial 1 the probe window had just been launched and
  was still active, so the call "worked". On trial 2 the probe window had
  been parked on an off-screen scratch workspace, something else was active,
  and that window moved instead. That is exactly the 1-worked-then-collateral
  pattern recorded in three runs of the previous round.
- The hypothesis this round was asked to test -- that a bare string makes
  `get_window` "fall back to something else, plausibly the active window" --
  is **half right and worth correcting in the design doc**: the fallback is
  not inside `get_window` (which cleanly returns `nil`), it is inside the
  dispatcher, which treats an absent/`nil` `window` field as "the active
  window". The consequence for the code is the same, but the cure is
  different: a resolution guard *does* work, as long as the selector string
  it feeds `get_window` is one that can actually resolve.
- The previous round's report that "a resolution guard does not help: `w`
  was not `nil`, it was the wrong window" is not reproducible here. Measured
  directly, `w` *is* `nil` for a bare address, 5/5 runs; and the guarded
  form measured 35/35 clean (below). Nothing this round saw `get_window`
  return a *wrong* window -- it returns the right one or none.
- An **unresolvable string** in the `window` field is a different case from
  `nil`: it is a consistent no-op (0/35 worked, 35/35 no-op, 0 collateral,
  for the bare-hex string via both verbs). That is why the plain-string
  forms were always harmless and always useless.

### Per-form results (today, 2026-09-02, five runs)

Trials are 7 per form per run; the aggregate is over the runs that reached
the form. The negative control column is the decisive one.

| form (verb + selector) | trials | negative control (`0xdeadbeef`) |
| --- | --- | --- |
| `eval` + `get_windows({})` enumerate, match on `w.address` | **35/35 worked**, 0 no-op, 0 collateral (5 runs) | **clean 5/5** -- nothing moved at all |
| `eval` + `get_window("address:<hex>")` + `if w then` guard | **35/35 worked**, 0 no-op, 0 collateral (5 runs) | **clean 5/5** |
| `eval` + `window = "address:<hex>"` (plain string, no `get_window`) | **14/14 worked**, 0 no-op, 0 collateral (2 runs) | **clean 2/2** |
| `dispatch` + `window = "address:<hex>"` (plain string) | **14/14 worked**, 0 no-op, 0 collateral (2 runs) | **clean 2/2** |
| `eval` + `window = "<bare hex>"` (plain string) | 0/35 worked, 35/35 no-op, 0 collateral (5 runs) | clean 5/5 -- but the form is inert, so this proves nothing about it |
| `dispatch` + `window = "<bare hex>"` (plain string) | 0/35 worked, 35/35 no-op, 0 collateral (5 runs) | clean 5/5 -- same, inert |
| `eval` + `get_window("address:<hex>")` **unguarded** | 7/7 worked, 0 no-op, 0 collateral (1 run) | **UNSAFE** -- moved the window that was ACTIVE at the time (Signal, `0x55a061856e40`, workspace 9 -> 51). Restored and verified back on 9; the run aborted there. |
| `eval` + `get_window("<bare hex>")` object | previous round: worked trial 1, moved a different real window trial 2, three runs running. Not run today (gated off). | never reached -- the form is condemned by its own *trials*, before a negative control is even due |
| `dispatch` + `get_window("<bare hex>")` object | measured dangerous 2026-09-02, previous round. Not run today (gated off). | not measured |

The last three rows are the three "unresolved selector" forms, and they are
now all off by default behind `PROBE_INCLUDE_DANGEROUS_FORM=1`: they share
one root cause (a selector that resolves to `nil` reaching the dispatcher),
it is measured, and re-confirming it on the user's live desktop buys no new
information.

Note what the unguarded `address:`-prefix row means, because it is the
single most useful result of this round: **that form scores a perfect 7/7 on
a live address and is still unsafe.** Only the negative control tells them
apart. A form that "usually works" is exactly what this row looks like from
the trials column alone.

### The expression Task 11 should copy

Use the enumerate-and-compare form. It is safe *by construction* -- on a
miss the loop body never runs, so there is no dispatcher call at all on the
miss path, and its safety does not depend on how Hyprland happens to treat
an unresolvable selector:

```
hyprctl eval 'do for _, w in ipairs(hl.get_windows({})) do if w.address == "<address>" then hl.dispatch(hl.dsp.window.move({ workspace = "<ws>", window = w, follow = false })) end end end'
```

(35/35 trials moved the right window; 5/5 negative controls moved nothing.)

Two measured, simpler alternatives, in case the coordinator prefers one:

- `window = "address:<hex>"` as a **plain string**, no `get_window`, no
  enumeration -- 14/14 worked, 2/2 negative controls clean, on **both**
  verbs. This is by far the shortest form and it needs no Lua block at all.
  Its safety, however, rests on Hyprland no-oping an unresolvable *string*
  selector (measured true, 35/35 no-op for the bare-hex string) rather than
  on the shape of the calling code, so an upgrade could in principle change
  it. Recommended only with that caveat noted.
- `local w = hl.get_window("address:<hex>") if w then ... end` -- 35/35
  worked, 5/5 negative controls clean. Equivalent in safety to enumerating
  as long as the `address:` prefix is never dropped; drop the prefix and it
  silently becomes the most dangerous form measured here.

**Never** pass a bare hex address to `hl.get_window()`, and never let a
possibly-`nil` value reach a `window` field: `window = nil` means "the
active window", which is a real user window most of the time.

## Q3b -- moving an already-existing workspace to another monitor

**PASS, re-measured under the current protocol** (the previous round could
not measure it at all -- Q3 aborted first in all three of its runs).

| form | tally |
| --- | --- |
| `dispatch` (bare dispatcher expression) | **28/28 worked**, 0 no-op, 0 collateral (4 runs x 7) |
| `eval` + `hl.dispatch(...)` wrapper | **28/28 worked**, 0 no-op, 0 collateral (4 runs x 7) |

Both verbs work, equally, with no flakiness and no collateral movement of
any other workspace in 56 trials. `dispatch` is simply the shorter one:

```
hyprctl dispatch 'hl.dsp.workspace.move({ workspace = "50", monitor = "HDMI-A-1" })'
```

This is expected to be the safer of the two questions by construction:
`workspace.move` takes no `window` selector at all, only a workspace id and
a monitor name, both plain strings -- so the `nil`-means-active-window
mechanism that made Q3 dangerous has no analogue here. It is still wrapped
in the same before/after guard as everything else, and the guard has never
fired on it.

## Safety finding: an unresolved `window` selector, and the guard around it

This is the most important thing this probe found beyond the four graded
questions, and it changed the script three times. The history, because each
step corrected the previous conclusion:

**Round 1.** A background watch of every window's workspace, polled every
0.1-0.15 s, caught the user's real Modelbox window silently moving to a
scratch workspace during a `dispatch`-verb, object-selector `window.move`
call whose own target did not move. A second real window, displaced by an
earlier uninstrumented run, was restored by hand. Conclusion at the time:
the `dispatch` verb is the problem, `eval` + `hl.get_window(addr)` is "the
reliable form".

**Round 2.** Running that same "reliable" form repeatedly inside one run
showed it was not reliable at all: it worked on trial 1 and moved a
different real window on trial 2, in three runs out of three. Conclusion at
the time: **no** form of `window.move` is safe, wrap everything in a guard.
Two rounds, two wrong conclusions, because neither round knew *why*.

**Round 3 (this one).** The read-only resolution diagnostic answers the why
(see the Q3 table above): a bare hex address never resolves, `get_window`
returns `nil`, and a `nil` `window` field makes the dispatcher act on the
**active** window. The collateral moves were never random and never a
Hyprland bug -- they were the active-window fallback, hit whenever the probe
window was no longer the active one. With a selector that actually resolves
(`address:` prefix) or no dispatcher call on the miss path at all
(enumerate), the same dispatcher is clean across 98 trials and 14 negative
controls. So round 2's "nothing is safe" is now superseded too: specific
forms are safe, and the negative control is what proves it.

The guard stays in the script regardless, for two reasons: it is what caught
this in the first place, and it is what makes a *future* regression (a
Hyprland upgrade changing selector handling) visible instead of silent.
Concretely, every dispatcher call that could move a window or a workspace is
bracketed by a full before/after snapshot of every client's workspace (or
every workspace's monitor). If anything other than the thing under test
changed, the guard:

1. restores it via a `get_windows()`-filter lookup (never `get_window()`),
2. **reads the result back** and only reports "restored" if the readback
   confirms it -- if the readback disagrees, it prints an unmissable
   `MANUAL FIX NEEDED` line (via both the stderr `warn` and the normal
   `fail` output channel) naming the window/workspace, where it belongs, and
   where it was last seen, so a human can finish the job,
3. and then **stops the whole run** -- no further trials of the current
   form, no further forms, no Q3b if the event happened during Q3.

It fired exactly once this round: on the negative control of the unguarded
`address:`-prefix form, which is precisely the event that condemned that
form.

**Known limitation of the guard**: a before/after snapshot diff cannot tell
"this hyprctl call moved the window" apart from "the user moved it by hand,
or some other process moved it, in the same ~0.4-0.8 s window between the
two snapshots". On this machine, which is the user's live, actively-used
desktop, that possibility is real, not theoretical. This is an accepted
trade-off, not a bug to fix. In this round's one collateral event the
attribution is nonetheless solid, because the guard also records which
window was **active** at the moment of the call and it was the same window
that moved -- exactly what the `nil`-selector mechanism predicts.

## Cleanup finding: `window.close` and the plain-string `window` selector

Not one of the four graded questions, but relevant to any later task that
needs to close a specific window via the Lua API rather than the process.

`hl.dsp.window.close({ window = addr })`, with `addr` a **bare address
string**, answered `ok` via both `eval` and `dispatch` but did not close the
window. That now reads as the same story as `window.move`: a bare hex string
is not a valid selector, and an unresolvable *string* (unlike `nil`) makes
the dispatcher a no-op. Tested separately at the time (outside the committed
probe run, on a scratch window),
`hl.dispatch(hl.dsp.window.close({ window = hl.get_window(addr) }))` *did*
close the window -- which, in light of this round's findings, was almost
certainly the `nil`-means-active-window path landing on the scratch window
because it happened to be active, not `get_window` resolving a bare address.
**Anything that needs to close a specific window should use the same
`address:`-prefixed or enumerated selector as Q3, and never a bare hex
string.**

The legacy fallback that was tried before that finding,
`hyprctl dispatch closewindow "address:$addr"`, did not silently no-op --
it answered with a Lua syntax error (`')' expected near 'address'`, with a
note that `dispatch` in Lua is shorthand for `hl.dispatch(...)`). That is a
second confirmed case, alongside `hyprctl keyword`, of the switch to the Lua
config making a legacy (non-Lua) dispatcher syntax inert.

Because of all this, the committed script does not ask a Hyprland dispatcher
to end the probe window at all: it reads `.pid` for the window's address out
of `hyprctl -j clients` (the script started the process itself) and kills
that PID directly, then polls `hyprctl -j clients` for up to ~3 s to confirm
the window is actually gone before claiming so -- and reports a `FAIL` with
the PID for manual cleanup if it is not.
