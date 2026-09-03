# Manual checklist

Everything on this page is a claim that **no automated test in this repository
can settle**. Two reasons, both structural:

- `Service.qml`, `Panel.qml`, `BarWidget.qml` and `Runners.qml` import
  `Quickshell.Io` and `Quickshell.Hyprland`. Those types exist only inside the
  running Quickshell runtime, so nothing here can execute those files at all.
  The test suites cover `Model.js`, the `bin/` scripts, and the *structure* of
  the QML -- never its behaviour in a live shell.
- The compositor is the other half of every placement claim. Whether Hyprland
  accepts a rule, and what it does with it, is measurable only against a
  running Hyprland.

Work through part A before submitting, part B after every install, and part C
whenever one of its questions has never been answered on this machine.

---

## Part A -- before this can be submitted

### A1. Take `preview.png`

**Not done yet, and nothing in this repository may do it**: it needs a
screenshot of the panel open in a live shell, and no automated step here is
allowed to load the plugin into a running session.

1. Install and restart the shell, then build a configuration worth showing:
   **at least four programs, three of them placed**, and a workspace table
   with **three rows**.
2. Open the panel and capture just the panel window:

   ```bash
   hyprshot -m window -o "$PWD" -f preview.png
   ```

3. Check the image before committing it: no file-system paths, no account
   names, no employer or customer data, nothing from a private window title.
4. Put it at the **repository root**, next to `manifest.json`. Marketplace
   validation looks there and nowhere else -- an image under `images/` is
   treated as absent, which is how a submission ends up listed with the
   generic placeholder.

The shell suite has an assertion for this that holds in both states: it passes
while `preview.png` is absent *and* named here as owed, and it passes once the
file is present and is a real PNG. It fails only if the obligation disappears
from both places at once.

### A2. Run the two checks this repository cannot run for you

```bash
omarchy plugin validate "$PWD"
qmllint -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" \
        BarWidget.qml Panel.qml Service.qml Runners.qml
```

`omarchy plugin validate` mirrors the checks the running shell applies to a
manifest. `qmllint` needs the shell's own import path, which only exists on a
machine with Omarchy installed.

### A3. Confirm what you are asserting in the submission

The marketplace asks the submitter to confirm ownership of the plugin **and of
the preview image**, and to state the plugin's dependencies. Note also that
approval is for *listing* and is explicitly not a security review -- so the
claims below have to be true because they are true, not because a reviewer
checked them:

- no elevated rights anywhere, no `--system` tier, no package installation;
- the expected capability baseline is therefore `installer` and nothing else;
- the place a reviewer will look first: this plugin pushes Lua into the
  running compositor. Every value that crosses that boundary arrives as
  `string.char(...)` bytes rather than as text (`Model.luaBytes`), and the
  allowlist on the fields is the second layer, not the only one.

---

## Part B -- the walkthrough after an install

Run `omarchy-restart-shell` first and wait about 8 seconds. The inotify watcher
reloads the shell after any change under the plugin directory and takes running
`Process` objects with it; measuring before it has settled measures the reload.

1. The widget is visible in the bar, and its tooltip names the right numbers.
2. A click opens the panel; a second click closes it.
3. `Escape` closes the panel.
4. **Apply** after a workspace change: `hyprctl workspacerules` shows the new
   rule, and a workspace that was already open has moved.
5. **Apply** after a program placement: a window that was already open has
   moved.
6. **Revert** discards, and "changes pending" disappears.
7. **Launch missing** starts exactly the enabled programs that are not running
   -- and **none** of them twice.
8. `omarchy-restart-shell` starts **nothing** again. That is the start marker
   doing its job.
9. **Apply twice in a row**, then:

   ```bash
   hyprctl workspacerules | grep -c "Workspace rule"
   ```

   The count must not grow on the second Apply. Background: `put()` switches
   the previously set rule off through `set_enabled(false)`, and the Hyprland
   stubs declare `set_enabled` for `HL.WorkspaceRule` exactly as they do for
   `HL.WindowRule`. That is the only evidence there is -- and this project has
   already learned that the stubs are not authoritative for the runtime:
   `HL.WindowRuleSpec` declares no `monitor` field and the field works anyway.
   *If the count grows:* rules accumulate within a session. The last matching
   one wins, so behaviour stays correct and the list just gets long -- but
   `put()` then needs a different route for workspace rules.
10. Disable the plugin through Omarchy's own plugin screen and enable it again.
11. `./uninstall`, then check: the directory is gone, the configuration file is
    still there.
12. `chmod 664` the configuration file and open the panel: it must show the
    message naming the exact command to fix the mode, and apply **nothing**.
13. Log out and back in: the enabled programs start, each exactly once, in
    their configured places.

---

## Part C -- open questions carried from the build

Each item says what to do and what a failure looks like.

### C1. Does `configreloaded` actually arrive via `onRawEvent`?

Subscribed as `Connections { target: Hyprland }`. Unverified. Watch for the
event after a config save.

*If it does not arrive:* the plugin never notices an external config change.
The named fallback is a 60 s `Timer` calling `load()`. **The fallback was
deliberately NOT added** -- the decision waits on this measurement. Do not ship
silence: either the event works, or the fallback goes in and the README says
the delay exists.

### C2. Does `exitStatus` arrive as a number, and is a normal exit 0?

`Process.NormalExit` is `undefined` in the installed API (zero `Enum {` blocks
on the `Process` type; the name appears in no file under `/usr/lib/qt6/qml/`),
so the code compares against `root.normalExit: 0`, which is
`QProcess::ExitStatus`'s value.

*If `exitStatus` arrives as something other than 0 for a clean exit:* the
marker's claim is never trusted and the autostart never runs -- silently, in
the safe direction. Check by claiming once and confirming the programs start.

### C3. Does the watchdog stay quiet on a normal boot?

The 30 s watchdog must be stopped by the success path. Measured on the shell
side that detached entries no longer hold the wrapper's stderr open (EOF at 0 s
instead of the launched program's lifetime), but whether Quickshell's `exited`
is deferred by `waitForEnd: true` is unverified.

*If it fires:* a false error banner at **every login**, which reads to a user
as "the plugin is broken on first use".

### C4. Does one `omarchy-restart-shell` leave the session single?

The marker's whole purpose. Restart the shell and confirm no program starts
twice.

*If it doubles:* the claim is being read as granted when it was refused -- the
defect found in round 1, where `head` swallowed the exit status.

### C5. Do the two argued Processes hold their invariant in practice?

`readProc` and `evalProc` enforce one-run-per-Process mechanically
(`readBusy`/`pendingLoad`, `evalBusy`/`pendingChunkRun`). `markerProc` and
`launchProc` rest on a timing argument: they are only reached again through a
fresh `readProc` cycle, so a queued signal from a previous dispatch arrives and
is rejected first. Accepted as an assumption, recorded here because it is not
proven.

*Exercise:* save the configuration repeatedly during startup and confirm the
rules end up applied and the session started exactly once.

### C6. Is the error a user sees a real one?

Five `onExited` handlers comparing `exitCode !== 0` after a `run.tool(...)`
call were dead code until round 1 -- a pipeline reports `head`'s status, so
every script failure read as success. They are live for the first time and have
never fired in anger.

*Exercise:* make one `bin/` script fail on purpose and confirm the panel says
so.

### C7. Does the `[+ Add]` picker actually fill up?

`run.tool("omarchy-autostart-apps")` is read through a `StdioCollector`, and
nothing here can execute a file that imports `Quickshell.Io`. Open the panel,
press `[+ Add]`, and confirm the list appears with real application names.

*If it stays on "Reading the installed applications...":* neither
`onStreamFinished` nor `onExited` arrived. *If it says "No installed
applications were found":* the script answered nothing -- run
`bin/omarchy-autostart-apps` by hand and compare. *If it says "Could not read
the list of installed applications":* either the script failed (a real exit
status now survives `run.tool`) or its JSON was cut off by `runnerOut`'s
256 KiB cap. On a machine with very many `.desktop` files the cap is the
likelier of the two -- measure the byte size of the script's own output.

### C8. Does the import run once the application list is in?

The import is triggered from `appsProc`'s `onStreamFinished`, not from
`onExited`, because it needs `root.apps` and that is where `root.apps` arrives.
Which of the two Quickshell emits first is unverified and deliberately not
depended on.

*Exercise:* with an empty configuration, press `[Import current session]` and
confirm one disabled row per open window class appears and the workspace table
fills from the live state. *If nothing happens:* `onStreamFinished` did not
fire, and the flag `importPending` is left cleared by `onExited` only on a
failure -- check for an error line in the panel.

### C9. Would a Hyprland refusal of the pattern be visible at all?

Ask this question before C9b. `hl.window_rule` is called without `pcall`, so a
Lua error inside the chunk is not caught by us, and the only signal the panel
has is `hyprctl`'s exit code -- which nothing here has measured for the *eval*
verb. A rule Hyprland silently ignores and a rule it applies look identical
from the panel.

*Exercise:* feed `hyprctl eval` a chunk that is certain to fail (a call to a
nonexistent `hl.` function) and record the exit code and stderr. If it exits 0,
then `Panel.qml`'s "hyprctl refused a rule block" branch is unreachable and the
placement path has no error report at all -- say so before C9b's answer is
trusted.

### C9b. Does a class picked with `[From window]` really match its window?

Measured for the MATCH path: the pattern `classLiteral` produces goes through
the real `grep -E` in `test/run-tests.sh` and finds exactly the window it was
built from. GNU grep warns "stray \ before -" / "before :" on the escaped
punctuation and honours it as a literal; the script sends grep's stderr to
`/dev/null`, so the warning is not visible anywhere.

NOT measured for the PLACEMENT path: the same pattern travels into
`hl.window_rule({ match = { class = ... } })`, and Hyprland's own regex engine
has never seen it here. `\-` and `\:` are legal punctuation escapes in
ECMAScript `std::regex` and in RE2, which is the argument, not a measurement.

*Exercise:* pick the class of a webapp window (a `nimbus-web.*__-Default` class
is the case this exists for), apply, close and reopen that window, and confirm
it lands on the configured workspace. *If it does not:* Hyprland refused or
mis-parsed the escaped pattern, and the escape set in `Model.classLiteral` has
to lose `-` and `:` -- with the harness assertion and the shell assertion that
name the exact literal brought along.

### C10. Does `[From window]` pick for the row it was opened on?

`pickForRow` is an INDEX and the picker's own delegate has an `index` of its
own. Measured offscreen that a nested `Repeater` delegate's `index` shadows the
outer row's (it differed from the row index in 4 of 6 delegates), which is why
the click passes `programRow.rowIndex`. What the measurement cannot show is the
live panel.

*Exercise:* with three program rows, open the SECOND row's `[From window]`,
pick a window, and confirm the class landed in the second row and nowhere else.

### C11. What does the user see when the application list is too long?

`runnerOut` announces truncation on stderr and `appsProc` now collects it, so
`Model.appsProblem` can say "too long to read in full" instead of "could not be
read". Reachable, not theoretical: at the reviewer's measured ~137 bytes per
entry the script's 2000-file bound reaches 230-270 KB against a 256 KiB cap.

*Exercise:* point `DESKTOP_DIRS` at a directory with enough generated
`.desktop` files to pass the cap, open `[+ Add]`, and confirm the sentence
names the length. *If it says "could not be read":* the stderr collector did
not fire, or the marker text drifted -- the cross-file check in
`qml-structure.sh` covers the second.

### C12. Is an imported window with no known command visibly incomplete?

The import no longer guesses a command from the window class (that was an
injection path). Such an entry arrives with an empty command, which
`validate()` names `command-invalid`.

*Exercise:* import a session containing a window whose class matches no
`.desktop` entry, and confirm the row carries the "left out until it is fixed"
line and the omissions list names it.

*If the row looks ordinary:* the row marker is bound to `checked.programs` by
identity -- that binding, not the import, is what to look at.

### C13. Is a launch failure reported anywhere? (No -- confirm it stays that way.)

Measured on the shell side: a nonexistent program, an exit 127, a program that
exits non-zero, and a program writing its own error message all produce empty
stderr and a wrapper exit of 0. The launch path cannot see any of them.

The only report that reaches the user is the other way round -- the count of
enabled programs for which no window ever matched, shown under the list. The
README says this plainly rather than implying the plugin detects launch
failures.

*Exercise:* enable a program whose command is `definitely-not-a-program`,
apply, log in, and confirm that (a) nothing claims it started successfully and
(b) it appears in the "configured but no window ever matched" line with the
*Launch missing* button next to it.
