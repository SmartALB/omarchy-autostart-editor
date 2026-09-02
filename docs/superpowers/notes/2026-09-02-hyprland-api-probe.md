# Hyprland Lua API probe -- results

Run with `test/probe-hyprland-api.sh` on Hyprland 0.56.2 (Omarchy Quattro),
three monitors (`HDMI-A-1`, `DP-3`, `DP-4`). Verbatim output:

```
=== Q1: does Lua state survive across separate eval calls? ===
  ..  second eval saw _G.__probe = 4711
PASS  Q1: state persists -- rule handles can live in _G

=== Q2 + Q3: need a real window ===
  ..  monitors: first=HDMI-A-1 second=DP-3
  ..  probe window address = 0x55a061d302a0
  ..  window opened on monitor DP-3 (rule asked for DP-3)
PASS  Q2: window_rule honours a monitor field

PASS  Q3b: this form moves an existing workspace to another monitor:
      hyprctl dispatch -- hl.dsp.workspace.move({ workspace = '50', monitor = 'HDMI-A-1' })
PASS  Q3: this form moves a specific window:
      hyprctl eval -- hl.dispatch(hl.dsp.window.move({ workspace = '50', window = hl.get_window('0x55a061d302a0'), follow = false }))

  ..  probe window closed; every rule set here is inert and gone at the next Hyprland start
```

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
