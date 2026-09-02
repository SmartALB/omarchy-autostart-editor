# Hyprland Lua API probe -- results

Run with `test/probe-hyprland-api.sh` on Hyprland 0.56.2 (Omarchy Quattro),
three monitors (`HDMI-A-1`, `DP-3`, `DP-4`). Verbatim output:

```
=== Q1: does Lua state survive across separate eval calls? ===
  ..  second eval saw _G.__probe = 4711
PASS  Q1: state persists -- rule handles can live in _G

=== Q2 + Q3: need a real window ===
  ..  monitors: first=HDMI-A-1 second=DP-3
  ..  probe window address = 0x55a061d2f620
  ..  window opened on monitor DP-3 (rule asked for DP-3)
PASS  Q2: window_rule honours a monitor field

PASS  Q3b: this form moves an existing workspace to another monitor:
      hyprctl dispatch -- hl.dsp.workspace.move({ workspace = '50', monitor = 'HDMI-A-1' })
PASS  Q3: this form moves a specific window:
      hyprctl eval -- hl.dispatch(hl.dsp.window.move({ workspace = '50', window = hl.get_window('0x55a061d2f620'), follow = false }))

  ..  probe window closed (pid 3435390 terminated, verified gone from hyprctl -j clients)
```

(This is the output of the fixed script, run after the cleanup fix described
below. The window address and pid differ from the earlier run only because
each run opens a fresh window; the four question answers are unchanged.)

## Q1 -- Lua state across separate `eval` calls

PASS: a second, independent `hyprctl eval` call saw the value a first call
wrote into `_G`. Task 9 can hold its rule handles in
`_G.__smartalb_autostart` and use them on re-apply/disable instead of the
name-based fallback.

## Q2 -- does `hl.window_rule()`'s `monitor` field work

PASS: a `hl.window_rule({ ..., monitor = 'DP-3' })` set before the window
opened made the window actually land on `DP-3`. Task 9 can rely on
`window_rule`'s `monitor` field directly for monitor placement, the same way
it already relies on `workspace` -- no separate placement route is needed.

## Q3 -- moving a specific, already-open window

PASS, via `eval`, not `dispatch`, and only with the window wrapped through
`hl.get_window(addr)` -- a bare address string in the `window` field did not
move the window:

```
hyprctl eval -- hl.dispatch(hl.dsp.window.move({ workspace = '50', window = hl.get_window('0x55a061d302a0'), follow = false }))
```

Task 11's reconcile step (moving windows that are already open) can use this
exact form verbatim.

## Q3b -- moving an already-existing workspace to another monitor

PASS, via `dispatch`, with a plain dispatcher expression (no `hl.dispatch(...)`
wrapper, unlike Q3):

```
hyprctl dispatch -- hl.dsp.workspace.move({ workspace = '50', monitor = 'HDMI-A-1' })
```

Task 11 can use `dispatch` (not `eval`) for relocating a workspace that
already exists to a different monitor.

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
PID-based `kill` is simpler and does not depend on it.

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
