#!/usr/bin/env bash
# Runs every mutation probe from the plan, one at a time.
#
# A structural test that survives its own mutation does not hold the property
# it claims to hold. Each probe below breaks exactly one guarded property and
# fails if the suite that is supposed to notice stays green.
#
# Each probe: copy the file aside, mutate it, expect the suite to go red,
# restore from the copy, expect green again.
#
# WHY NOT `git checkout -- .`, which the plan's sketch used: this repository is
# also where the plan and the spec are edited, and three times in this project
# a probe ending in a checkout took uncommitted work with it. A probe here
# touches exactly one named file and restores it from a copy verified with
# `cmp`. Nothing consults git, and a dirty working tree is not an obstacle.
#
# A MUTATION THAT CHANGES NOTHING IS THE FAILURE MODE THIS SCRIPT IS MOST
# EXPOSED TO. Once a sed pattern drifts out of date it matches nothing, the
# suite stays green because nothing was broken, and "the suite went red" is
# never printed -- but neither is anything alarming, unless somebody compares
# the probe count against what the file contains. So every probe compares the
# file against its own copy after mutating and fails BY NAME if the two are
# identical.
#
# THE ASSERTION-COUNT GUARD IN run-qml-tests.sh IS NOT MUTATED AWAY, IT IS
# PROBED. That guard requires the number of assertion call sites in
# harness.qml to EQUAL the number the run performs -- equality, not a floor,
# because "ran at least N" is exactly what a silently skipped block still
# satisfies. Probe "guard: an assertion in the file that never runs" adds a
# call site inside a block that cannot execute and requires the guard to
# catch it (the runner exits 4). Nothing here relaxes the guard, and no probe
# adds an assertion inside a loop, which would trip it for real.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

WORK="$(TMPDIR=/tmp mktemp -d)" || { echo "mutations: mktemp -d failed" >&2; exit 2; }

# THE FILE UNDER MUTATION RIGHT NOW, or empty between probes. An interrupted
# run used to leave a shipped file mutated AND delete the backup its own
# failure message pointed at -- reproduced during the final review, which left
# manifest.json carrying an injected "overlay": "Panel.qml" entry point with
# the copy already gone. Two probes make that more than cosmetic: one adds
# `rm -f -- "$CONFIG"` to `uninstall`, another adds a privileged verb to
# README.md.
#
# So the restore runs on EVERY exit path, and it runs BEFORE the work
# directory is removed. `restore_now` is idempotent and safe to call with
# nothing in flight. Note the ordering: the INT/TERM handlers restore and then
# exit, which fires the EXIT trap, which restores again (a no-op the second
# time) and only then deletes the backups.
IN_FLIGHT=""
IN_FLIGHT_BACKUP=""

restore_now() {
    [[ -n "$IN_FLIGHT" && -n "$IN_FLIGHT_BACKUP" && -f "$IN_FLIGHT_BACKUP" ]] || return 0
    if cp -- "$IN_FLIGHT_BACKUP" "$ROOT/$IN_FLIGHT"; then
        printf '\nmutations: interrupted -- restored %s from its copy\n' "$IN_FLIGHT" >&2
    else
        printf '\nmutations: INTERRUPTED AND COULD NOT RESTORE %s.\n       Restore it by hand from %s BEFORE that directory is gone.\n' \
               "$IN_FLIGHT" "$IN_FLIGHT_BACKUP" >&2
        # Leave the backup behind rather than deleting the only copy.
        WORK=""
    fi
    IN_FLIGHT=""; IN_FLIGHT_BACKUP=""
}

cleanup() {
    restore_now
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    return 0
}

trap cleanup EXIT
trap 'restore_now; exit 130' INT
trap 'restore_now; exit 143' TERM
trap 'restore_now; exit 129' HUP

run=0; failed=0; skipped=0

# RUN A SUBSET, DELIBERATELY AND VISIBLY. A full run is 108 probes at roughly a
# minute each, because every probe runs a whole suite twice; verifying the
# probes added by one task should not cost an hour and a half.
#
# PROBE_ONLY is an extended regular expression matched against the probe NAME.
# Unset means every probe, which is the only thing a release run may do. A
# filtered run prints how many it skipped and says in as many words that it
# proves nothing about them -- a subset that reports itself as a full pass is
# exactly the blind shape this whole file exists to refuse.
PROBE_ONLY="${PROBE_ONLY:-}"

fail() { failed=$((failed + 1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

# probe NAME SUITE FILE SED-EXPRESSION
probe() {
    local name="$1" suite="$2" file="$3" expr="$4"
    if [[ -n "$PROBE_ONLY" ]] && ! grep -qE -- "$PROBE_ONLY" <<<"$name"; then
        skipped=$((skipped + 1))
        return
    fi
    run=$((run + 1))
    local backup="$WORK/${file//\//_}"

    if [[ ! -f "$ROOT/$file" ]]; then
        fail "$name" "$file does not exist, so nothing was probed"
        return
    fi
    cp -- "$ROOT/$file" "$backup" || { fail "$name" "could not copy $file aside"; return; }

    # From here until the restore below, an interrupt must put this file back.
    IN_FLIGHT="$file"; IN_FLIGHT_BACKUP="$backup"

    sed -i -e "$expr" -- "$ROOT/$file"
    if cmp -s -- "$ROOT/$file" "$backup"; then
        # Restore anyway, so a later probe on the same file starts clean.
        cp -- "$backup" "$ROOT/$file"
        IN_FLIGHT=""; IN_FLIGHT_BACKUP=""
        fail "$name" "the mutation changed nothing -- the pattern no longer matches $file"
        return
    fi

    if "$suite" >/dev/null 2>&1; then
        fail "$name" "the suite stayed green under mutation -- $suite does not hold this property"
    else
        printf 'ok   %s -- the suite went red\n' "$name"
    fi

    cp -- "$backup" "$ROOT/$file"
    if ! cmp -s -- "$ROOT/$file" "$backup"; then
        # Keep the backup: it is the only copy of the original left.
        WORK=""
        fail "$name" "the restore of $file did not take -- STOP and restore it by hand from $backup"
        return
    fi
    IN_FLIGHT=""; IN_FLIGHT_BACKUP=""
    if ! "$suite" >/dev/null 2>&1; then
        fail "$name" "the suite did not recover after $file was restored"
    fi
}

SHELL_SUITE=./test/run-tests.sh
QML_SUITE=./test/run-qml-tests.sh
STRUCT_SUITE=./test/qml-structure.sh
SHAPE_SUITE=./test/runners-shape.sh

# A probe can only mean anything if the suite is green to begin with. Checked
# once per suite up front, by name, rather than inferred from the first probe.
for pair in "$SHELL_SUITE" "$QML_SUITE" "$STRUCT_SUITE" "$SHAPE_SUITE"; do
    if ! "$pair" >/dev/null 2>&1; then
        printf 'FAIL baseline -- %s is already red before any mutation; nothing below can be trusted\n' "$pair"
        printf '\nmutation probes: total=0 failed=1\n'
        exit 1
    fi
done
echo "baseline: all four suites are green"

# --- the bin/ scripts -------------------------------------------------------

probe "apps: the file count cap" "$SHELL_SUITE" bin/omarchy-autostart-apps \
  's/^            (( count >= MAX_FILES )) && break 2/            :/'

probe "windows: the window count cap" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  's/^        | \.\[0:$max\]$/        | .[0:99999]/'

# --- the QML files, structurally -------------------------------------------

# --- the removed half cannot grow back --------------------------------------
#
# Both of these guard an ABSENCE, and an absence check has to be probed or it
# proves nothing: the check that stood in this place required every
# rule-construction site in Model.js to mention luaBytes(), and once there were
# no such sites it passed over an empty set for a whole round.

probe "removal: a rule construction cannot come back into Model.js" "$STRUCT_SUITE" Model.js \
  's|^function luaQuote(s) {$|function luaQuote(s) {\n    if (false) return "hl.window_rule({ x = 1 })";|'

probe "removal: an eval verb cannot come back into Model.js" "$STRUCT_SUITE" Model.js \
  's|^function luaQuote(s) {$|function luaQuote(s) {\n    if (false) return "eval";|'

probe "runners: bash named by absolute path" "$STRUCT_SUITE" Runners.qml \
  's|"/usr/bin/bash"|"bash"|'

probe "runners: the producer's own exit status" "$SHAPE_SUITE" Runners.qml \
  's/s=${PIPESTATUS\[0\]}/s=$?/'

probe "barwidget: the glyph stays a \\u escape" "$STRUCT_SUITE" BarWidget.qml \
  's/"\\uf135"/""/'

# --- the submission set -----------------------------------------------------

probe "manifest: a panel kind would move the plugin off the bar" "$SHELL_SUITE" manifest.json \
  's/"kinds": \["bar-widget"\]/"kinds": ["bar-widget", "panel"]/'

# An entry point whose kind is not declared. This is the direction NOTHING
# else caught: it is not `panel`, so the "no panel key" assertion passes; the
# kinds list is untouched, so the sorted-kinds assertion passes; and
# `omarchy plugin validate` only checks kind -> entryPoint, so the platform
# validator passes it too. Only the pair check refuses it.
probe "manifest: an entry point with no kind to load it" "$SHELL_SUITE" manifest.json \
  's|"barWidget": "BarWidget.qml"|"barWidget": "BarWidget.qml",\n    "overlay": "Panel.qml"|'

# The opposite direction: the kind gone while its entry point stays. This is
# the exact inconsistent pair that would ship a plugin whose autostart never
# runs, and it is what fix round 1 was raised about. Probed the other way
# round now that "service" is gone from both halves -- the entry point is
# re-added alone, which is the same inconsistent pair reached from the side
# this removal could actually have left behind.
probe "manifest: a kind removed while its entry point stays" "$SHELL_SUITE" manifest.json \
  's|"barWidget": "BarWidget.qml"|"barWidget": "BarWidget.qml",\n    "service": "Service.qml"|'

# AND THE KIND WITHOUT THE FILE. Re-declaring "service" alongside an
# entryPoints.service that names a Service.qml which is not on disk is exactly
# the state that once meant the plugin's whole purpose was silently absent
# while `omarchy plugin validate` still exited 0. Both halves consistent with
# each other, and neither consistent with the repository.
probe "manifest: the service kind and entry point cannot come back together" "$SHELL_SUITE" manifest.json \
  's|"kinds": \["bar-widget"\],|"kinds": ["bar-widget", "service"],|
   s|"barWidget": "BarWidget.qml"|"barWidget": "BarWidget.qml",\n    "service": "Service.qml"|'

# --- an upgrade must not leave a removed file behind -----------------------
#
# THE DEFECT THIS EXISTS FOR, measured on the user's own machine: `install`
# copied its file list over whatever was at the target, so Service.qml,
# bin/omarchy-autostart-config and bin/omarchy-autostart-marker survived the
# build that deleted them -- and every assertion this repository had about
# `install` passed over that directory, because all of them asked only whether
# the NEW files had arrived.
#
# The mutation puts the old shape back exactly: the previous directory is not
# parked out of the way, and the staged content is merged into the target
# instead of renamed onto it.
probe "install: an upgrade must not leave a removed file behind" "$SHELL_SUITE" install \
  's|^    if \[\[ -e "$TARGET" \]\]; then$|    if false; then|
   s|^    mv -- "$STAGE" "$TARGET"$|    mkdir -p "$TARGET"; cp -r -- "$STAGE/." "$TARGET/"|'

# And the two halves of the path guard, one probe each. An absence guard that
# is never handed the input it refuses is a guard nobody has seen work.
probe "install: only a directory the installer made may be removed" "$SHELL_SUITE" install \
  's|^    if \[\[ "$base" != ".$ID."\* \]\]; then$|    if false; then|'

probe "uninstall: a target that does not resolve to the plugin directory is refused" "$SHELL_SUITE" uninstall \
  's|^    if \[\[ -z "$ID" \|\| "${target_real##\*/}" != "$ID" \|\| "${target_real%/\*}" != "$plugins_real" \]\]; then$|    if false; then|'

probe "readme: a privileged verb in prose" "$SHELL_SUITE" README.md \
  's/^## Tests$/## Tests\n\nIf a test fails, re-run it with sudo.\n/'

# THE PROPERTY TURNED AROUND. There is no configuration of this plugin's own
# left to keep -- the JSON file went with the removed half -- so what uninstall
# must now be held to is that it removes the plugin AND TOUCHES NOTHING ELSE.
# The one file this plugin ever wrote is the user's own autostart.lua, and this
# probe makes uninstall delete it.
probe "uninstall: the user's own autostart.lua is not removed with the plugin" "$SHELL_SUITE" uninstall \
  's|^cat <<NOTE$|rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/autostart.lua"\ncat <<NOTE|'

probe "checklist: the preview obligation cannot just vanish" "$SHELL_SUITE" CHECKLIST.md \
  's/preview\.png/preview-image/g'

# The README and preview.png must agree -- that is how a broken image sat at
# the top of the first page a reviewer opens while all five suites stayed
# green. The coupling is state-dependent, so the mutation has to be: with no
# image on disk, ADDING a reference must go red; once the screenshot has been
# taken, REMOVING it must go red. A single fixed expression would silently
# stop proving anything the moment the file lands.
if [[ -f preview.png ]]; then
    probe "readme: the existing screenshot must be shown" "$SHELL_SUITE" README.md \
      's|^!\[.*\](preview\.png)$||'
else
    probe "readme: no image reference while preview.png does not exist" "$SHELL_SUITE" README.md \
      's|^## What it does$|![The Autostart Layout panel](preview.png)\n\n## What it does|'
fi

# --- the reader for the user's Hyprland Lua files ---------------------------
#
# THE FOUNDATION PROBE IS THE FIRST ONE. Every other property of this reader
# is decoration if `line` and `raw` do not agree with the input, because the
# writer that comes next does line surgery on somebody's hand-maintained
# configuration. A reader that reports the right command against the wrong
# line number passes every readable assertion and then edits the wrong line --
# and this project has already had that class of defect reach a real window.

probe "hypr: the line number is 1-based" "$QML_SUITE" Model.js \
  's/n + 1, raw,/n, raw,/g'

probe "hypr: raw is the line untouched, indentation included" "$QML_SUITE" Model.js \
  's|raw: raw, fn: name|raw: String(raw).replace(/^ +/, ""), fn: name|'

probe "hypr: comment and blank lines are counted like any other" "$QML_SUITE" Model.js \
  's|: text).split("\\n");|: text).split("\\n").filter(function(l) { return l !== ""; });|'

probe "hypr: a form it cannot take apart is reported, not dropped" "$QML_SUITE" Model.js \
  's|^        entry.reason = /.*nested-call.*$|        continue;|'

probe "hypr: a refusal code cannot reach the panel unworded" "$QML_SUITE" Model.js \
  's|^    "incomplete-call"        // the call does not end on this line$|    "incomplete-call",       // the call does not end on this line\n    "no-wording-for-this"|'

probe "hypr script: the file bytes cross into JSON verbatim" "$SHELL_SUITE" bin/omarchy-autostart-hypr \
  's|--rawfile c "\$TMPFILE"|--arg c "$(cat "$TMPFILE")"|'

probe "hypr script: the truncation flag" "$SHELL_SUITE" bin/omarchy-autostart-hypr \
  's|^    if (( size > MAX_BYTES_PER_FILE )); then$|    if false; then|'

probe "hypr script: the cut is to exactly the cap, not the detection byte" "$SHELL_SUITE" bin/omarchy-autostart-hypr \
  's|head -c "\$MAX_BYTES_PER_FILE" "\$dst"|head -c $((MAX_BYTES_PER_FILE + 1)) "$dst"|'

probe "hypr script: only a readable plain file counts as present" "$SHELL_SUITE" bin/omarchy-autostart-hypr \
  's|if \[\[ -f "\$path" \&\& -r "\$path" \]\]; then|if [[ -e "$path" ]]; then|'

# --- WRITING autostart.lua --------------------------------------------------
#
# The file under this writer RUNS AT EVERY LOGIN, so each probe below turns off
# exactly one of its safeguards and requires a suite to notice. A green suite
# over a disarmed guard here is the difference between a change taking effect
# and a session that does not start the user's programs.

# The reader half the writer stands on: a line inside a block comment came back
# editable before the task 18 review found it, so changing it would have
# rewritten a line the user had deliberately switched off.
probe "autostart: a block-commented line is not an entry" "$QML_SUITE" Model.js \
  '/if (inBracket\[n\]) continue;/d'

probe "autostart: the bracket scanner keeps its state across lines" "$QML_SUITE" Model.js \
  's|^        flags.push(level >= 0);$|        flags.push(false);|'

probe "autostart: a quoted string does not open a bracket" "$QML_SUITE" Model.js \
  's|^                var str = luaStringAt(line, i);$|                var str = null;|'

# The escaper. Dropping either escape is silent in the file and fatal at login.
probe "autostart: a double quote is escaped" "$QML_SUITE" Model.js \
  's|out += BACKSLASH + QUOTE;|out += QUOTE;|'

probe "autostart: a backslash is escaped" "$QML_SUITE" Model.js \
  's|out += BACKSLASH + BACKSLASH;|out += BACKSLASH;|'

probe "autostart: the literal is quoted at all" "$QML_SUITE" Model.js \
  's|return QUOTE + out + QUOTE;|return out;|'

# The allowlist, and the throw that makes it unbypassable.
probe "autostart: luaQuote throws on a character it cannot write" "$QML_SUITE" Model.js \
  's|        if (autostartCharRefused(code)) {|        if (false) {|'

probe "autostart: a control character is refused" "$QML_SUITE" Model.js \
  's|^    if (code < 0x20) return true;$|    if (code < 0x00) return true;|'

probe "autostart: an empty command is refused" "$QML_SUITE" Model.js \
  's|return "empty-command";|return null;|'

probe "autostart: a command past the cap is refused" "$QML_SUITE" Model.js \
  's|return "command-too-long";|return null;|'

# The surgery itself. Each of these three changes exactly one line of Model.js
# and makes a byte-exact assertion red.
probe "autostart: add appends, it does not prepend" "$QML_SUITE" Model.js \
  's|^        appended.push(autostartLine(String(operation.command)));$|        appended.unshift(autostartLine(String(operation.command)));|'

probe "autostart: change replaces the line named and no other" "$QML_SUITE" Model.js \
  's|^    out\[wanted - 1\] = autostartLine(String(operation.command));$|    out[wanted] = autostartLine(String(operation.command));|'

probe "autostart: remove deletes one line, not two" "$QML_SUITE" Model.js \
  's|^        out.splice(wanted - 1, 1);$|        out.splice(wanted - 1, 2);|'

probe "autostart: the file keeps its single trailing newline" "$QML_SUITE" Model.js \
  's|return lines.join("\\n") + "\\n";|return lines.join("\\n");|'

# THE NON-EDITABLE ENTRY, which in the user's file is the nested Chat line.
# With this check gone, the plugin would rewrite a line it cannot represent.
probe "autostart: a non-editable entry cannot be changed or removed" "$QML_SUITE" Model.js \
  's|^    if (found.editable !== true) return { ok: false, error: "entry-not-editable" };$|    if (false) return { ok: false, error: "entry-not-editable" };|'

probe "autostart: a line that holds no entry cannot be edited" "$QML_SUITE" Model.js \
  's|^    if (found === null) return { ok: false, error: "no-entry-on-line" };$|    if (found === null) found = { editable: true, raw: lines[wanted - 1] };|'

# THE ONE-LINE ASSERTION'S OWN SENSITIVITY. If oneLineDifference reported "one
# line" for two edits, every surgery assertion above would be decoration.
probe "autostart: the one-line proof notices a second changed line" "$QML_SUITE" Model.js \
  's|^            if (at !== -1) return "multiple";$|            if (false) return "multiple";|'

probe "autostart: the one-line proof notices a shifted tail" "$QML_SUITE" Model.js \
  's|^        for (var j = i; j < a.length; j++) if (a\[j\] !== b\[j + 1\]) return "multiple";$|        for (var j = i; j < a.length; j++) if (false) return "multiple";|'

# The section the surgery reads its bytes from, and which section may be
# written at all.
probe "autostart: the section carries the bytes the surgery works on" "$QML_SUITE" Model.js \
  's|^            content: present ? String(f.content \|\| "") : "",$|            content: "",|'

probe "autostart: only autostart.lua is writable" "$QML_SUITE" Model.js \
  's|^    if (String(s.name) !== "autostart.lua") return false;$|    if (false) return false;|'

probe "autostart: a truncated read is not writable" "$QML_SUITE" Model.js \
  's|^    if (s.truncated === true) return false;$|    if (false) return false;|'

probe "autostart: a refusal code cannot reach the panel unworded" "$QML_SUITE" Model.js \
  '/^    case "entry-not-editable":$/,+2d'

# --- the writer script's own guards -----------------------------------------

# THE luac5.1 GATE, and it is the strongest safeguard in this task. Disarmed,
# a file that will not compile is renamed into place and the next login fails.
probe "writer: the syntax gate actually gates" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    if ! diagnostic="$("$luac" -p "$STAGEFILE" 2>&1)"; then$|    if false; then diagnostic=""|'

probe "writer: an absent Lua compiler is a refusal, not a skip" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    return 1$|    printf "/bin/true\\n"; return 0|'

# THE FRESHNESS CHECK. This is a file the user also edits by hand.
probe "writer: a file that changed on disk is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|\[\[ "$current" == "$expect_mtime" \]\]|[[ "$current" == "$current" ]]|'

# THE ONLY WAY BACK: ~/.config/hypr is not under version control.
probe "writer: the backup is taken before the replacement" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|cp -p -- "$TARGET" "$BACKUP"|true|'

probe "writer: a symlink is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    \[\[ ! -h "$TARGET" \]\] \|\| err "is-a-symlink"|    [[ 1 -eq 1 ]] \|\| err "is-a-symlink"|'

probe "writer: a group-writable file is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    if (( 8#$mode \& 8#22 )); then$|    if (( 8#$mode \& 8#00 )); then|'

probe "writer: an absent file is not written into existence" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    \[\[ -e "$TARGET" \]\] \|\| err "not-a-file" "$TARGET does not exist"$|    [[ -e "$TARGET" ]] \|\| touch "$TARGET"|'

probe "writer: a candidate past the cap is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^        err "too-large" "the candidate exceeds $MAX_BYTES bytes"$|        true|'

probe "writer: the replacement is staged beside the destination" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|mktemp "$HYPR_DIR/.autostart.lua.XXXXXX"|mktemp|'

probe "writer: the staged file gets the original's permissions" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|chmod --reference="$TARGET" "$STAGEFILE"|true|'

# --- the panel's one route to the file --------------------------------------
# The substituted name is a script that does not exist, which is the point:
# any second route to disk is a route the writer's own guards -- the freshness
# check, the backup, the luac gate -- do not stand in front of.
probe "panel: the write goes through the writer script, not a second route" "$STRUCT_SUITE" Panel.qml \
  's|omarchy-autostart-hypr-write|omarchy-autostart-somewhere-else|'

probe "panel: the new content is shell-quoted" "$STRUCT_SUITE" Panel.qml \
  's|Model.shellQuote(result.text)|result.text|'

probe "panel: a refused operation never arms the Process" "$STRUCT_SUITE" Panel.qml \
  '/^        if (!result.ok) {$/,+3d'

probe "panel: the row controls are gated on the entry being editable" "$STRUCT_SUITE" Panel.qml \
  's|hyprEntryRow.entry.editable === true|true|'

probe "panel: the count is derived in Model.js, not in the panel" "$STRUCT_SUITE" Panel.qml \
  's|Model.hyprProgramCount(root.hyprSections)|0|'

# AND BarWidget's handler must match the signal's arity. A second parameter on
# a one-argument signal is not an error in QML -- it simply arrives undefined,
# and the tooltip reads "3 programs, undefined placements" with nothing failing
# anywhere. That is the shape this removal actually left behind once.
probe "barwidget: the counted handler takes exactly the signal's one argument" "$STRUCT_SUITE" BarWidget.qml \
  's|counted.connect(function(programs) {|counted.connect(function(programs, placements) {|'

probe "panel: the counted signal carries exactly one number" "$STRUCT_SUITE" Panel.qml \
  's|signal counted(int programs)|signal counted(int programs, int placements)|'

# The change editor's focus hand-off. Without it a hidden TextField stays the
# window's activeFocusItem and Escape is swallowed for the rest of the open
# session -- the defect this project measured once already, on the program rows.
probe "panel: the change editor hands focus back before it hides the field" "$STRUCT_SUITE" Panel.qml \
  '/^    function autostartCloseEditor() {$/,/^    }$/{/forceActiveFocus/d}'

probe "panel: the change editor is closed in exactly one place" "$STRUCT_SUITE" Panel.qml \
  '/^    function reload() {$/,/^    }$/{s|root.autostartCloseEditor()|root.autostartEditLine = -1|}'

# --- FROM A RUNNING PROGRAM TO AN AUTOSTART COMMAND -------------------------
#
# Every assurance this task added, handed the input it was written to catch.
# The ranking probe is the one that matters most: without it his Webmail
# window offered YouTube Music first, and the suite said nothing.

probe "candidates: the host in the window class is what orders the suggestions" "$QML_SUITE" Model.js \
  's|if (host !== "" && command.indexOf(host) >= 0) hosted.push(row);|if (false) hosted.push(row);|'

probe "candidates: the browser name in front of the host is not part of the host" "$QML_SUITE" Model.js \
  's|    if (lastDash >= 0) token = token.substring(lastDash + 1);|    if (false) token = token.substring(lastDash + 1);|'

probe "candidates: the volatile path prefixes" "$QML_SUITE" Model.js \
  's|        if (first.indexOf(UNSTABLE_PREFIXES\[i\]) === 0) return true;|        if (false) return true;|'

probe "candidates: a .mount_ segment anywhere in the path" "$QML_SUITE" Model.js \
  's|    return /(\^\|\[\\/ \\t\])\\.mount_/.test(text);|    return false;|'

probe "candidates: the .desktop matched on the window class ranks first" "$QML_SUITE" Model.js \
  's|            byClass.push({ command: command, source: "desktop-class", name: name });|            other.push({ command: command, source: "desktop-class", name: name });|'

probe "candidates: the .desktop matched on the running program is offered at all" "$QML_SUITE" Model.js \
  's|        if (program !== "" && commandProgram(command) === program) {|        if (false) {|'

probe "candidates: the running command line is offered last" "$QML_SUITE" Model.js \
  's|        ordered.push({ command: running, source: "running", name: "" });|        true;|'

# HELD BY NOTHING UNTIL THIS PROBE WAS BELIEVED. It reported green for two
# rounds: the assertion meant to hold it -- Termpane, matched by class and by
# binary -- is made one entry by the loop's own `continue`, not by this guard.
# Two assertions naming the inputs that really do produce a duplicate command
# were added to test/harness.qml; this now turns them red.
probe "candidates: one command is offered once" "$QML_SUITE" Model.js \
  's|        if (seen\[candidate.command\]) continue;|        if (false) continue;|'

probe "candidates: an exact duplicate is told apart from the same program" "$QML_SUITE" Model.js \
  's|    if (exact) out.push("already-present");|    if (false) out.push("already-present");|'

probe "candidates: the list is capped" "$QML_SUITE" Model.js \
  's|out.length < MAX_CANDIDATES|out.length < 999|'

probe "candidates: a warning is not suppressed by another warning" "$QML_SUITE" Model.js \
  's|    if (commandIsUnstablePath(command)) out.push("unstable-path");|    if (out.length > 0 \&\& commandIsUnstablePath(command)) out.push("unstable-path");|'

probe "candidates: the two reasons for an empty list are told apart" "$QML_SUITE" Model.js \
  's|    return windowProgram(window) === "" ? "no-command-line" : "command-too-long";|    return "no-command-line";|'

probe "candidates: the program field of a window wins over its command line" "$QML_SUITE" Model.js \
  's|    return named !== "" ? commandProgram(named) : commandProgram(source.command);|    return commandProgram(source.command);|'

# --- the window helper reading /proc ----------------------------------------

probe "windows: a command line past the cap is empty, not truncated" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  's|then "" else $c end|then $c else $c end|'

probe "windows: the program survives as a basename, not a whole path" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  's|        def basename: split("/") \| last // "";|        def basename: .;|'

probe "windows: the control characters in a command line are squashed" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  '/^        def clean:/s|"\[\[:cntrl:\]\]"|"[[:cntrl:]]zz"|'

# The pattern is a bracket expression around the backslash -- "[\]t" is one
# literal backslash followed by "t" -- because a backslash inside a sed regex
# followed by a digit or a letter is not a literal backslash. What stood here
# needed two characters before each letter where the file has one, so it
# matched nothing and this probe reported "the mutation changed nothing" for
# two rounds. The pid and the command line still travel to jq as one
# tab-separated line, so the guard it points at is still real.
probe "windows: a tab in a command line cannot shift a field" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  '/ tr /s|[\]t||'

# "#" as the delimiter, not "|": the line under mutation is a jq pipeline and
# contains the character sed would otherwise read as the end of the pattern.
probe "windows: the pid does not leave the script" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  's#| map({ address, class, title, workspace, monitor,#| map({ address, class, title, workspace, monitor, pid,#'

# --- the panel's picker -----------------------------------------------------

probe "panel: the suggestions come from Model.js, not from the panel" "$STRUCT_SUITE" Panel.qml \
  's|Model.autostartCandidatesForWindow(|Model.somethingElseEntirely(|'

probe "panel: opening the running-programs list reads the applications too" "$STRUCT_SUITE" Panel.qml \
  '/^    function autostartFromWindowToggle() {$/,/^    }$/{s|        root.startAppsRead()||}'

probe "panel: picking a suggestion writes nothing" "$STRUCT_SUITE" Panel.qml \
  '/^    function autostartUseCandidate(command) {$/,/^    }$/{s|root.autostartNewCommand = String(command \|\| "")|root.autostartWrite(root.autostartOperation("add", undefined, command))|}'

probe "panel: every warning a suggestion carries is shown" "$STRUCT_SUITE" Panel.qml \
  's|model: autostartCandidate.modelData.warnings \|\| \[\]|model: []|'

probe "panel: a window with no suggestion shows its reason" "$STRUCT_SUITE" Panel.qml \
  's|Model.candidateReasonText(|String(|'

probe "panel: every suggestion row names where it came from" "$STRUCT_SUITE" Panel.qml \
  's|Model.candidateSourceText(|String(|'

probe "panel: the window row is not addressed by a bare index" "$STRUCT_SUITE" Panel.qml \
  's|onClicked: root.autostartWindowUnfold(autostartWindowEntry.windowIndex)|onClicked: root.autostartWindowUnfold(index)|'

probe "panel: the outer index is captured under a name of its own" "$STRUCT_SUITE" Panel.qml \
  's|readonly property int windowIndex: index|readonly property int windowIndex: 0|'

# --- the guards themselves --------------------------------------------------
#
# Two probes of the two mechanisms that exist because an assertion which does
# not run looks exactly like one that passes. Neither guard is weakened here;
# each is handed the input it was written to catch.

# harness.qml gains one call site inside a block that cannot execute. declared
# becomes one more than ran, and run-qml-tests.sh must exit 4.
probe "guard: an assertion in the file that never runs" "$QML_SUITE" test/harness.qml \
  's|^            // --- shellQuote|            if (false) { check("an assertion that never runs", 1, 1); }\n            // --- shellQuote|'

# run-tests.sh loses one invocation line. The suite's own invocation guard
# (test/lib.sh) must name the function that stopped running.
#
# The line named here has to be one that EXISTS: this probe pointed at
# test_marker_release_removes_the_marker_file, which went with the start
# marker, and a probe that deletes nothing reports "the mutation changed
# nothing" rather than proving the guard works.
probe "guard: a test function that is defined but never invoked" "$SHELL_SUITE" test/run-tests.sh \
  '/^test_hypr_read_changes_nothing$/d'

printf '\nmutation probes: total=%d failed=%d\n' "$run" "$failed"
if (( skipped > 0 )); then
    printf 'THIS WAS A FILTERED RUN: %d probe(s) were skipped by PROBE_ONLY=%s.\n' \
           "$skipped" "$PROBE_ONLY"
    printf 'It proves nothing about those %d, and it is not a release run.\n' "$skipped"
fi
if (( run == 0 )); then
    printf 'and it ran NOTHING -- the filter matched no probe name at all.\n'
    exit 1
fi
(( failed == 0 ))
