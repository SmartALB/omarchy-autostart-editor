# Autostart Layout

An Omarchy bar widget for Hyprland: a reader -- and, later, a writer -- for the
Hyprland configuration files you already keep by hand.

## Status: it reads all three, and writes `autostart.lua`.

This plugin used to keep a list of its own, in
`~/.config/omarchy/autostart-layout.json`, and apply it at login through
`hyprctl eval`. That was two sources of truth for one fact -- which program
starts, and where its window goes -- and the one that mattered was always the
Hyprland configuration.

So the direction changed. The single source of truth is now your own

- `~/.config/hypr/autostart.lua`,
- `~/.config/hypr/windowrules.lua`,
- `~/.config/hypr/workspaces.lua`,

which Hyprland already reads and applies at login by itself. This release reads
all three and shows them, and it writes exactly one of them: `autostart.lua`.
`windowrules.lua` and `workspaces.lua` are read only. It applies nothing of its
own -- no `hyprctl eval`, no `hyprctl reload`, nothing started and nothing
killed -- so your autostart and your window placement keep working exactly as
they did, because they were never this plugin's doing in the first place: they
are Hyprland's.

### What writing `autostart.lua` means, precisely

It is **line surgery**, and only three operations exist:

- **add** -- one line, appended as the last line, in the style the file already
  uses: `o.launch_on_start("<your command>")`. Nothing is sorted into a
  "matching" comment section, because guessing which of your section comments a
  program belongs under is exactly the surprise this design avoids.
- **change** -- exactly the line you picked, no other.
- **remove** -- exactly the line you picked, no other.

Your comments, your blank lines and every form the reader cannot represent stay
byte for byte as you wrote them. In particular, **a line the panel cannot
represent can be neither changed nor removed.** It is shown as it stands, marked
as such, with the note that the file has to be edited by hand for it. That is a
real limitation and it is named rather than hidden: in a file with a nested
helper call like
`o.exec_on_start(o.launch_webapp_sole("Chat", "https://chat.example.org/"))`,
that entry is visible and untouchable.

Four things stand between a change and your next login:

1. The new file content is produced by a **pure function** in `Model.js` -- old
   text plus one operation gives new text, no file I/O -- so every case is a
   unit test with a byte-exact expected result, plus the assertion that old and
   new differ in exactly one line.
2. A command that cannot be written as a readable Lua string literal -- a line
   break, a control character, a NUL -- is **refused**, with a sentence saying
   why, rather than encoded into something unreadable.
3. The candidate is compiled with `luac5.1 -p` **before** anything is renamed
   into place. `-p` parses without executing. A file that would not compile is
   never published, and the original is left byte for byte as it was.
4. Your file is backed up to `autostart.lua.bak` (one step back, overwritten
   each time) and replaced by an atomic rename. If its modification time is not
   the one the panel read, the write is refused: you also edit this file by
   hand, and a line number from a stale read means a different line.

A change takes effect **at your next login.** The plugin starts nothing and
reloads nothing.

The old JSON half is still in the source, disconnected at one named place
(`WRITE_PATH_ENABLED` in `Model.js`), because the writer is built from it. It
is not read, not applied, and not offered in the panel.

## What it does

Opens a panel behind a bar button and shows, in the order of the files:

1. **`autostart.lua`** -- the programs your session starts. `o.launch_on_start`
   and `o.exec_on_start` are read; `o.exec_on_start(o.launch(...))` is shown
   identically to `o.launch_on_start(...)`, because
   `/usr/share/omarchy/default/hypr/helpers.lua` defines them to be the same
   thing.
2. **`windowrules.lua`** -- which window class goes to which workspace, with
   `float`, `maximize` and `fullscreen` if they are set.
3. **`workspaces.lua`** -- which workspace is pinned to which monitor.

Every entry is shown with its **1-based line number**, so you can find it in
your own editor. A line that calls one of those helpers in a form the reader
cannot take apart -- a nested helper such as
`o.exec_on_start(o.launch_webapp_sole("Chat", "..."))`, a rule matching on
a table of properties, an option the panel has no representation for -- is
shown **as it stands**, marked *not editable*, with the reason in plain words.
It is never guessed at and never silently left out. A line that calls none of
those helpers is not an entry at all; it belongs to your file.

Nothing here needs elevated rights. There is no `--system` tier, no elevation
helper, no package installation, and no rule file of any kind. Everything the
plugin does, it does as you, in your own configuration directory -- and at the
moment, all it does is read.

### What it needs

- Hyprland with Omarchy's Quickshell-based shell (this is a `bar-widget` plus
  `service` plugin, schema version 1).
- `hyprctl`, `jq`, `bash`, `grep`, `timeout`, `setsid`, `mktemp` -- all of
  them part of a stock Omarchy install. Nothing is fetched at runtime and the
  plugin makes no network connection at all.

### When something else is a better fit

Your editor. `~/.config/hypr/*.lua` is three small hand-written files, and
until the write half lands there is nothing this panel can do to them that
`nvim` cannot do faster. What it offers today is the overview: all three files
side by side, with the forms it will later be able to edit marked apart from
the forms it will always leave alone.

## Install

```bash
git clone https://github.com/SmartALB/omarchy-autostart-layout.git
cd omarchy-autostart-layout
./install
omarchy-restart-shell
```

`./install` copies the plugin to
`~/.config/omarchy/plugins/smartalb.autostart/` and prints what to do next. It
refuses to run as the root user, because it installs into a per-user
configuration directory.

Then add the widget to your bar. Either use Omarchy's own plugin screen, or
add the id to a bar section in `~/.config/omarchy/shell.json`:

```json
{ "bar": { "layout": { "right": [ { "id": "smartalb.autostart" } ] } } }
```

**This step is not optional, and skipping it fails quietly.** That one entry is
what enables *both* halves of the plugin: the bar widget you click, and the
background part that applies your list at login. Until the id is referenced
from `shell.json`, Omarchy treats the plugin as disabled -- nothing appears in
the bar and nothing starts at login, with no error anywhere. One entry is
enough; do not add a second one under a top-level `plugins[]` array.

To check it took, after the restart:

```bash
omarchy plugin list | grep smartalb.autostart
```

The row should read `enabled` and list both `bar-widget` and `service`.

### Removal

```bash
./uninstall
```

It removes the plugin directory and the session start marker. Remove the
widget from your bar in `shell.json` yourself afterwards, then run
`omarchy-restart-shell`. Your configuration file is deliberately **kept**, so
a reinstall finds your list again; the uninstaller prints its path so you can
delete it on purpose.

## How placement works

> **This section describes the disconnected half.** It is kept because the
> write half will be built from it. Today the plugin sets no rule at all --
> your `windowrules.lua` does, and this plugin only reads it. See *Status*
> above.

In Hyprland a workspace lives on exactly one monitor. That is why a program's
placement is an **either-or** and not two fields: pinning a program to
workspace 3 *and* to `DP-2` would be a contradiction the moment workspace 3
sits on `DP-4`, and the panel refuses that combination rather than silently
picking one.

> If you want a program on a particular screen and do not care about the
> workspace number, choose monitor. If you think in workspaces, choose
> workspace and pin the workspace to a monitor in the table below.

The panel shows the resulting monitor greyed out next to a workspace choice,
so you can see which screen a workspace choice actually implies.

## Where your data lives

> Your Hyprland configuration lives where it always did:
> `~/.config/hypr/autostart.lua`, `windowrules.lua` and `workspaces.lua`.
> The plugin opens them **read-only** and writes nothing anywhere. The
> file described below still exists if you used an earlier version, but
> nothing reads it any more.

One file:

```
~/.config/omarchy/autostart-layout.json      (mode 0600)
```

That file holds **command lines that are run as you when your session
starts**. It is the same trust level as `~/.config/hypr/autostart.lua`, and it
is worth reading with that in mind before you paste a command into it.

Two consequences, both deliberate:

- The plugin writes that file with mode `0600` and **applies nothing at all**
  if it ever becomes writable by anyone else. It then says so in the panel and
  tells you the exact command to put the mode back. A file another account can
  edit is a file another account can use to run programs as you.
- The plugin touches no other configuration. It does not write to
  `hyprland.conf`, to any `.lua` under `~/.config/hypr/`, or to your
  `shell.json`; it never overwrites configuration you did not change in its
  own panel, and the panel changes nothing until you press **Apply**.

## How it applies

> **This section describes the disconnected half.** Today the plugin applies
> nothing: no `hyprctl eval`, no start-marker claim, no launch. Hyprland
> applies your three Lua files at login on its own, as it always did. See
> *Status* above.

No Hyprland configuration file is edited. The rules are set at runtime in the
running compositor -- window rules for the programs, workspace rules for the
table -- and they live only there.

Two things follow from that:

- A manual `hyprctl reload` drops them, because a reload rebuilds the
  compositor's rule set from the configuration files, which never contained
  them. The background part of the plugin notices the reload and sets the
  **rules** again, so a window opened after that lands where you configured
  it. It does **not** re-run the workspace-to-monitor moves: a workspace that
  is already open stays on whichever monitor the reload left it on until you
  open the panel and press **Apply**, which does perform the moves. So the gap
  is short for the rules and, for the current layout, lasts until the next
  Apply.
- Nothing is left behind when you remove the plugin. Log out, or run
  `hyprctl reload`, and the rules are gone.

**What the plugin cannot tell you:** whether a program you configured actually
started. Programs are launched detached from the shell, and a misspelled
command, a missing binary and a program that exits immediately all look the
same from here -- no output, no failing status. The one honest report the
plugin can give is the other way round: it counts the enabled programs for
which **no window ever matched**, says so under the list, and offers *Launch
missing*. If a row is listed there, the usual cause is a misspelled command or
a window-class pattern that matches nothing; open the row and check both.

## Known limits

The limit that matters right now: **the plugin cannot change anything.** It
reads your three Hyprland files and shows them; the write half does not exist
yet. The limits below belong to the disconnected half and are kept for the
same reason its code is.

- Workspaces 1 to 99 only. Named workspaces are not supported.
- **At login the table sets rules, and a rule only fires when a workspace is
  created.** Workspace 1 already exists before the shell starts, so pinning
  workspace 1 to a particular monitor is honoured for workspaces created after
  login, not for the one you are already looking at. The panel's **Apply**
  button does move workspaces that are already open -- the background part
  that runs at login deliberately does not, because moving workspaces around
  under you while your session is still coming up is worse than not moving
  them. If your layout matters on the workspace you land in, open the panel
  once and press **Apply**, or put the programs you care about on workspaces
  you open later.
- Placement is workspace or monitor. There are no `float`, `size`, `maximize`
  or `fullscreen` rules -- this is not a general window-rule editor.
- Placement matches on window class, so several windows of the same class go
  to the same place. One rule per class, not per window.
- An application whose window class is not known until it has run once needs
  **From window** pressed once: start it, then pick its window from the list
  and the class is filled in for you.
- An imported window whose class matches no installed application arrives with
  an empty command on purpose. The plugin does not guess a command from a
  window class; fill it in and the row starts working.
- At most 200 programs, a 100-character name and a 500-character command per
  row.

## Development

Three traps, each with the symptom you will recognise it by:

- **Run `omarchy-restart-shell` after every QML change.** The develop guide
  says saved changes reload automatically; for bar widgets that is not true.
  *Symptom:* the journal writes `Local plugin changed, reloading`, and the
  widget still behaves like the previous version -- diagnostic output you just
  added does not fire at all.
- **After touching a plugin file, wait about 8 seconds before measuring
  anything.** The inotify watcher reloads the shell and takes running
  `Process` objects down with it. *Symptom in the journal:*
  `another handler is registered for target`.
- **Use `/usr/lib/qt6/bin/qml` for the test suite.** `/usr/bin/qml` on Arch is
  Qt 5.15, does not load the harness at all, and exits 2 -- which collides
  with the runner's own "cannot run". The tool that fails with **no output
  whatsoever** and status 1 is `/usr/bin/qmltestrunner`, which is why it is
  not used here. The runner's five exit codes: `0` green, `1` a test failed,
  `2` cannot run, `3` the harness itself broke, `4` the assertion-count guard
  failed.

`CHECKLIST.md` lists everything no automated test in this repository can
settle -- every claim that needs a running Hyprland session to confirm.

## Tests

```bash
./test/run-tests.sh        # the bin/ scripts, the manifest, install/uninstall
./test/run-qml-tests.sh    # Model.js, headless, in the Qt6 engine
./test/qml-structure.sh    # structural checks over the QML files
./test/runners-shape.sh    # runnerOut/runnerErr, run through a real bash
./test/lua-syntax.sh       # the Lua chunks compile
./test/mutations.sh        # every test above, checked against its own mutation
```

`mutations.sh` is the one worth explaining: it breaks a guarded property on
purpose, one at a time, and fails if the suite stays green. A test that
survives the removal of the thing it tests was never testing it.

`test/probe-hyprland-api.sh` is **not** part of any suite and is not run by
any of the above. It is the measurement that established how Hyprland's Lua
API behaves, and it acts on the live desktop: it creates and removes real
windows and workspace rules. It snapshots before and after, verifies the
restore and aborts on the first unexpected event, but do not run it in a
session you care about.

## License

MIT. See `LICENSE`.
