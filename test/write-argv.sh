#!/usr/bin/env bash
# Binds the one property the autostart write has to hold about ITS COMMAND
# rather than about the writer: the new autostart.lua must never appear in an
# argv, because /proc/<pid>/cmdline is readable by every process on this
# machine and an autostart line is any command with any argument.
#
# THE DEFECT THIS EXISTS FOR, in the shape it shipped in v1.0.1: the panel
# built "printf '%s' <the whole file, shell-quoted> | omarchy-autostart-hypr-write
# write --expect-mtime N" and handed that string to `bash -c`. The writer did
# receive the content on stdin -- and the comment at the call site said so --
# but the SHELL one process earlier carried the entire file in its own argv.
# The exposure was one process upstream of everything the comment described.
#
# WHAT IS MEASURED HERE, and in this order:
#
#   1. the argv the panel's own SOURCE produces, evaluated in the real Qt6
#      engine by test/extract-write-argv.py -- not a hand-written copy of it,
#      which would stay green after the call site grew a shell back;
#   2. a real /proc/<pid>/cmdline, for the launched process and every
#      descendant it has while it runs. This is not an argument about what
#      argv means: the bytes are read out of /proc while the writer waits;
#   3. that the content nevertheless ARRIVES -- on stdin, in the file, through
#      the writer's own guards. A command carrying no content and a write that
#      silently writes nothing must not look the same.
#
# Nothing here touches ~/.config: the fixture lives in a sandbox under /tmp
# and XDG_CONFIG_HOME points at it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

run=0; failed=0
ok()  { run=$((run+1)); printf 'ok   %s\n' "$1"; }
bad() { run=$((run+1)); failed=$((failed+1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

finish() {
    printf '\nwrite argv: total=%d failed=%d\n' "$run" "$failed"
    (( failed == 0 ))
}

# The Qt6 runtime, resolved by RUNNING the candidate -- /usr/bin/qml on Arch is
# Qt 5.15 and cannot load this. Same resolution as test/run-qml-tests.sh, and
# the same refusal rather than a fallback.
QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" --version 2>&1 | grep -q "Qml Runtime 6"; then QML="$candidate"; break; fi
done
if [[ -z "$QML" ]]; then
    bad "write argv: a Qt6 qml runtime is available" \
        "no Qt6 qml runtime found; install qt6-declarative or point QT6_QML at it"
    finish; exit $?
fi

WORK="$(TMPDIR=/tmp mktemp -d)" || { echo "write argv: mktemp -d failed" >&2; exit 2; }
cleanup() { [[ -n "${WORK:-}" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT

SANDBOX="$WORK/sandbox"
HYPR_DIR="$SANDBOX/config/hypr"
mkdir -p "$HYPR_DIR" "$SANDBOX/home"

# The fixture, and the token the whole suite turns on. It is a real autostart
# line, because the writer's luac5.1 gate is not bypassed for a test.
TOKEN="argv-sentinel-$$-${RANDOM}-do-not-leak"
{
    printf '%s\n' '-- Autostart.'
    printf '%s\n' 'o.launch_on_start("notes-app")'
} > "$HYPR_DIR/autostart.lua"
chmod 644 "$HYPR_DIR/autostart.lua"
MTIME="$(stat -c %Y "$HYPR_DIR/autostart.lua")"
CONTENT="$(cat "$HYPR_DIR/autostart.lua"; printf '%s\n' "o.launch_on_start(\"$TOKEN\")")"

# --- 1: the argv the panel's own source builds ------------------------------
#
# Model.js goes into the work directory because the generated probe imports the
# REAL one: a quoting call spliced into the command expression must resolve to
# the function it names, not to a stub.
cp -- Model.js "$WORK/Model.js"
if ! python3 test/extract-write-argv.py "$CONTENT" "$MTIME" "$PWD/bin/" "$WORK/probe.qml"; then
    bad "write argv: the command expression could be extracted from the source" \
        "extraction failed (see stderr above) -- Panel.qml or Runners.qml no longer has a shape this can read"
    finish; exit $?
fi
ok "write argv: the command expression could be extracted from the source"

argv_json="$(cd "$WORK" && QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen \
    /usr/bin/timeout -k 5 60 "$QML" probe.qml 2>&1 \
    | sed -n 's/^.*ARGV_JSON://p' | tail -1)"
if [[ -z "$argv_json" ]] || ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$argv_json"; then
    bad "write argv: the source's own command expression evaluated to an argv list" \
        "the probe printed no usable ARGV_JSON: ${argv_json:-<nothing>}"
    finish; exit $?
fi
ok "write argv: the source's own command expression evaluated to an argv list"

mapfile -t ARGV < <(jq -r '.[]' <<<"$argv_json")

# Fail-closed: the argv has to be the real one before its contents mean
# anything. It must name the writer, and it must carry the freshness
# expectation -- an argv missing either would pass the "no content in it"
# assertion below by being empty of everything.
names_writer="no"
carries_mtime="no"
for element in "${ARGV[@]}"; do
    [[ "$element" == *omarchy-autostart-hypr-write ]] && names_writer="yes"
    [[ "$element" == "--expect-mtime" ]] && carries_mtime="yes"
done
[[ "$names_writer" == "yes" ]] \
    && ok "write argv: it names the writer script" \
    || bad "write argv: it names the writer script" "argv: $argv_json"
[[ "$carries_mtime" == "yes" ]] \
    && ok "write argv: it carries the freshness expectation" \
    || bad "write argv: it carries the freshness expectation" "argv: $argv_json"

# THE ASSERTION. Every element, not the joined string: a content spliced in as
# its own argument is the shape a well-meaning refactor would produce.
leaked=""
for element in "${ARGV[@]}"; do
    [[ "$element" == *"$TOKEN"* ]] && leaked="$leaked
$element"
done
[[ -z "$leaked" ]] \
    && ok "write argv: no element of it carries the new autostart.lua" \
    || bad "write argv: no element of it carries the new autostart.lua" "$leaked"

# And no element is an interpreter either: a shell here means a command string
# one process later, which is the defect by another route.
shell_element=""
for element in "${ARGV[@]}"; do
    case "${element##*/}" in
        bash|sh|dash|zsh|env) shell_element="$shell_element $element" ;;
    esac
done
[[ -z "$shell_element" ]] \
    && ok "write argv: and no element of it is a shell" \
    || bad "write argv: and no element of it is a shell" "$shell_element"

# --- 2: a real /proc/<pid>/cmdline ------------------------------------------
#
# The writer blocks on its stdin read, which is the window in which its whole
# process tree can be read out of /proc. Every descendant, not just the
# launched process: the exposure this suite exists for was in a CHILD of the
# process the panel started.
cmdlines_of_tree() {
    local pid="$1" child kid
    [[ -r "/proc/$pid/cmdline" ]] || return 0
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null; printf '\n'
    for child in /proc/"$pid"/task/*/children; do
        [[ -r "$child" ]] || continue
        for kid in $(cat "$child" 2>/dev/null); do
            cmdlines_of_tree "$kid"
        done
    done
}

mkfifo "$WORK/stdin" || { bad "write argv: the stdin fifo could be created" "mkfifo failed"; finish; exit $?; }
env -u WAYLAND_DISPLAY HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/config" \
    "${ARGV[@]}" < "$WORK/stdin" > "$WORK/envelope.json" 2> "$WORK/writer.err" &
writer_pid=$!
exec {feed}>"$WORK/stdin"

# The staged candidate appearing beside the fixture is the writer past its
# validation and parked on the read. Bounded, and a timeout is a failure: a
# measurement that never reached the window must not look like one that did.
staged=""
for (( i = 0; i < 500; i++ )); do
    staged="$(ls -A "$HYPR_DIR" | grep '^\.autostart' | head -1 || true)"
    [[ -n "$staged" ]] && break
    sleep 0.01
done
tree_cmdlines=""
if [[ -z "$staged" ]]; then
    bad "write argv: the writer was caught while it was running" \
        "the writer never staged anything, so /proc was never read at the right moment"
else
    ok "write argv: the writer was caught while it was running"
    tree_cmdlines="$(cmdlines_of_tree "$writer_pid")"
fi

printf '%s\n' "$CONTENT" >&"$feed"
exec {feed}>&-
wait "$writer_pid" 2>/dev/null
envelope="$(cat "$WORK/envelope.json" 2>/dev/null)"

# Fail-closed again: the /proc read has to have SEEN the writer, or "the token
# is not in it" is a statement about an empty string.
if grep -q 'omarchy-autostart-hypr-write' <<<"$tree_cmdlines"; then
    ok "write argv: /proc showed the writer's own command line"
else
    bad "write argv: /proc showed the writer's own command line" \
        "the collected command lines do not mention the writer at all:
$tree_cmdlines"
fi
if grep -qF -- "$TOKEN" <<<"$tree_cmdlines"; then
    bad "write argv: the file's content is in no /proc command line of the write" \
        "the token was readable in /proc:
$(grep -F -- "$TOKEN" <<<"$tree_cmdlines")"
else
    ok "write argv: the file's content is in no /proc command line of the write"
fi

# --- 3: and the content still arrives ---------------------------------------
[[ "$(jq -r .ok <<<"$envelope" 2>/dev/null)" == "true" ]] \
    && ok "write argv: the write succeeded" \
    || bad "write argv: the write succeeded" "envelope: ${envelope:-<nothing>}
stderr: $(cat "$WORK/writer.err" 2>/dev/null)"
[[ "$(cat "$HYPR_DIR/autostart.lua")" == "$CONTENT" ]] \
    && ok "write argv: and the published file is exactly the content that went in on stdin" \
    || bad "write argv: and the published file is exactly the content that went in on stdin" \
           "published:
$(cat "$HYPR_DIR/autostart.lua")"

finish
