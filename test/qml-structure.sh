#!/usr/bin/env bash
# WHAT THIS SCRIPT IS, AND WHAT IT IS NOT
#
# It is a smoke detector for the files no test can execute: Quickshell.Io
# does not exist outside the Quickshell runtime, so Runners.qml, Service.qml,
# BarWidget.qml and Panel.qml have no runnable suite at all. These checks
# catch an honest mistake -- a limit dropped during a refactor, a Process
# added without a teardown line, an absolute path turned into a bare name.
#
# It is NOT a guarantee, and three adversarial passes proved it: source text
# a real author would plausibly write defeated eleven checks across those
# passes -- a comment claiming a property the code had lost, a decoy helper
# name inside an unrelated string, a `//` hidden in a template literal that
# blinded every later check on the line. Each was closed; more exist.
# Verifying that a call resolves to the vetted helper, or that a value is
# reachable, needs a parser, and this is not one.
#
# What IS guaranteed lives elsewhere: every value that reaches Lua is
# covered by behavioural tests in test/harness.qml, verified by stripping
# each of the eleven luaBytes() call sites in turn and watching each one
# turn an assertion red. Everything about actual runtime behaviour is
# covered only by the manual checklist in the final task -- and that is
# where it has to stay honest.
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

# 5b -- every Process command: goes through a helper, anchored, and through
#       THIS FILE'S OWN vetted instance -- not just a name that happens to
#       match. Naming alone was still gameable: a locally shadowed
#       "function tool(raw) { return [...] }" satisfies a check that only
#       verifies the NAME "tool(", and so does an unrelated object,
#       "legacyToolbox.tool(...)". Neither can be told apart from the real
#       thing by a name-only check. What CAN be checked without a parser is
#       origin: this file's own "Runners { id: X }" declaration names the
#       one instance that was actually wired up, and a call is only trusted
#       if it is dot-qualified by exactly that id (whitespace around the dot
#       is fine -- "root . tool(...)" is ordinary QML, not a decoy). A bare
#       "tool(" (no qualifier) is rejected outright -- it cannot be told
#       apart from a shadowed local function, so it is never trusted, real
#       or not. A qualifier that is not the declared instance is rejected.
#       A file with a "command:" but no "Runners { id: ... }" declaration at
#       all fails, since there is then no vetted instance to have called.
#       Falls through to the next line only when nothing at all follows
#       "command:" on its own line (a "[" or a call wrapped onto the next
#       line).
#
#       This still only verifies the TEXT of the call site, not that the
#       object it is called on actually resolves to the real Runners
#       component at runtime, and it takes the file's FIRST "Runners { id:
#       ... }" declaration if more than one exists -- verifying resolution
#       needs a parser, and this script is deliberately not one; see the
#       header.
trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "$t"; }
runners_instance_id() {
  # $1 = comment-stripped file content. Prints the id of the file's first
  # "Runners { id: X }" declaration (X on the same line or a following one,
  # same shape as the Process id-detection below), or nothing if nine is
  # found.
  awk '
      /^[[:space:]]*Runners[[:space:]]*\{/ { inrun = 1 }
      inrun && /id:[[:space:]]*[A-Za-z_]/ {
          match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
          s = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
          print s; exit
      }
  ' <<<"$1"
}
hits=""
for f in $(qml_files); do
  clean="$(strip_comments "$f")"
  mapfile -t lines <<<"$clean"
  n=${#lines[@]}
  runners_id="$(runners_instance_id "$clean")"
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
    if [[ -z "$runners_id" ]]; then
      hits="$hits
$f:$((i + 1)): ${line} (no Runners { id: ... } declaration found in this file)"
      continue
    fi
    helper_anchor_pat="^${runners_id}[[:space:]]*\.[[:space:]]*(runner|runnerOut|runnerErr|hypr|tool)\("
    if [[ ! "$candidate" =~ $helper_anchor_pat ]]; then
      hits="$hits
$f:$((i + 1)): ${line}"
    fi
  done
done
[[ -z "$hits" ]] && ok "every Process command begins with a call on this file's own Runners instance" \
                 || bad "every Process command begins with a call on this file's own Runners instance" "$hits"

# 6 -- teardown covers every declared Process with an actual statement, not
#      merely a mention -- a comment like "// also stop barProc" used to
#      satisfy a bare substring search. Every "Process {" opener is counted
#      independently of whether an id was extracted from it; a shortfall is
#      a FAIL naming the file, not silence -- a Process nobody can verify
#      was stopped must never look identical to a file with no Process at
#      all. A wall-clock deadline would end these eventually, but
#      "eventually" is up to two minutes of work nobody is waiting for.
#
#      The opener count uses gsub(), not a per-line match: a line-anchored
#      pattern that fires at most once per record undercounts two "Process {"
#      openers sharing one physical line, and the shortfall silently stopped
#      registering because the (also undercounted) id total matched it. The
#      id harvest walks every "id:" on a line, not just the first, gated by
#      how many openers are still awaiting one ("pending") so it does not
#      over-collect from an unrelated "id:" once every opener already has
#      one. An opener whose id sits on a LATER line (Process { alone, then
#      id: fooProc below) still works: pending carries forward to that line.
for file in $(qml_files); do
  clean="$(strip_comments "$file")"
  awkout="$(awk '
      {
          n_open = gsub(/Process[[:space:]]*\{/, "&")
          proc_count += n_open
          pending += n_open
          if (pending > 0) {
              rest = $0
              while (pending > 0 && match(rest, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
                  s = substr(rest, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
                  print "ID:" s
                  pending--
                  rest = substr(rest, RSTART + RLENGTH)
              }
          }
      }
      END { print "COUNT:" (proc_count + 0) }
  ' <<<"$clean")"
  ids="$(sed -n 's/^ID://p' <<<"$awkout")"
  proc_count="$(sed -n 's/^COUNT://p' <<<"$awkout")"
  id_count=0
  [[ -n "$ids" ]] && id_count="$(grep -c . <<<"$ids")"
  if (( proc_count > id_count )); then
    bad "$file: every declared Process has a detectable id" \
        "found $proc_count Process block(s) (opener count) but extracted only $id_count id(s) -- an id this script cannot read cannot be verified as stopped in teardown"
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
