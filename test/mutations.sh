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

# RUN A SUBSET, DELIBERATELY AND VISIBLY. A full run is 138 probes at roughly a
# minute each, because every probe runs a whole suite twice; verifying the
# probes added by one task should not cost over two hours.
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
ARGV_SUITE=./test/write-argv.sh

# A probe can only mean anything if the suite is green to begin with. Checked
# once per suite up front, by name, rather than inferred from the first probe.
for pair in "$SHELL_SUITE" "$QML_SUITE" "$STRUCT_SUITE" "$SHAPE_SUITE" "$ARGV_SUITE"; do
    if ! "$pair" >/dev/null 2>&1; then
        printf 'FAIL baseline -- %s is already red before any mutation; nothing below can be trusted\n' "$pair"
        printf '\nmutation probes: total=0 failed=1\n'
        exit 1
    fi
done
echo "baseline: all five suites are green"

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

# --- the display name is one string ----------------------------------------
#
# It lives in four literals -- manifest.json's name, its displayName,
# BarWidget.qml's tooltip and Panel.qml's header -- and until the rename to
# "Autostart Editor" nothing bound any of them to any other. Each place is
# probed on its own, so a rename that reaches three of the four fails here
# rather than shipping a bar that names a design which no longer exists.

probe "name: the bar tooltip must carry the manifest's name" "$STRUCT_SUITE" BarWidget.qml \
  's|Autostart Editor|Autostart Somethingelse|g'

probe "name: the panel header must carry the manifest's name" "$STRUCT_SUITE" Panel.qml \
  's|text: "Autostart Editor"|text: "Autostart Somethingelse"|'

probe "name: the manifest's two names must agree with each other" "$STRUCT_SUITE" manifest.json \
  's|"displayName": "Autostart Editor"|"displayName": "Autostart Somethingelse"|'

probe "name: and the shell suite still pins the name itself" "$SHELL_SUITE" manifest.json \
  's|"name": "Autostart Editor"|"name": "Autostart Somethingelse"|'

# --- the version in the panel footer ---------------------------------------
#
# The footer exists so a user testing two machines can tell which build is in
# front of them, which makes a stale number worse than no number. Model.VERSION
# and manifest.json's `version` are two copies of one fact, so each side is
# bumped on its own here -- the equality must refuse either -- and a version
# literal is planted in Panel.qml, which must refuse a second source of truth.

# NEITHER OF THESE TWO NAMES THE CURRENT VERSION, and that is the whole point
# of the shape. They used to read `"1.0.0"` -> `"1.0.1"`, and the 1.0.1 bump
# turned both into patterns that matched nothing: the mutation changed the file
# not at all, the suite stayed green for want of anything broken, and only the
# "the mutation changed nothing" guard said so. A probe that has to be re-aimed
# at every release is a probe that is silently dead between releases.
#
# So each one CAPTURES whatever version is there and replaces it with a
# sentinel that no release can ever be. It proves exactly what the literal
# form proved -- one side moved on its own must make the equality red -- and it
# cannot go stale. If the sentinel ever WERE the real version the file would
# come back unchanged and the same guard would fail by name, so this is not a
# way to stop noticing.
probe "version: Model.VERSION bumped alone must be refused" "$SHELL_SUITE" Model.js \
  's|^\(var VERSION *= *"\)[^"]*\(";\)$|\1999.999.999\2|'

probe "version: the manifest bumped alone must be refused" "$SHELL_SUITE" manifest.json \
  's|\("version": "\)[^"]*\("\)|\1999.999.999\2|'

probe "version: a version literal in Panel.qml is a second source of truth" "$STRUCT_SUITE" Panel.qml \
  's|text: Model.versionText()|text: "1.0.0"|'

probe "version: the footer must reach the version through Model" "$SHELL_SUITE" Panel.qml \
  's|text: Model.versionText()|text: "1.0.0"|'

probe "version: the v prefix is what makes it read as a version" "$QML_SUITE" Model.js \
  's|return v === "" ? "" : "v" + v;|return v;|'

probe "version: an empty version must not render as a bare v" "$QML_SUITE" Model.js \
  's|return v === "" ? "" : "v" + v;|return "v" + v;|'

probe "readme: a privileged verb in prose" "$SHELL_SUITE" README.md \
  's/^## Tests$/## Tests\n\nIf a test fails, re-run it with sudo.\n/'

# THE PROPERTY TURNED AROUND. There is no configuration of this plugin's own
# left to keep -- the JSON file went with the removed half -- so what uninstall
# must now be held to is that it removes the plugin AND TOUCHES NOTHING ELSE.
# The one file this plugin ever wrote is the user's own autostart.lua, and this
# probe makes uninstall delete it.
probe "uninstall: the user's own autostart.lua is not removed with the plugin" "$SHELL_SUITE" uninstall \
  's|^cat <<NOTE$|rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/autostart.lua"\ncat <<NOTE|'

# THE SUBJECT OF THIS PROBE MOVED WHEN THE SCREENSHOT WAS TAKEN, so the probe
# moved with it rather than being weakened to keep passing.
#
# The assertion is "the screenshot is either taken or still owed in writing",
# and it passes in BOTH states by design. What it refuses is the third state:
# gone from disk AND gone from the checklist. While preview.png did not exist,
# stripping the obligation out of CHECKLIST.md reached that third state and the
# suite went red, which is what this probe used to do.
#
# preview.png now exists, so the assertion answers through the file-present
# branch and never reads CHECKLIST.md at all -- the obligation's disappearance
# is invisible, and the old probe reported "the suite stayed green" honestly.
# The property was not lost; it is simply not the branch that is live.
#
# So this forks on the state, the same way the README coupling below already
# does and for the same reason: a single fixed expression stops proving
# anything the moment the file lands. With the file present, the live half of
# the assertion is "PRESENT BUT NOT A PNG -- a placeholder is not a
# screenshot", and that is what gets probed, by breaking the magic bytes the
# assertion actually reads. With the file absent, the checklist obligation is
# load-bearing again and the original probe applies.
if [[ -f preview.png ]]; then
    # The first eight bytes are what the assertion checks, so the mutation
    # lands there: 89 50 4e 47 -> 89 42 41 44. Measured -- same file size, and
    # the restore comes back byte-identical under the `cmp` above.
    probe "preview: a file that is not a real PNG is not a screenshot" "$SHELL_SUITE" preview.png \
      '1s/^\x89PNG/\x89BAD/'
else
    probe "checklist: the preview obligation cannot just vanish" "$SHELL_SUITE" CHECKLIST.md \
      's/preview\.png/preview-image/g'
fi

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
      's|^## What it is$|![The Autostart Editor panel](preview.png)\n\n## What it is|'
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
  's|"\$HEAD" -c "\$MAX_BYTES_PER_FILE" "\$dst"|"$HEAD" -c $((MAX_BYTES_PER_FILE + 1)) "$dst"|'

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

# THE NON-EDITABLE ENTRY, which in the fixture is the nested webapp line.
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

# --- what the listing shows -------------------------------------------------
#
# The line number is gone from the display and stays in the data, so both
# halves are probed: putting a number back in front must turn the listing
# assertions red, and the two markers that DO carry information must not be
# droppable in silence.

probe "listing: no line number in front of an entry" "$QML_SUITE" Model.js \
  's|    if (e.kind === "autostart") {|    if (e.kind === "autostart") { return String(e.line) + ": " + String(e.command);|'

probe "listing: the (shell) marker must survive" "$QML_SUITE" Model.js \
  's|(e.launcher === "uwsm-app" ? "" : "  (shell)")|""|'

probe "listing: a non-editable entry must still show its raw line" "$QML_SUITE" Model.js \
  's|^    if (!e.editable) return String(e.raw === undefined ? "" : e.raw);$|    if (!e.editable) return "";|'

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
# THE BACKUP ITSELF. The variable it copies to is now a dated name computed
# per write, so the old pattern -- cp -p -- "$TARGET" "$BACKUP" -- matches
# nothing and this probe reported "the mutation changed nothing" the moment the
# dating landed.
# The destination moved again: the backup is copied to a STAGED name and
# renamed onto its final one, so that a link left at the final name cannot be
# written through (see the symlink probes below). The pattern follows.
probe "writer: the backup is taken before the replacement" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|"$CP" -p -- "$TARGET_FD_PATH" "$BACKUPTMP"|true|'

# --- THE FILE THE WRITER VALIDATED, HELD OPEN -------------------------------
#
# The second half of the reviewer's finding against v1.0.1: the target was
# validated by NAME, and the name was then resolved twice more -- for the
# backup and for the rename -- with nothing holding the file that had been
# checked. Each of the three pieces of the fix gets its own probe, and the
# first of them is the whole fix reverted: with the /proc path replaced by the
# name, every later read resolves the name again, which is exactly the code
# the finding was written about.
probe "writer: the descriptor must be what is read, not the name again" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|TARGET_FD_PATH="/proc/self/fd/$TARGETFD"|TARGET_FD_PATH="$TARGET"|'

probe "writer: the backup must come from the descriptor, not from the name" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|"$CP" -p -- "$TARGET_FD_PATH" "$BACKUPTMP"|"$CP" -p -- "$TARGET" "$BACKUPTMP"|'

# The two halves of the re-check before the rename, one probe each. The inode
# half is the one an mtime comparison cannot hold: `touch -d` gives a
# different file the same timestamp.
probe "writer: a different file at the name must be noticed (the inode)" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|\[\[ "$now_inode" == "$target_inode"|[[ "$now_inode" == "$now_inode"|'

probe "writer: the same file written to must be noticed (the mtime)" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|"$now_mtime" == "$target_mtime_ns" \]\]|"$now_mtime" == "$now_mtime" ]]|'

# --- the dated backups, and the pruning that deletes in the user's directory -
#
# The naming is trivial; the pruning is not. It removes files from
# ~/.config/hypr, so each condition that decides WHICH files gets its own
# probe -- an absence guard nobody has watched refuse anything is a guard
# nobody knows works, which is what the install probes taught earlier in this
# task.

# THE ANCHORS ARE THE WHOLE GUARD. Without them the pattern MATCHES INSIDE a
# longer name, so "x.autostart.lua.smartalb-autostart.<stamp>.bak" and ours
# with ".save" appended both become removable.
probe "backups: the name pattern must be anchored at both ends" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^BACKUP_RE="\^autostart|BACKUP_RE="autostart|; s|(-\[0-9\]+)?\\\.bak\\\$"$|(-[0-9]+)?\\.bak"|'

probe "backups: a symlink named like ours must not be removed" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    \[\[ ! -h "$path" \]\] \|\| return 1$|    [[ 1 -eq 1 ]] \|\| return 1|'

# NOT ONLY A DIRECTORY. `rm -f` refuses a directory on its own, so relaxing
# this guard to `-e` changes nothing for one and the probe reported green. What
# `-f` actually buys is everything else that is not a plain file: a FIFO named
# like one of ours IS removed by `rm -f`, and the refusal fixture carries one,
# which is what makes this guard observable at all.
probe "backups: anything that is not a plain file must not be removed" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    \[\[ -f "$path" \]\] \|\| return 1$|    [[ -e "$path" ]] \|\| return 1|'

probe "backups: every removal must go through the name check" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    is_our_backup "$name" \|\| return 1$|    is_our_backup "$name" \|\| true|'

probe "backups: the count must actually be capped" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    (( ${#names\[@\]} > MAX_BACKUPS )) \|\| return 0$|    return 0|'

# Keeping the OLDEST would satisfy a bare count, which is why the cap test
# asserts which five survive rather than how many.
probe "backups: the ones kept must be the newest" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@ | "$SORT" -r)@ | "$SORT")@'

# A name that does not carry the date is a name the next write overwrites,
# which is the single-backup behaviour this change removed.
probe "backups: the name must carry the date" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|base="autostart.lua.$author.$stamp.bak"|base="autostart.lua.$author.fixed.bak"|'

# A second write inside the same second must not silently replace the backup
# the first one took.
# The freeness test moved into name_is_free, so this disarms it there -- and
# it now disarms it for BOTH candidate shapes at once, the bare stamp and the
# "-<n>" collision suffix, which is what it always meant to do.
probe "backups: a same-second collision must not overwrite a saved state" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@if name_is_free "$base"; then printf@if true; then printf@'

# AND A BACKUP THAT COULD NOT BE TAKEN MUST STILL ABORT THE WRITE.
#
# BOTH refusals at once, and that is not laziness. The two branches are
# redundant on purpose -- a name that cannot be found free leaves backup_base
# empty, and the `cp` to "$HYPR_DIR/" then fails and refuses too -- so
# disarming either ONE leaves the guarantee standing and the probe reported
# green. Measured, both ways round. A probe that can only be red by disarming
# the whole guarantee is the honest shape for a guarantee held twice over.
probe "backups: a failed backup must still abort the write" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@|| err "write-failed" "could not find a free backup name in $HYPR_DIR; nothing was written"@|| backup_base="x"@
   s@|| err "write-failed" "could not back $TARGET up to $backup_path; nothing was written"@|| true@'

# THE SEAM THAT MAKES THE ABORT TESTABLE MUST NOT WIDEN ANYTHING. It is
# validated by the same pattern the clock's own output passes; without that
# check it would be a way to name a backup outside our own pattern.
probe "backups: the stamp seam must accept nothing but a timestamp" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@    \[\[ "$stamp" =~ \^\[0-9\]{8}-\[0-9\]{6}\$ \]\] || return 1@    [[ -n "$stamp" ]] || return 1@'

# --- a symlink pre-positioned at the backup name ----------------------------
#
# The hole a marketplace reviewer reported against c2236c3, and the reason
# these probes are here rather than the assertions being trusted on sight: the
# guard that was missing is one this file already holds in three other places,
# so an assertion that never watched it fail is worth nothing here.

# `-e` FOLLOWS a symlink, so a DANGLING one at a candidate name reports "does
# not exist" and the name reads as free. This is the exact line of the report.
probe "backups: a symlink at a candidate name is not a free name" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@    \[\[ ! -e "$path" && ! -L "$path" \]\]@    [[ ! -e "$path" ]]@'

# AND THE WRITE ITSELF MUST NOT BE ABLE TO FOLLOW ONE. This reverts the backup
# to the shape the report describes -- a `cp` straight to the final name --
# which is what a link appearing between the check and the copy would then be
# written through.
probe "backups: the backup must not be copied straight to its final name" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@    "$MV" -T -f -- "$BACKUPTMP" "$backup_path" \\@    "$CP" -p -- "$TARGET" "$backup_path" \\@'

# -T IS NOT DECORATION. Measured: `mv` onto a symlink pointing at a DIRECTORY
# moves the file INSIDE that directory and leaves the link standing;
# `mv -T` replaces the link. The publish gets the same treatment as the backup.
probe "writer: the publish cannot be diverted into a directory" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@"$MV" --exchange -T -- "$STAGEFILE" "$TARGET"@"$MV" --exchange -- "$STAGEFILE" "$TARGET"@'

# The staged backup is a dotfile beside the user's Hyprland configuration, and
# a write that fails between the copy and the rename must not leave it there.
probe "backups: the staged backup is removed on the way out" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@    \[\[ -n "${BACKUPTMP:-}" \]\] && "$RM" -f -- "$BACKUPTMP"@    :@'

# BOTH GUARDS AT ONCE, and that is the honest shape here rather than laziness
# -- the same reasoning as "a failed backup must still abort the write" above.
#
# A link pointing at an EXISTING file is refused by the name check on `-e`
# alone, so no single-guard mutation can reach the copy with one at the
# destination; and the `mv -T` write cannot be observed being followed while
# the name check is standing. The assertion that the LINK'S TARGET IS UNTOUCHED
# is therefore only red when the whole guarantee is disarmed, which is exactly
# what this does: the name check waved through, and the backup copied straight
# to the name it chose. Measured -- with either one alone the suite stays green.
probe "backups: a link at the backup name must never reach the user's own file" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@if name_is_free "$base"; then printf@if true; then printf@
   s@    mv -T -f -- "$BACKUPTMP" "$backup_path" \\@    cp -p -- "$TARGET" "$backup_path" \\@'

probe "writer: a symlink is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    \[\[ ! -h "$TARGET" \]\] \|\| err "is-a-symlink"|    [[ 1 -eq 1 ]] \|\| err "is-a-symlink"|'

probe "writer: a group-writable file is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    if (( 8#$mode \& 8#22 )); then$|    if (( 8#$mode \& 8#00 )); then|'

probe "writer: an absent file is not written into existence" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^    \[\[ -e "$TARGET" \]\] \|\| err "not-a-file" "$TARGET does not exist"$|    [[ -e "$TARGET" ]] \|\| /usr/bin/touch "$TARGET"|'

probe "writer: a candidate past the cap is refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^        err "too-large" "the candidate exceeds $MAX_BYTES bytes"$|        true|'

probe "writer: the replacement is staged beside the destination" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|"$MKTEMP" "$HYPR_DIR/.autostart.lua.XXXXXX"|"$MKTEMP"|'

# The reference moved to the held descriptor with the fix for the check-then-use
# finding, so the pattern follows it: the staged file must get the mode of the
# file that was VALIDATED, and a probe whose pattern no longer matches proves
# nothing -- which is exactly how the full gate caught this one.
probe "writer: the staged file gets the original's permissions" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|"$CHMOD" --reference="$TARGET_FD_PATH" "$STAGEFILE"|true|'

# --- the panel's one route to the file --------------------------------------
# The substituted name is a script that does not exist, which is the point:
# any second route to disk is a route the writer's own guards -- the freshness
# check, the backup, the luac gate -- do not stand in front of.
probe "panel: the write goes through the writer script, not a second route" "$STRUCT_SUITE" Panel.qml \
  's|omarchy-autostart-hypr-write|omarchy-autostart-somewhere-else|'

# --- THE CONTENT MUST NOT ENTER AN ARGV -------------------------------------
#
# THE PROBE THAT STOOD HERE WAS THE RIGHT ANSWER TO THE WRONG QUESTION. It
# required the content to be shell-QUOTED into the command string
# (Model.shellQuote(result.text)), and it was green for three rounds while the
# producing shell carried the whole of the user's autostart.lua in its own
# /proc/<pid>/cmdline. Quoting was never the property; the content being in a
# command at all was.
#
# Both directions are probed: the structural check on Panel.qml, and the
# behavioural suite that evaluates the panel's own command expression and then
# reads a real /proc/<pid>/cmdline.
probe "panel: the content must not be appended to the argv" "$STRUCT_SUITE" Panel.qml \
  's|String(Number(section.mtime))\]|String(Number(section.mtime)), result.text]|'

probe "argv: a content argument is readable in /proc" "$ARGV_SUITE" Panel.qml \
  's|String(Number(section.mtime))\]|String(Number(section.mtime)), result.text]|'

# AND THE SHAPE v1.0.1 ACTUALLY SHIPPED, put back verbatim: run.runnerOut with
# the content shell-quoted into the command string. `|| run.toolArgv(` leaves
# the two following lines parsing as before while the string route is what the
# expression evaluates to, so this is a one-line revert of the fix rather than
# an invented defect. Measured against this probe: the reconstructed argv
# carries the whole file in a `bash -c` element, and the same content was read
# out of a live /proc/<pid>/cmdline by hand (15 of 93 sampled command lines
# held it) -- which is why the assertion is on the argv the source builds and
# not only on the /proc window, since the old shape does not park on stdin and
# a /proc read of a process that lives two milliseconds is a race, not a test.
probe "argv: the v1.0.1 shell-string route cannot come back" "$ARGV_SUITE" Panel.qml \
  's@autostartWriteProc.command = run.toolArgv(@autostartWriteProc.command = run.runnerOut("printf %s " + Model.shellQuote(result.text) + " | " + Model.shellQuote(run.binDir + "omarchy-autostart-hypr-write") + " write --expect-mtime " + Number(section.mtime)) || run.toolArgv(@'

# The other half of the same fix: a command carrying no content is only correct
# if the content goes in on stdin. Each of the three statements that make that
# work is probed on its own -- an open stdin, the write, and the close without
# which the writer waits forever for an end of stream that never comes.
probe "panel: stdin must be open on the writer Process" "$STRUCT_SUITE" Panel.qml \
  's|stdinEnabled: true|stdinEnabled: false|'

probe "panel: the content must actually be written to stdin" "$STRUCT_SUITE" Panel.qml \
  's|autostartWriteProc.write(autostartWriteProc.pendingContent)|true|'

probe "panel: stdin must be closed, or the candidate has no end" "$STRUCT_SUITE" Panel.qml \
  's|autostartWriteProc.stdinEnabled = false|autostartWriteProc.pendingContent = ""|'

# And the argv helper must carry the arguments it was given: an argv that
# names the writer and nothing else is a write with no freshness expectation.
probe "runners: the argv must carry the tool's own arguments" "$ARGV_SUITE" Runners.qml \
  's|.concat(args \|\| \[\])|.concat([])|'

# 5c ITSELF, handed the input it was written for. An assignment to a Process
# command was outside both older checks -- they scan for "command:" with the
# colon -- and the one route that writes the user's autostart.lua is an
# assignment. Probed on a DIFFERENT call site than the write, so what goes red
# is 5c and not one of the checks specific to the writer.
probe "panel: a hand-built argv in a command assignment is refused" "$STRUCT_SUITE" Panel.qml \
  's|windowsProc.command = run.tool("omarchy-autostart-windows")|windowsProc.command = ["/usr/bin/true"]|'

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
# The ranking probe is the one that matters most: without it the webmail
# window offered Music (Web) first, and the suite said nothing.

# --- the running-programs picker is off, and off means unreachable ---------
#
# Hidden, not removed, so the probes over the ranking and the warnings below
# stay. What these three add is the gate: the flag off, read once, and the
# route closed before it reads anything.

probe "running programs: the flag must actually be off" "$STRUCT_SUITE" Model.js \
  's|^var RUNNING_PROGRAMS_ENABLED = false;$|var RUNNING_PROGRAMS_ENABLED = true;|'

probe "running programs: the panel must have one switch, not two" "$STRUCT_SUITE" Panel.qml \
  's|^    readonly property bool offersRunningPrograms: Model.RUNNING_PROGRAMS_ENABLED$|    readonly property bool offersRunningPrograms: Model.RUNNING_PROGRAMS_ENABLED \&\& Model.RUNNING_PROGRAMS_ENABLED|'

# THE ONE THAT MATTERS: with the guard gone the button is still hidden, so the
# feature still LOOKS off -- and every press would spawn a process.
probe "running programs: the route must refuse, not just the button hide" "$STRUCT_SUITE" Panel.qml \
  's|^        if (!root.offersRunningPrograms) return$|        if (false) return|'

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
  '/"$TR" /s|[\]t||'

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

# --- THE OPEN, AND THE OBJECT IT LANDED ON (finding 1) ----------------------
#
# Each of these breaks exactly one of the checks validate_descriptor makes.
# The identity comparison is the one no end-to-end test can reach, so its
# probe is what stands behind the lifted-function assertions.

probe "descriptor: the object opened must be the object the name named" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|\[\[ "$ident" == "$path_ident" \]\]|[[ -n "$ident" ]]|'

probe "descriptor: the whole validation cannot be skipped" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@^    validate_descriptor "$path_ident" "$TARGET_FD_PATH"@    [[ -f "$TARGET_FD_PATH" ]] || err "not-a-file" "x"@'

probe "descriptor: the mode must be asked of the descriptor" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|(( 8#$mode \& 8#22 ))|(( 0 ))|'

probe "descriptor: a second hard link must be refused" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|\[\[ "$links" == "1" \]\]|[[ -n "$links" ]]|'

probe "descriptor: the owner comparison must be against our own euid" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|\[\[ "$uid" == "$EUID" \]\]|[[ -n "$uid" ]]|'

# The identity of the NAME is taken with lstat on purpose: with -L it would
# resolve the link and then agree with the descriptor about a file the name
# does not refer to, which is the comparison quietly answering "yes" always.
probe "descriptor: the name's identity must not be dereferenced" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|path_ident="$("$STAT" -c .%d:%i. -- "$TARGET" 2>/dev/null)"|path_ident="$("$STAT" -L -c "%d:%i" -- "$TARGET" 2>/dev/null)"|'

# --- A VERSION THAT APPEARS AFTER THE VALIDATION (finding 2) ----------------

# The exchange is what makes the replaced object inspectable at all. Reverted
# to the one-way rename this fix replaced, the intervening version becomes
# unreachable again -- which is the finding.
probe "publish: a one-way rename cannot preserve what it replaced" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@&& "$MV" --exchange -T -- "$STAGEFILE" "$TARGET" 2>/dev/null; then@\&\& "$MV" -T -f -- "$STAGEFILE" "$TARGET" 2>/dev/null; then@'

probe "publish: what was replaced must be looked at" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^        publish_check_replaced "$replaced" "$target_inode" "$target_mtime_ns"|        :|'

# WHOLE SECONDS ARE TOO COARSE TO IDENTIFY WHAT WAS REPLACED, and the unit is
# therefore part of the property rather than an implementation detail. Measured:
# two writes to one file inside the same second report the same %Y and a
# different %.9Y, so in seconds a rewrite IN PLACE reads as "the file we
# validated" and is deleted as redundant. This probe puts the coarse unit back.
probe "publish: the replaced file is identified at sub-second precision" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@got="$(LC_ALL=C "$STAT" -c .%i %.9Y. -- "$replaced" 2>/dev/null)"@got="$(LC_ALL=C "$STAT" -c "%i %Y" -- "$replaced" 2>/dev/null)"@'

# And the same unit in the re-check one step earlier.
probe "publish: the pre-publish re-check is sub-second too" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@now_fields="$(LC_ALL=C "$STAT" -c .%i %.9Y. -- "$TARGET" 2>/dev/null)"@now_fields="$(LC_ALL=C "$STAT" -c "%i %Y" -- "$TARGET" 2>/dev/null)"@'

# The window marker is what makes the three window tests deterministic. Without
# it they fall back to guessing, which is the flake that found the coarse-unit
# defect in the first place -- so the marker's own absence must be loud.
probe "publish: the delay seam announces that it entered the window" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@    : > "$HYPR_DIR/$DELAY_MARKER" 2>/dev/null || true@    :@'

# The whole point: an intervening version is KEPT, not deleted. This is the
# defect the old code had, written back in one line.
probe "publish: an intervening version must never be deleted" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@       \&\& "$MV" -T -- "$replaced" "$HYPR_DIR/$base"; then@       \&\& "$RM" -f -- "$replaced"; then@'

# And it must be distinguished from the validated file by BOTH numbers: with
# the mtime dropped, a replacement that happened to land on the same inode
# number reads as "the file we validated" and is deleted as redundant.
probe "publish: the replaced file is identified by inode AND mtime" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|if \[\[ "$got" == "$want_inode $want_mtime" \]\]; then|if [[ "${got%% *}" == "$want_inode" ]]; then|'

# A rescued file filed under our own backup author would be prunable, and
# MAX_BACKUPS could then delete the only copy of a state nobody saved.
probe "publish: a rescued file must not be filed among our backups" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^RESCUE_AUTHOR="smartalb-autostart-rescued"|RESCUE_AUTHOR="smartalb-autostart"|'

# The answer has to CARRY the rescue, or nothing tells the user.
probe "publish: the answer must name what was preserved" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|--arg r "$RESCUED_PATH"|--arg r ""|'

# The delay seam must stay a delay. A value that is not a single digit is
# ignored rather than passed on, and dropping that check is what would turn a
# test seam into an argument-injection point.
probe "publish: the delay seam validates its own value" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|\[\[ "$PUBLISH_DELAY" =~ \^\[0-9\]\$ \]\] \|\| return 0|:|'

# A SYSTEM THAT CANNOT EXCHANGE MUST BE REFUSED, NOT DOWNGRADED. This is the
# one-way rename put back -- the exact code that was tried and taken out --
# and it is the shape the second finding is about.
probe "publish: an unavailable exchange must refuse, not fall back to a plain rename" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@        err "no-atomic-exchange" \\@        "$MV" -T -f -- "$STAGEFILE" "$TARGET" || err "write-failed" "x"; STAGEFILE=""; publish_mode="rename"; : \\@'

# And the seam that reaches that branch has to actually reach it.
probe "publish: the no-exchange seam is honoured" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's@    if \[\[ "$NO_EXCHANGE" != "1" \]\] \\@    if [[ "$NO_EXCHANGE" != "0" ]] \\@'

# --- THE EXECUTION BOUNDARY (finding 3) -------------------------------------

# A bare tool name at a command position. With PATH emptied this fails at
# runtime as well as failing the class-level assertion -- which is exactly the
# pair of consequences the empty PATH was chosen for.
probe "boundary: a tool resolved by bare name" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|current="$("$STAT" -L -c %Y "$TARGET_FD_PATH" 2>/dev/null)"|current="$(stat -L -c %Y "$TARGET_FD_PATH" 2>/dev/null)"|'

probe "boundary: a bare tool name in the reader too" "$SHELL_SUITE" bin/omarchy-autostart-hypr \
  's|size="$("$WC" -c < "$dst")"|size="$(wc -c < "$dst")"|'

probe "boundary: a bare tool name in the apps picker" "$SHELL_SUITE" bin/omarchy-autostart-apps \
  's|} \| "$JQ" -R -s|} \| jq -R -s|'

probe "boundary: a bare tool name in the window list" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  's|\| "$TR" .\\0\\n\\t\\r. .    .|\| tr "\\0\\n\\t\\r" "    "|'

# The interpreter itself is a PATH lookup when it is spelled with env.
probe "boundary: the interpreter named through env, not absolutely" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  '1s|^#!/bin/bash$|#!/usr/bin/env bash|'

probe "boundary: a minimal PATH instead of none" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^PATH=$|PATH=/usr/bin:/bin|'

probe "boundary: a tool declared by a relative name" "$SHELL_SUITE" bin/omarchy-autostart-hypr-write \
  's|^readonly STAT=/usr/bin/stat$|readonly STAT=stat|'

# The two halves at the process boundary. Neither is sufficient alone, so each
# is probed on its own.
probe "boundary: a Process that inherits the environment" "$STRUCT_SUITE" Panel.qml \
  's|^        clearEnvironment: true$|        clearEnvironment: false|'

probe "boundary: a Process given no vetted environment" "$STRUCT_SUITE" Panel.qml \
  's|^        environment: run.toolEnv$|        environment: ({})|'

# BASH_ENV back on the allowlist is the finding itself, in one word.
probe "boundary: BASH_ENV back on the allowlist" "$STRUCT_SUITE" Runners.qml \
  's|readonly property var toolEnvPass: \["HOME"|readonly property var toolEnvPass: ["BASH_ENV", "HOME"|'

# So is the seam that names a binary the window script executes.
probe "boundary: the hyprctl seam back on the allowlist" "$STRUCT_SUITE" Runners.qml \
  's|readonly property var toolEnvPass: \["HOME"|readonly property var toolEnvPass: ["HYPRCTL", "HOME"|'

probe "boundary: an inherited PATH instead of a fixed one" "$STRUCT_SUITE" Runners.qml \
  's|readonly property string toolPath: "/usr/bin:/bin"|readonly property string toolPath: ""|'

probe "boundary: the producer limit's own tool resolved by name" "$STRUCT_SUITE" Runners.qml \
  's|readonly property string binHead: "/usr/bin/head"|readonly property string binHead: "head"|'

# --- THE SENTENCE THAT TELLS THE USER ---------------------------------------
#
# A preserved file nobody is told about is a file nobody looks at, so the
# wording is part of the fix rather than decoration on it.
probe "rescue wording: a preserved file that is never mentioned" "$QML_SUITE" Model.js \
  's|^    if (p === "") return "";|    if (p !== "") return ""; return "";|'

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
