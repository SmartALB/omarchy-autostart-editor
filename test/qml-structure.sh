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
#
# A second red-team pass found three more evasions and two silent-failure
# modes in that same round of fixes: check 4b's literal "; }" search missed
# a semicolon set directly against the brace ("&& ;}"); check 5 required a
# helper name to appear ANYWHERE in the joined text, so a bare array with a
# helper name buried in a decoy string argument (e.g. a notify-send message
# that happens to say "tool(...)") passed; and check 6 went silent, not red,
# when an id could not be extracted at all (a split "id:\n    fooProc"),
# because the whole Process block was then skipped rather than flagged.
# strip_comments() itself was also fragile: a blunt "//.*" truncation
# corrupts the "//" inside Runners.qml's `/^file:\/\//` regex literal, so it
# is now a quote- and escape-aware scan (test/strip-comments.awk) instead.
# Check 4b now tolerates whitespace before the brace; check 5 anchors the
# helper call to the START of what follows "command:" (falling through to
# the next line only when nothing follows on the same one) while keeping the
# original same-line bare-array check alongside it, on the theory that two
# cheap checks that can disagree are easier to diagnose than one clever one;
# check 6 fails loudly, once per file, when a Process block is found but
# fewer ids could be extracted from it than Process blocks exist.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

run=0; failed=0
ok()   { run=$((run+1)); printf 'ok   %s\n' "$1"; }
bad()  { run=$((run+1)); failed=$((failed+1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

qml_files() { ls -1 ./*.qml 2>/dev/null; }

# Comment-stripped view of a file. A line comment alone is enough to satisfy
# a check that only asks whether a substring is present anywhere on a line
# ("// head -c 262144" reads back as a producer limit) -- every check in this
# file reads through this instead of the raw file, so no future check can be
# satisfied by a comment saying the right thing rather than code doing it.
#
# A blunt "sed 's|//.*||'" truncation corrupts a "//" that legitimately
# occurs outside a comment -- inside a string ("https://example.com"), or
# inside a regex literal built from escaped slashes, as in Runners.qml's own
# `/^file:\/\//`. test/strip-comments.awk tracks quote state and treats a
# backslash-prefixed character as one atomic unit (never available to pair
# into a "//") both inside and outside a string, so only a genuine,
# unescaped, unquoted "//" starts a comment.
strip_comments() {
  awk -f "$SCRIPT_DIR/strip-comments.awk" "$1" 2>/dev/null
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

# 4b -- neither collecting helper terminates its command group with a
#       semicolon directly against the closing brace, in any spacing --
#       "; }", ";}", ";  }" and so on. The autostart's command field is a
#       shell command line by design (Model.js: launchCommand) and may
#       legitimately end in "&", ";", or a trailing #comment, and
#       `bash -n` confirms "{ foo & ;}" fails the same way "{ foo & ; }"
#       does: a semicolon immediately before "}" is a syntax error
#       regardless of the whitespace around it. Termination must be a
#       newline instead, the same fix launchCommand already uses. A literal
#       "; }" substring search misses the no-space variant, so this matches
#       a semicolon followed by any amount of whitespace (including none)
#       and then the brace.
semi_brace_pat=';[[:space:]]*}'
if grep -A2 'function runnerOut' <<<"$stripped_runners" | grep -qE "$semi_brace_pat"; then
  bad "runnerOut does not close its group with a semicolon against the brace" "found near runnerOut"
else
  ok "runnerOut does not close its group with a semicolon against the brace"
fi
if grep -A2 'function runnerErr' <<<"$stripped_runners" | grep -qE "$semi_brace_pat"; then
  bad "runnerErr does not close its group with a semicolon against the brace" "found near runnerErr"
else
  ok "runnerErr does not close its group with a semicolon against the brace"
fi

# 5a -- cheap first line: no bare array literal starts on the same line as
#       "command:". Kept alongside 5b even though 5b subsumes it -- two
#       cheap checks that can disagree are easier to diagnose than one
#       clever one that might be wrong in a new way.
hits="$(grep_stripped_all '^[[:space:]]*command:[[:space:]]*\[' || true)"
[[ -z "$hits" ]] && ok "no bare array literal on the same line as command:" \
                 || bad "no bare array literal on the same line as command:" "$hits"

# 5b -- every Process command: goes through a helper, anchored: what follows
#       "command:" must BEGIN with an identifier path ending in one of the
#       helper names immediately followed by "(" -- not merely contain one
#       anywhere. A bare array survives as long as some unrelated string
#       argument happens to mention a helper name (e.g. a notify-send
#       message quoting "tool(update) finished") if the check only searches
#       for the name anywhere in the line; anchoring to the start of the
#       assignment closes that. Falls through to the next line only when
#       nothing at all follows "command:" on its own line, which is what a
#       "[" wrapped onto the next line, or a helper call opened but not
#       argued on the same line, both look like.
helper_anchor_pat='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)*(runner|runnerOut|runnerErr|hypr|tool)\('
trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "$t"; }
hits=""
for f in $(qml_files); do
  mapfile -t lines < <(strip_comments "$f")
  n=${#lines[@]}
  for ((i = 0; i < n; i++)); do
    line="${lines[$i]}"
    [[ "$line" =~ ^[[:space:]]*command:(.*)$ ]] || continue
    rest="$(trim "${BASH_REMATCH[1]}")"
    if [[ -n "$rest" ]]; then
      candidate="$rest"
    else
      nextline=""
      (( i + 1 < n )) && nextline="$(trim "${lines[$((i + 1))]}")"
      candidate="$nextline"
    fi
    if [[ ! "$candidate" =~ $helper_anchor_pat ]]; then
      hits="$hits
$f:$((i + 1)): ${line}"
    fi
  done
done
[[ -z "$hits" ]] && ok "every Process command begins with a helper call" \
                 || bad "every Process command begins with a helper call" "$hits"

# 6 -- teardown covers every declared Process with an actual statement, not
#      merely a mention -- a comment like "// also stop barProc" used to
#      satisfy a bare substring search. The id-detection logic itself
#      (Process { id: foo on one line, or id: split onto the next) is
#      unchanged: it was independently verified sound and is not where the
#      original hole was. What IS new: an id that cannot be extracted at all
#      (a split "id:\n    fooProc", or any other shape this awk does not
#      recognise) used to make the whole Process block produce no line --
#      neither ok nor FAIL -- so a Process nobody can verify was stopped
#      looked identical to a file with no Process at all. Every "Process {"
#      opener is now counted independently of whether an id was extracted
#      from it; a shortfall is a FAIL naming the file, not silence. A wall-
#      clock deadline would end these eventually, but "eventually" is up to
#      two minutes of work nobody is waiting for.
for file in $(qml_files); do
  clean="$(strip_comments "$file")"
  awkout="$(awk '
      /^[[:space:]]*Process[[:space:]]*\{/ { proc_count++; inproc=1 }
      inproc && /id:[[:space:]]*[A-Za-z_]/ {
          match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
          s = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
          print "ID:" s; inproc=0 }
      END { print "COUNT:" (proc_count + 0) }
  ' <<<"$clean")"
  ids="$(sed -n 's/^ID://p' <<<"$awkout")"
  proc_count="$(sed -n 's/^COUNT://p' <<<"$awkout")"
  id_count=0
  [[ -n "$ids" ]] && id_count="$(grep -c . <<<"$ids")"
  if (( proc_count > id_count )); then
    bad "$file: every declared Process has a detectable id" \
        "found $proc_count Process block(s) but extracted only $id_count id(s) -- an id this script cannot read cannot be verified as stopped in teardown"
  fi
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
#       The real, per-value guarantee is a set of behavioural tests in the
#       real engine, in test/harness.qml: "chunks/reconcile: no configured
#       value appears literally in the payload" build a chunk with
#       distinctive class/monitor/address values and assert none survive as
#       readable text, and "chunks/reconcile: nothing numeric survives
#       outside string.char()" additionally cover the workspace field, which
#       cannot be given a distinctive value (WORKSPACE_RE permits only
#       digits) by asking a stronger question instead: strip every
#       string.char(...) group and require no digit to remain anywhere.
#       Trust those four, not this one, for the encoding property.
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
