# Manual checklist

Everything on this page is a claim that **no automated test in this repository
can settle**. The reason is structural: `Panel.qml`, `BarWidget.qml` and
`Runners.qml` import `Quickshell.Io`, and those types exist only inside the
running Quickshell runtime, so nothing here can execute those files at all.
The test suites cover `Model.js`, the `bin/` scripts, and the *structure* of
the QML -- never its behaviour in a live shell.

The plugin edits one file, `~/.config/hypr/autostart.lua`, and does nothing
else: no configuration of its own, nothing applied to the running compositor,
nothing started, nothing reloaded. Most of what earlier versions of this
checklist asked about -- rules, workspace moves, the start marker, launching
missing programs, a second Apply -- was about a half that no longer exists,
and those questions are gone rather than answered.

Work through part A before submitting and part B after every install. Part C
holds the questions that have never been answered on this machine.

---

## Part A -- before this can be submitted

### A1. Take `preview.png`

**Not done yet, and nothing in this repository may do it**: it needs a
screenshot of the panel open in a live shell, and no automated step here is
allowed to load the plugin into a running session.

1. Install and restart the shell against an `autostart.lua` worth showing:
   **at least four entries, one of them a form the panel marks as not
   editable**, so the screenshot shows both what the plugin edits and what it
   deliberately leaves alone.
2. Open the panel and capture just the panel window:

   ```bash
   hyprshot -m window -o "$PWD" -f preview.png
   ```

3. Check the image before committing it: no file-system paths, no account
   names, no employer or customer data, nothing from a private window title.
   The panel shows command lines, and a command line can carry a token.
4. Put it at the **repository root**, next to `manifest.json`. Marketplace
   validation looks there and nowhere else -- an image under `images/` is
   treated as absent, which is how a submission ends up listed with the
   generic placeholder.
5. **Then add it to the README**, as the fifth line, directly under the
   two-line summary and above `## What it is`:

   ```markdown
   ![The Autostart Editor panel](preview.png)
   ```

   The README deliberately ships **without** that line, because a reference to
   a file that does not exist renders as a broken image on the first page a
   marketplace reviewer opens. The shell suite couples the two in both
   directions: no file means no reference, and once the file exists the README
   must show it. So step 5 is not optional -- omitting it turns the suite red,
   which is the point.

The shell suite has two assertions for this. The first holds in both states:
it passes while `preview.png` is absent *and* named here as owed, and it passes
once the file is present and is a real PNG; it fails only if the obligation
disappears from both places at once. The second is the coupling in step 5 --
the README must reference the image exactly when the image exists.

### A2. Enable the plugin in `shell.json`, and confirm the widget came up

**Installing is not sufficient, and the failure is silent.** A third-party
plugin counts as enabled only when its id is referenced from
`~/.config/omarchy/shell.json`; only first-party shell infrastructure is
implicitly enabled (`shell.qml:263-266`, `PluginRegistry.isEnabled`). Until
that reference exists, the bar shows nothing and nothing complains: the plugin
installs and `omarchy plugin validate` exits 0.

**One entry is enough, and it is the bar entry.** `findEntryLocation`
(`PluginRegistry.qml:206-224`) accepts the id in `bar.id`, in any
`bar.layout.*` section, or in the top-level `plugins[]` array, and
`isEnabled()` for a third-party plugin is exactly that predicate. So adding
the widget to the bar -- through Omarchy's own plugin screen, or by hand:

```json
{ "bar": { "layout": { "right": [ { "id": "smartalb.autostart" } ] } } }
```

is the whole of it. There is no second switch, and no service half any more.

**Do not also add it under `plugins[]`.** A second reference is not needed and
is not harmless bookkeeping: `setEnabled(false)` removes only the first
location it finds, so switching the plugin off through the interface would
leave the other entry behind and the plugin would stay enabled.

Verify, after `omarchy-restart-shell`:

```bash
omarchy plugin list | grep smartalb.autostart
```

The row must read `enabled`, and its KINDS column must show `bar-widget` --
and **nothing else**. A row that also lists `service` means the manifest grew
a kind back whose `Service.qml` does not exist.

### A3. Run the two checks this repository cannot run for you

```bash
omarchy plugin validate "$PWD"
qmllint -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" \
        BarWidget.qml Panel.qml Runners.qml
```

`omarchy plugin validate` mirrors the checks the running shell applies to a
manifest. `qmllint` needs the shell's own import path, which only exists on a
machine with Omarchy installed.

### A4. Confirm what you are asserting in the submission

The marketplace asks the submitter to confirm ownership of the plugin **and of
the preview image**, and to state the plugin's dependencies. Note also that
approval is for *listing* and is explicitly not a security review -- so the
claims below have to be true because they are true, not because a reviewer
checked them:

- no elevated rights anywhere, no system-wide tier, no package installation;
- the expected capability baseline is therefore `installer` and nothing else;
- the place a reviewer will look first: this plugin **writes a file that runs
  at every login**. It writes no generated Lua anywhere and pushes nothing
  into the running compositor -- `luaBytes`, which re-encoded every value as
  `string.char(...)` bytes for that boundary, is gone with the boundary. What
  guards the one file it does write is three things: the character allowlist
  in `Model.autostartCharRefused` (a line break or a control character cannot
  be written at all), `luaQuote`'s escaping, and the `luac5.1 -p` gate in
  `bin/omarchy-autostart-hypr-write`, which refuses a candidate that does not
  compile.

---

## Part B -- the walkthrough after an install

Run `omarchy-restart-shell` first and wait about 8 seconds. The inotify watcher
reloads the shell after any change under the plugin directory and takes running
`Process` objects with it; measuring before it has settled measures the reload.

Back up your `autostart.lua` by hand before starting: the plugin keeps one
step (`autostart.lua.bak`), and this walkthrough writes more than once.

1. The widget is visible in the bar, and its tooltip names the number of
   entries your `autostart.lua` actually has -- count them yourself. Before
   the first click it must say only `Autostart Editor`: the count is unknown
   at that point, not zero.
2. A click opens the panel; a second click closes it. `Escape` closes it too.
   **And the build is in the bottom right of the panel**, quiet and
   right-aligned, reading `v` and the version -- `v1.0.0` for this release.
   Check it against the manifest on THAT machine:

   ```bash
   jq -r .version ~/.config/omarchy/plugins/smartalb.autostart/manifest.json
   ```

   The two must agree. This line exists so you can tell two machines apart at
   a glance, so a number that is stale or absent defeats its whole purpose --
   an empty footer means the panel is not the build you think it is. The
   number is not written in `Panel.qml`; it comes from `Model.VERSION`, which
   a shell assertion pins to the manifest in both directions.
3. Every entry of your file is listed, each with its line number. Compare
   against your own editor:

   ```bash
   nl -ba ~/.config/hypr/autostart.lua
   ```

   Every number the panel shows must be the line that call is on. **This is
   the claim every write rests on** -- the automated round-trip proof in
   `test/harness.qml` checks it against the file contents, but only your eyes
   can check it against the panel.
4. A form the reader cannot take apart -- a nested helper such as
   `o.exec_on_start(o.launch_webapp_sole("Chat", "..."))` -- is shown
   **verbatim**, marked *not editable*, with a sentence saying why, and has no
   change or remove control. If it shows a command instead, the reader has
   guessed: report it, because a guess here becomes a wrong rewrite.
5. The header names the file, says it is the only one this panel edits, and
   gives its entry count. If the file does not exist it must say so rather
   than showing an empty panel.
6. **Add** a command by typing it. The line appears as the **last** line of
   the file, nothing else in the file moved, and `autostart.lua.bak` holds the
   previous content:

   ```bash
   diff ~/.config/hypr/autostart.lua.bak ~/.config/hypr/autostart.lua
   ```

   Exactly one added line, and no other difference.
7. **Add from your installed applications**: the picker lists real application
   names, and choosing one **fills the field** with its command rather than
   writing it. Nothing reaches the file until you press the add control.
8. **Add from a running program**: the picker lists your open windows. Unfold
   one and confirm the suggestions are ordered sensibly for that window, that
   each names where it came from, and that a command under `/tmp`, `/run` or
   an AppImage mount path carries the warning that it will not survive a
   restart. Picking one fills the field and writes nothing.
9. A window with no command to offer is **shown anyway**, with the reason.
10. **Change** one entry: exactly that line differs afterwards, and the
    editor's field gives focus back when it closes -- press `Escape` after
    closing it and confirm the panel still closes. (A hidden field that keeps
    focus swallows `Escape` for the rest of the session; that defect has been
    measured in this project before.)
11. **Remove** one entry: exactly that line is gone, and the comment above it
    is still there.
12. Nothing was started and nothing was reloaded. The message after a write
    says so; confirm no new window appeared and that your session is
    unchanged.
13. Make the file unwritable by a second account (`chmod 664`) and try to
    write: the panel must refuse, name that reason, and change nothing.
14. Edit `autostart.lua` in your editor while the panel is open, then try to
    write from the panel: it must refuse as stale and tell you to reopen the
    panel. **This is the guard that stops a line number from a stale read
    hitting a different line.**
15. Point `autostart.lua` at a symlink and try to write: refused, with that
    reason.
16. Log out and back in: your entries start, each exactly once, and the file
    the plugin wrote is what did it.
17. **Install over the previous version and check what is NOT there.** This
    is the one step written from a defect that reached the user's machine:
    `install` used to copy its file list over whatever was at the target, so
    `Service.qml`, `bin/omarchy-autostart-config` and
    `bin/omarchy-autostart-marker` survived the build that deleted them. It
    replaces the directory now, and the shell suite holds that -- but the
    installed copy is the thing the shell actually loads, so look at it:

    ```bash
    diff -r <(cd "$PWD" && ls -1) \
            <(ls -1 ~/.config/omarchy/plugins/smartalb.autostart)
    ```

    The plugin directory must hold twelve entries and nothing else: the four
    documents, the four QML/JS files, and `bin/` with its four scripts. A
    `Service.qml` there is the defect back.
18. `./uninstall`, then check: the plugin directory is gone and
    `~/.config/hypr/autostart.lua` is byte for byte what it was.

---

## Part C -- open questions carried from the build

Each item says what to do and what a failure looks like.

### C1. Is the error a user sees a real one?

The `onExited` handlers comparing `exitCode !== 0` after a `run.tool(...)`
call were dead code once: a bare pipeline reports `head`'s status, so every
script failure read as success. `runnerOut` recovers the producer's own status
through `${PIPESTATUS[0]}` and maps 141 (the producer's SIGPIPE, meaning the
answer was longer than the cap) to success rather than to failure.

*Exercise:* make `bin/omarchy-autostart-hypr` fail on purpose and confirm the
panel says so instead of showing an empty file.

### C2. Does the `[+ Add]` application picker actually fill up?

`run.tool("omarchy-autostart-apps")` is read through a `StdioCollector`, and
nothing here can execute a file that imports `Quickshell.Io`.

*If it stays on "Reading the installed applications...":* neither
`onStreamFinished` nor `onExited` arrived. *If it says "No installed
applications were found":* the script answered nothing -- run
`bin/omarchy-autostart-apps` by hand and compare. *If it says "Could not read
the list of installed applications":* either the script failed or its JSON was
cut off by `runnerOut`'s 256 KiB cap.

### C3. What does the user see when the application list is too long?

`runnerOut` announces truncation on stderr and the panel collects it, so
`Model.appsProblem` can say "too long to read in full" instead of "could not
be read". Reachable, not theoretical: at a measured ~137 bytes per entry the
script's 2000-file bound reaches 230-270 KB against a 256 KiB cap.

*Exercise:* point `DESKTOP_DIRS` at a directory with enough generated
`.desktop` files to pass the cap, open the picker, and confirm the sentence
names the length. *If it says "could not be read":* the stderr collector did
not fire, or the marker text drifted -- the cross-file check in
`qml-structure.sh` covers the second.

### C4. Does the running-programs picker pick for the window it was opened on?

The window row is an INDEX and the suggestions delegate has an `index` of its
own. Measured offscreen that a nested `Repeater` delegate's `index` shadows
the outer row's (it differed in 4 of 6 delegates), which is why the panel
captures the window index under a name of its own and goes through
`autostartWindowUnfolded` / `autostartWindowUnfold`. What the measurement
cannot show is the live panel.

*Exercise:* with several windows open, unfold the SECOND one, pick a
suggestion, and confirm the command that lands in the field is that window's.

### C5. Does `configreloaded` matter here at all? (Expected: no.)

Earlier versions subscribed to Hyprland's `configreloaded` event because a
`hyprctl reload` dropped the rules they had set at runtime. Nothing is set at
runtime any more, so there is nothing for a reload to drop and the plugin does
not listen for it.

*Exercise:* run `hyprctl reload` with the panel open and confirm the panel is
simply unaffected. If the entries on screen change or the panel reports
anything, something is still reacting to the compositor.

### C6. Does the file survive a write that is interrupted?

The writer stages the new content beside the destination, gives it the
original's permissions, and replaces the file by an atomic rename. A rename
within one filesystem either happens or does not.

*Exercise:* not easily forced by hand. What can be checked is the aftermath of
every write in part B: `autostart.lua` is either the old content or the new
one, never a partial file, and `autostart.lua.bak` always holds the content
from before the last write.
