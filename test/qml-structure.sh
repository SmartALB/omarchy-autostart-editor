#!/usr/bin/env bash
# Structural checks on the QML files.
#
# Runners.qml and its callers import Quickshell.Io, which does not exist
# outside the Quickshell runtime, so they cannot be executed headless. What
# CAN be held is the shape: absolute interpreters, every command through a
# helper, a producer limit on both collecting helpers, and a teardown that
# covers every declared Process. These are the five properties that closed the
# fourth review finding on smartalb.vpn v1.3.1.
#
# A grep is a text search, not a compiler: it cannot distinguish a comment
# from the code it describes, and by itself it cannot verify that the
# SPECIFIC dynamic value on a line was encoded rather than some other value
# nearby. A red-team pass against an earlier version of this script defeated
# five of ten checks with plausible source text: a comment claiming a
# property the code no longer had (checks 3, 4), a bare array whose "["
# was wrapped onto the following line (check 5), an id merely mentioned
# in a teardown comment rather than actually stopped (check 6), and check
# 7b's single-line window, which "luaBytes(key)" appearing twice already on
# a construction's opener line satisfies even after "luaBytes(placement.value)"
# -- the encoding of the one value that actually mattered -- was removed.
#
# Two fixes close the comment-based half of that class for good: every check
# below reads through strip_comments(), never the raw file, and checks 5/6
# require an actual statement (a helper call, an ".running = false" line)
# rather than a bare substring anywhere nearby. The per-value encoding
# question that check 7b cannot answer is not fixed by tightening the grep
# further -- no grep can verify that; see the comment on check 7b for where
# the real guarantee lives instead.
set -uo pipefail
cd "$(dirname "$0")/.."

run=0; failed=0
ok()   { run=$((run+1)); printf 'ok   %s\n' "$1"; }
bad()  { run=$((run+1)); failed=$((failed+1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

qml_files() { ls -1 ./*.qml 2>/dev/null; }

# Comment-stripped view of a file. A line comment alone is enough to satisfy
# a check that only asks whether a substring is present anywhere on a line
# ("// head -c 262144" reads back as a producer limit) -- every check in this
# file reads through this instead of the raw file, so no future check can be
# satisfied by a comment saying the right thing rather than code doing it.
# Line-oriented and naive on purpose (sed, not a tokenizer): it can be fooled
# by "//" inside a string or a regex literal, but the only place that occurs
# in this codebase today (the file:// strip in Runners.qml's binDir) is not
# examined by any check below, so it costs nothing here.
strip_comments() {
  sed 's|//.*||' "$1" 2>/dev/null
}

# Emits grep -nE style "file:line:content" across every qml file, but from
# the comment-stripped view of each -- grep's own multi-file mode cannot be
# reused here because the input is piped per file, not read from disk.
grep_stripped_all() {
  local pattern="$1" f h
  for f in $(qml_files); do
    h="$(strip_comments "$f" | grep -nE "$pattern")"
    [[ -n "$h" ]] && printf '%s\n' "$h" | sed "s#^#$f:#"
  done
}

# 1 -- no PATH-resolved interpreter anywhere, in either quote style QML
#      accepts (single or double).
interp_pat="[\"'](bash|sh|timeout|hyprctl|head|jq)[\"']"
hits="$(grep_stripped_all "$interp_pat" || true)"
[[ -z "$hits" ]] && ok "no PATH-resolved interpreter in any qml file" \
                 || bad "no PATH-resolved interpreter in any qml file" "$hits"

# 2 -- the three absolute binaries are the only ones named, in either quote
#      style.
stripped_runners="$(strip_comments Runners.qml)"
for expected in /usr/bin/timeout /usr/bin/bash /usr/bin/hyprctl; do
  bin_pat="[\"']${expected}[\"']"
  grep -qE "$bin_pat" <<<"$stripped_runners" \
    && ok "Runners.qml names $expected absolutely" \
    || bad "Runners.qml names $expected absolutely" "not found"
done

# 3 -- both collecting helpers carry a producer limit, in real code -- a
#      comment claiming one is stripped before this check ever sees it.
grep -A2 'function runnerOut' <<<"$stripped_runners" | grep -q 'head -c' \
  && ok "runnerOut carries a producer byte limit" \
  || bad "runnerOut carries a producer byte limit" "no head -c near runnerOut (in real code)"
grep -A2 'function runnerErr' <<<"$stripped_runners" | grep -q 'head -c' \
  && ok "runnerErr carries a producer byte limit" \
  || bad "runnerErr carries a producer byte limit" "no head -c near runnerErr (in real code)"

# 4 -- runnerErr uses process substitution, not a pipe: a pipe would replace
#      the exit status of the command, which callers read. Same
#      comment-stripped basis as check 3.
grep -A2 'function runnerErr' <<<"$stripped_runners" | grep -q '2> >(' \
  && ok "runnerErr keeps the command exit status (process substitution)" \
  || bad "runnerErr keeps the command exit status (process substitution)" "no '2> >(' found (in real code)"

# 4b -- neither collecting helper terminates its command group with "; }".
#       The autostart's command field is a shell command line by design
#       (Model.js: launchCommand) and may legitimately end in "&", ";", or a
#       trailing #comment -- after which "; }" is a syntax error and the
#       group silently never runs. Termination must be a newline instead,
#       the same fix launchCommand already uses.
if grep -A2 'function runnerOut' <<<"$stripped_runners" | grep -q '; }'; then
  bad "runnerOut does not close its group with the unsafe \"; }\" form" "found near runnerOut"
else
  ok "runnerOut does not close its group with the unsafe \"; }\" form"
fi
if grep -A2 'function runnerErr' <<<"$stripped_runners" | grep -q '; }'; then
  bad "runnerErr does not close its group with the unsafe \"; }\" form" "found near runnerErr"
else
  ok "runnerErr does not close its group with the unsafe \"; }\" form"
fi

# 5 -- every Process command: goes through a helper, never a bare array --
#      including one whose "[" is wrapped onto the line after "command:",
#      which a same-line-only check cannot see. Each "command:" line (after
#      comment-stripping) is joined with the line after it, and the joined
#      text must reference one of the helpers by name -- a bare array,
#      wrapped or not, has nothing there to match.
helper_pat='(^|[^A-Za-z0-9_.])(runner|runnerOut|runnerErr|hypr|tool)\('
hits=""
for f in $(qml_files); do
  mapfile -t lines < <(strip_comments "$f")
  n=${#lines[@]}
  for ((i = 0; i < n; i++)); do
    line="${lines[$i]}"
    [[ "$line" =~ ^[[:space:]]*command:(.*)$ ]] || continue
    rest="${BASH_REMATCH[1]}"
    nextline=""
    (( i + 1 < n )) && nextline="${lines[$((i + 1))]}"
    joined="$rest $nextline"
    if [[ ! "$joined" =~ $helper_pat ]]; then
      hits="$hits
$f:$((i + 1)): ${line}${nextline:+ / next: $nextline}"
    fi
  done
done
[[ -z "$hits" ]] && ok "every Process command goes through a helper" \
                 || bad "every Process command goes through a helper" "$hits"

# 6 -- teardown covers every declared Process with an actual statement, not
#      merely a mention -- a comment like "// also stop barProc" used to
#      satisfy a bare substring search. The id-detection logic (Process {
#      id: foo on one line, or id: split onto the next) is unchanged: it was
#      independently verified sound and is not where the hole was. A wall-
#      clock deadline would end these eventually, but "eventually" is up to
#      two minutes of work nobody is waiting for.
for file in $(qml_files); do
  clean="$(strip_comments "$file")"
  ids="$(awk '/^[[:space:]]*Process[[:space:]]*\{/ {inproc=1}
              inproc && /id:[[:space:]]*[A-Za-z_]/ {
                  match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
                  s = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
                  print s; inproc=0 }' <<<"$clean")"
  [[ -z "$ids" ]] && continue
  teardown="$(awk '/Component.onDestruction/,/^[[:space:]]*\}/' <<<"$clean")"
  for id in $ids; do
    stop_pat="\\b${id}\\.running[[:space:]]*=[[:space:]]*false\\b"
    grep -qE "$stop_pat" <<<"$teardown" \
      && ok "$file: teardown stops $id" \
      || bad "$file: teardown stops $id" "no '${id}.running = false' statement in Component.onDestruction"
  done
done

# 7a -- Lua rule construction lives in Model.js only. A qml file must not
#       build rules at all; it only passes strings through. (hl.dsp. may
#       appear there -- the panel sniffs it to choose the hyprctl verb.)
hits="$(grep_stripped_all 'hl\.(window_rule|workspace_rule)' || true)"
[[ -z "$hits" ]] && ok "no rule construction in any qml file" \
                 || bad "no rule construction in any qml file" "$hits"

# 7b -- cheap first line ONLY: every apparent rule-construction site in
#       Model.js at least mentions luaBytes somewhere in a small window
#       around it. This is NOT the guarantee that the SPECIFIC dynamic value
#       on that construction was encoded -- a grep cannot tell
#       "luaBytes(key)", already present twice on windowRuleStatement's
#       opener line, from "luaBytes(placement.value)" having been quietly
#       dropped elsewhere on the same statement. That happened in review and
#       this check did not catch it: it stayed green with placement.value
#       leaking un-encoded, because luaBytes( was still present for the
#       OTHER two fields on the line.
#
#       The real, per-value guarantee is a behavioural test in the real
#       engine: "chunks: no configured value appears literally in the
#       payload" and "reconcile: no configured value appears literally in
#       the payload" in test/harness.qml. Those build a chunk with
#       distinctive class/monitor/workspace/address values and assert none
#       of them survive as readable text -- something no grep over source
#       can ask. Trust those two, not this one, for the encoding property.
stripped_model="$(strip_comments Model.js)"
hits=""
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  lineno="${m%%:*}"
  window="$(sed -n "${lineno},$((lineno + 2))p" <<<"$stripped_model")"
  grep -q 'luaBytes(' <<<"$window" || hits="$hits
$m"
done < <(grep -nE 'hl\.(window_rule|workspace_rule|dsp\.[a-z_.]+)\(\{' <<<"$stripped_model" || true)
hits="$(sed '/^$/d' <<<"$hits")"
[[ -z "$hits" ]] && ok "every apparent rule-building site in Model.js at least mentions luaBytes (coarse; see harness.qml for the real per-value guarantee)" \
                 || bad "every apparent rule-building site in Model.js at least mentions luaBytes (coarse; see harness.qml for the real per-value guarantee)" "$hits"

printf '\nqml structure: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
