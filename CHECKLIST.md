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

### A1. Take a preview image -- optional, but worth having

**The marketplace does not require one.** Its guide says a repository
"optionally contains one root preview", so a submission without one is
complete. It is still worth having: the preview is what a reviewer and every
later reader see before they read a word.

**Nothing in this repository may produce it**: it needs a screenshot of the
panel open in a live shell, and no automated step here is allowed to load the
plugin into a running session.

1. Install and restart the shell against an `autostart.lua` worth showing:
   **at least four entries, one of them a form the panel marks as not
   editable**, so the screenshot shows both what the plugin edits and what it
   deliberately leaves alone.
2. Open the panel and capture just the panel window:

   ```bash
   hyprshot -m window -o "$PWD" -f preview.png
   ```

3. **Check the image before committing it, and read it with your eyes.** No
   file-system paths, no account names, no employer or customer data, nothing
   from a private window title. The panel shows command lines, and a command
   line can carry a token.

   **This is not a formality, and it has already caught a real one.** On
   2026-09-03 a `preview.png` was taken of the panel against the owner's own
   `autostart.lua`. The image showed their work mail host, their messenger
   webapp URL, their work chat client and their local model runner -- the exact
   values two rounds of scrubbing had just removed from every file in the
   tree. The plugin renders your real file, so a screenshot of it publishes
   what the file contains.

   **No automated check can see this.** Every grep in this repository, and
   every grep in the audit that scrubbed the tree, reads text; a PNG is
   opaque to all of them. The suite can only assert that the file exists and
   is really a PNG. So this step is irreducibly manual, and it is the only
   thing standing between a scrubbed repository and a screenshot that undoes
   it.

   The safe way: point the panel at a **neutral** `autostart.lua` first --
   the fixture in `test/harness.qml` is one, and it was built to look like a
   real hand-maintained file for exactly this kind of reason -- take the
   screenshot against that, and put your own file back afterwards. Or ship no
   preview at all: it is optional.
4. Put it at the **repository root**, next to `manifest.json`. The root
   location is the part that matters: a preview under `images/` or anywhere
   else is not found, and the listing then shows the generic placeholder.

   **Five names are accepted** -- `preview.png`, `preview.jpg`,
   `preview.jpeg`, `preview.webp`, `preview.avif`. Any one of them will do,
   and there is **nothing to size or crop**: the marketplace strips the
   preview's metadata and generates the card and detail images itself. The
   only input limits are 50 MB and 40 megapixels, which a panel screenshot
   will not come close to.

   **This repository's own assertion pins `preview.png`**, deliberately: it
   checks the PNG magic bytes, so it can say "present and really an image"
   rather than "a file with the right name". If you take one of the other four
   formats instead, `test_the_preview_is_either_taken_or_still_owed` in
   `test/run-tests.sh` and the README reference have to be updated together --
   the suite will tell you, because it couples the two.
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

### A2. Install with Omarchy's own command, and confirm the widget came up

**Omarchy installs and enables plugins itself.** This step used to describe
editing `~/.config/omarchy/shell.json` by hand with two commands to verify it;
that was work the platform already does, and describing it was my error:

```bash
omarchy plugin add https://github.com/SmartALB/omarchy-autostart-editor.git --enable
```

`omarchy-plugin-add` clones into `~/.config/omarchy/plugins/<id>`, and
`--enable` runs `omarchy-plugin-enable`, which writes the bar placement -- it
asks which section and falls back to `barWidget.defaultSection`, which this
manifest sets to `right`. **Nothing in `shell.json` needs touching.**

Two failure modes worth knowing rather than rediscovering, both measured:

- **Over SSH, `--enable` needs `--yes`.** It asks for the section
  interactively, and with no terminal attached it needs `--yes` to take the
  default.
- **`omarchy plugin list` and `omarchy plugin enable` need a graphical
  session.** Outside one they fail with `OMARCHY_PATH is not set`, so
  installing over SSH works but verifying it there does not.

Verify, in a graphical session, after `omarchy-restart-shell`:

```bash
omarchy plugin list | grep smartalb.autostart
```

The row must read `enabled`, and its KINDS column must show `bar-widget` --
and **nothing else**. A row that also lists `service` means the manifest grew
a kind back whose `Service.qml` does not exist.

**Why enabling matters at all**, since the command now does it for you: a
third-party plugin counts as enabled only when its id is referenced from
`shell.json` (`shell.qml:263-266`, `PluginRegistry.isEnabled`), and until it
is, the bar shows nothing and nothing complains -- the plugin installs and
`omarchy plugin validate` exits 0. `findEntryLocation`
(`PluginRegistry.qml:206-224`) accepts the id in `bar.id`, in any
`bar.layout.*` section, or in a top-level `plugins[]` array. One reference is
enough, and a second is not harmless bookkeeping: `setEnabled(false)` removes
only the first location it finds, so switching the plugin off would leave the
other entry behind and it would stay enabled. `omarchy plugin enable` writes
one; do not add another by hand.

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

**These are the five statements the submission form requires, verbatim.** They
are what the owner has to confirm, so they are written out here rather than
paraphrased:

```
- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
```

Where each one is satisfied, so the box is ticked because it is true and not
because a reviewer checked it:

1. **Public, with install and removal.** `README.md` leads with
   `omarchy plugin add … --enable` and gives `omarchy plugin remove` plus the
   developer path from a clone.
2. **License and dependencies documented.** `LICENSE` is MIT and the manifest
   says so; *What it needs* in the README names `jq`, `luac5.1`, `realpath`
   with what it guards, `bash`, `timeout`, the coreutils, and `hyprctl` --
   and states that nothing is fetched at runtime and no network connection is
   made.
3. **Ownership**, including the preview: the screenshot is taken by the owner
   in step A1, of their own desktop, which is also why step 3 there is a
   privacy check rather than a formality.
4. **No overwriting without consent.** The panel writes only when the user
   presses a control; it edits exactly one file; every write takes a dated
   backup first and is refused outright if the file changed on disk since the
   panel read it. It touches no other configuration.
5. **Listing, not a security review** -- which is precisely why the note below
   exists.

**The note a reviewer will want, stated plainly.** This plugin **writes a file
that Hyprland executes at every login**. That is its entire purpose, and the
README says so in as many words rather than leaving it to be discovered. What
guards it is three things: the character allowlist in
`Model.autostartCharRefused` (a line break or a control character cannot be
written at all), `luaQuote`'s escaping, and the `luac5.1 -p` gate in
`bin/omarchy-autostart-hypr-write`, which refuses a candidate that does not
compile. It writes no generated Lua anywhere and pushes nothing into the
running compositor.

- No elevated rights anywhere, no system-wide tier, no package installation.
  The expected capability baseline is therefore `installer` and nothing else.
- The automated security baseline looks for a small set of deterministic
  patterns: download-to-shell execution, execution from an unpinned external
  git source, privilege-escalation policy files that waive a password, and
  privileged process control driven from predictable shared temporary state.
  This plugin does none of them. (The policy-file one is named around its
  spelling on purpose -- this repository's own suite greps these documents for
  privileged verbs and requires zero hits, so prose that spells one out turns
  it red. `install` carries the same note for the same reason.)
- The id `smartalb.autostart` is free: absent from the listed IDs and from the
  retired ones. Retired IDs stay permanently unavailable, so an id is worth
  getting right once.

---

## Part B -- the walkthrough after an install

Run `omarchy-restart-shell` first and wait about 8 seconds. The inotify watcher
reloads the shell after any change under the plugin directory and takes running
`Process` objects with it; measuring before it has settled measures the reload.

The plugin now keeps a dated backup per write and prunes to the newest five,
so this walkthrough -- which writes more than once -- no longer costs you the
state it started from. Back the file up by hand anyway if you care about it:
five writes is five, and this list has more steps than that.

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
3. Every entry of your file is listed, one under another, **with no line
   numbers in front** -- the user asked for those to go. Compare the list
   against your own editor:

   ```bash
   grep -nE 'o\.(launch_on_start|exec_on_start)' ~/.config/hypr/autostart.lua
   ```

   Same entries, same order, nothing missing and nothing invented. The line
   numbers are still what the writer targets, so the claim every write rests
   on has not gone anywhere -- it is just no longer visible: the round-trip
   proof in `test/harness.qml` checks `raw` against the line at its number,
   and step 6 below is where your eyes confirm a write landed on the right
   line.
   An entry that runs through `o.exec_on_start` is marked `(shell)`.
4. A form the reader cannot take apart -- a nested helper such as
   `o.exec_on_start(o.launch_webapp_sole("Chat", "..."))` -- is shown
   **verbatim**, marked *not editable*, with a sentence saying why, and has no
   change or remove control. If it shows a command instead, the reader has
   guessed: report it, because a guess here becomes a wrong rewrite.
5. The header names the file, says it is the only one this panel edits, and
   gives its entry count. If the file does not exist it must say so rather
   than showing an empty panel.
6. **Add** a command by typing it. The line appears as the **last** line of
   the file, nothing else in the file moved, and a **dated backup** named
   after this plugin holds the previous content:

   ```bash
   ls -1t ~/.config/hypr/autostart.lua.smartalb-autostart.*.bak | head -1
   diff "$(ls -1 ~/.config/hypr/autostart.lua.smartalb-autostart.*.bak | tail -1)" \
        ~/.config/hypr/autostart.lua
   ```

   Exactly one added line, and no other difference.
7. **Add from your installed applications**: the picker lists real application
   names, and choosing one **fills the field** with its command rather than
   writing it. Nothing reaches the file until you press the add control.
8. **There must be no "Running programs" button.** The feature is hidden by
   request -- "das ist noch nicht so weit" -- behind
   `Model.RUNNING_PROGRAMS_ENABLED`, which is `false`. Two things to check,
   because hiding is where this goes wrong:
   - the Add row shows the command field, **Applications** and **Add**, and
     nothing else, with the field using the width the missing button freed;
   - **nothing is spawned for it.** With the panel open and closed a few
     times, no `omarchy-autostart-windows` process should ever appear:

     ```bash
     pgrep -af omarchy-autostart-windows
     ```

     Silence. A hidden picker that still starts a process on every open is
     the worst of both, which is why the route refuses before it reads and a
     structural check requires the guard to come first.

   *When it is switched back on*, the steps it needs are: the picker lists the
   open windows; unfolding one shows suggestions ordered sensibly for that
   window, each naming where it came from, with a warning on any command under
   `/tmp`, `/run` or an AppImage mount path; picking one fills the field and
   writes nothing; and a window with no command to offer is shown anyway, with
   the reason. Every one of those is still covered by `test/harness.qml`.
9. **Change** one entry: exactly that line differs afterwards, and the
    editor's field gives focus back when it closes -- press `Escape` after
    closing it and confirm the panel still closes. (A hidden field that keeps
    focus swallows `Escape` for the rest of the session; that defect has been
    measured in this project before.)
10. **Remove** one entry: exactly that line is gone, and the comment above it
    is still there.
11. Nothing was started and nothing was reloaded. The message after a write
    says so; confirm no new window appeared and that your session is
    unchanged.
12. Make the file unwritable by a second account (`chmod 664`) and try to
    write: the panel must refuse, name that reason, and change nothing.
13. Edit `autostart.lua` in your editor while the panel is open, then try to
    write from the panel: it must refuse as stale and tell you to reopen the
    panel. **This is the guard that stops a line number from a stale read
    hitting a different line.**
14. Point `autostart.lua` at a symlink and try to write: refused, with that
    reason.
15. Log out and back in: your entries start, each exactly once, and the file
    the plugin wrote is what did it.
16. **Install over the previous version and check what is NOT there.** This
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
17. `./uninstall`, then check: the plugin directory is gone and
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
one, never a partial file, and the newest dated backup always holds the
content from before the last write.

### C7. Do the backups stay bounded, and do they leave the neighbours alone?

Write from the panel more than five times, then look at the directory:

```bash
ls -1 ~/.config/hypr/ | grep -E 'autostart\.lua.*\.bak'
```

There must be at most five `autostart.lua.smartalb-autostart.*.bak` files --
and any `autostart.lua.bak` from an older version of this plugin, plus
Omarchy's `autostart.lua.pre-apply.*.bak`, must still be there untouched.
Those two are not ours to remove and the pruner refuses them by name; the
shell suite hands it both, along with a directory and a symlink named like
ours, and requires every one to be refused.

*If one of them disappears:* stop and report it. That is a file nobody can get
back.
