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
trap 'rm -rf -- "$WORK"' EXIT

run=0; failed=0

fail() { failed=$((failed + 1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

# probe NAME SUITE FILE SED-EXPRESSION
probe() {
    local name="$1" suite="$2" file="$3" expr="$4"
    run=$((run + 1))
    local backup="$WORK/${file//\//_}"

    if [[ ! -f "$ROOT/$file" ]]; then
        fail "$name" "$file does not exist, so nothing was probed"
        return
    fi
    cp -- "$ROOT/$file" "$backup" || { fail "$name" "could not copy $file aside"; return; }

    sed -i -e "$expr" -- "$ROOT/$file"
    if cmp -s -- "$ROOT/$file" "$backup"; then
        # Restore anyway, so a later probe on the same file starts clean.
        cp -- "$backup" "$ROOT/$file"
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
        fail "$name" "the restore of $file did not take -- STOP and restore it by hand from $backup"
        return
    fi
    if ! "$suite" >/dev/null 2>&1; then
        fail "$name" "the suite did not recover after $file was restored"
    fi
}

SHELL_SUITE=./test/run-tests.sh
QML_SUITE=./test/run-qml-tests.sh
STRUCT_SUITE=./test/qml-structure.sh
SHAPE_SUITE=./test/runners-shape.sh
LUA_SUITE=./test/lua-syntax.sh

# A probe can only mean anything if the suite is green to begin with. Checked
# once per suite up front, by name, rather than inferred from the first probe.
for pair in "$SHELL_SUITE" "$QML_SUITE" "$STRUCT_SUITE" "$SHAPE_SUITE" "$LUA_SUITE"; do
    if ! "$pair" >/dev/null 2>&1; then
        printf 'FAIL baseline -- %s is already red before any mutation; nothing below can be trusted\n' "$pair"
        printf '\nmutation probes: total=0 failed=1\n'
        exit 1
    fi
done
echo "baseline: all five suites are green"

# --- the bin/ scripts -------------------------------------------------------

probe "config: the read size cap" "$SHELL_SUITE" bin/omarchy-autostart-config \
  's/^    if (( size > MAX_BYTES )); then/    if false; then/'

probe "config: the permission refusal" "$SHELL_SUITE" bin/omarchy-autostart-config \
  's/^    if (( 8#$mode & 8#22 )); then/    if false; then/'

probe "config: the staleness check" "$SHELL_SUITE" bin/omarchy-autostart-config \
  's/^    \[\[ "$current" == "$expect_mtime" \]\]/    [[ true ]]/'

probe "apps: the file count cap" "$SHELL_SUITE" bin/omarchy-autostart-apps \
  's/^            (( count >= MAX_FILES )) && break 2/            :/'

probe "windows: the window count cap" "$SHELL_SUITE" bin/omarchy-autostart-windows \
  's/^        | \.\[0:$max\]$/        | .[0:99999]/'

# --- the QML files, structurally -------------------------------------------

probe "runners: bash named by absolute path" "$STRUCT_SUITE" Runners.qml \
  's|"/usr/bin/bash"|"bash"|'

probe "runners: the producer's own exit status" "$SHAPE_SUITE" Runners.qml \
  's/s=${PIPESTATUS\[0\]}/s=$?/'

probe "barwidget: the glyph stays a \\u escape" "$STRUCT_SUITE" BarWidget.qml \
  's/"\\uf135"/""/'

# --- Model.js ---------------------------------------------------------------

probe "model: values reach Lua as bytes" "$QML_SUITE" Model.js \
  's/luaBytes(program\["class"\])/String(program["class"])/'

# DEVIATION FROM THE PLAN'S SKETCH: it mutated
#   if (placement.monitor !== undefined && placement.workspace !== undefined)
# which is not in Model.js and never was. The either-or rule is two separate
# guards, one per placement kind (Model.js:61 and :65) -- a single combined
# condition could not express it, because "workspace plus a monitor field" and
# "monitor plus a workspace field" are different inputs. A sed that matched
# nothing would have printed no probe at all.
probe "model: placement is either-or" "$QML_SUITE" Model.js \
  's/^        if (placement.monitor !== undefined) return "placement-invalid";$/        if (false) return "placement-invalid";/'

probe "model: the program cap" "$QML_SUITE" Model.js \
  's/^        if (out.programs.length >= MAX_PROGRAMS) {/        if (false) {/'

probe "model: the window address shape" "$QML_SUITE" Model.js \
  's|^        if (!ADDRESS_RE.test(hits\[i\].address)) {|        if (false) {|'

probe "model: an imported program stays switched off" "$QML_SUITE" Model.js \
  's/^            enabled: false,$/            enabled: true,/'

probe "model: the generated Lua compiles" "$LUA_SUITE" Model.js \
  's/^    "end"$/    "ende"/'

# --- the submission set -----------------------------------------------------

probe "manifest: a panel kind would move the plugin off the bar" "$SHELL_SUITE" manifest.json \
  's/"kinds": \["bar-widget", "service"\]/"kinds": ["bar-widget", "panel", "service"]/'

# An entry point whose kind is not declared. This is the direction NOTHING
# else caught: it is not `panel`, so the "no panel key" assertion passes; the
# kinds list is untouched, so the sorted-kinds assertion passes; and
# `omarchy plugin validate` only checks kind -> entryPoint, so the platform
# validator passes it too. Only the pair check refuses it.
probe "manifest: an entry point with no kind to load it" "$SHELL_SUITE" manifest.json \
  's|"barWidget": "BarWidget.qml",|"barWidget": "BarWidget.qml",\n    "overlay": "Panel.qml",|'

# The opposite direction: the kind gone while its entry point stays. This is
# the exact inconsistent pair that would ship a plugin whose autostart never
# runs, and it is what fix round 1 was raised about.
probe "manifest: a kind removed while its entry point stays" "$SHELL_SUITE" manifest.json \
  's/"kinds": \["bar-widget", "service"\]/"kinds": ["bar-widget"]/'

probe "readme: a privileged verb in prose" "$SHELL_SUITE" README.md \
  's/^## Tests$/## Tests\n\nIf a test fails, re-run it with sudo.\n/'

probe "uninstall: the configuration is the user's data" "$SHELL_SUITE" uninstall \
  's|^if \[\[ -d "$MARKER_DIR" \]\]; then|rm -f -- "$CONFIG"\nif [[ -d "$MARKER_DIR" ]]; then|'

probe "checklist: the preview obligation cannot just vanish" "$SHELL_SUITE" CHECKLIST.md \
  's/preview\.png/preview-image/g'

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
probe "guard: a test function that is defined but never invoked" "$SHELL_SUITE" test/run-tests.sh \
  '/^test_marker_release_removes_the_marker_file$/d'

printf '\nmutation probes: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
