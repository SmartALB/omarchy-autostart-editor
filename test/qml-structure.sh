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
#
#      MODEL.JS IS COVERED TOO, and was not before: qml_files() lists only
#      ./*.qml, so the one file in this project that builds shell command
#      TEXT was the one file never checked for a PATH-resolved tool name.
#      That needs a different pattern, not just a wider file list. In a qml
#      file a tool name is an argv element, so it is quote-delimited
#      ("bash"); in Model.js it is a bare word inside a larger command
#      string ("{ uwsm-app -- "), which the quote-delimited pattern cannot
#      see at all. Word-boundary match there instead. The leading character
#      class excludes "/" so an absolute /usr/bin/bash is not a hit, and
#      excludes "-" so a hyphenated name is matched whole rather than by its
#      tail.
#
#      Both halves share one verdict: this is one check about one property,
#      not two checks that each cover half a project.
interp_names="bash sh timeout hyprctl head jq setsid uwsm-app"

# THE ONE EXEMPTION, named here so it is argued rather than invisible.
# `uwsm-app` stays PATH-resolved on purpose, ruled in round 5:
#   - the command field it wraps is PATH-resolved BY DESIGN -- users write
#     `nimbus`, not `/usr/bin/nimbus` -- so an absolute path on the wrapper
#     buys nothing the wrapped command does not already give away;
#   - Omarchy's own helpers.lua emits `uwsm-app -- ` bare for that same
#     reason, and matching the platform is worth more here than matching a
#     rule written for interpreters we choose ourselves;
#   - this is a marketplace plugin, and a system installing uwsm under a
#     different prefix would break on a hard-coded path.
# It is exempt BY NAME, not by line: a line carrying both `uwsm-app` and a
# genuine offender still fails, because each name is scanned on its own.
interp_exempt="uwsm-app"

interp_pat="[\"'](bash|sh|timeout|hyprctl|head|jq|setsid)[\"']"
hits="$(grep_stripped_all "$interp_pat" || true)"
model_clean="$(strip_comments Model.js)"
for name in $interp_names; do
  case " $interp_exempt " in *" $name "*) continue ;; esac
  name_hits="$(grep -nE "(^|[^A-Za-z0-9_/-])${name}([^A-Za-z0-9_-]|$)" <<<"$model_clean" || true)"
  [[ -n "$name_hits" ]] && hits="$hits
$(sed "s#^#Model.js:#" <<<"$name_hits")"
done
hits="$(sed '/^$/d' <<<"$hits")"
[[ -z "$hits" ]] && ok "no PATH-resolved interpreter in any qml file or Model.js" \
                 || bad "no PATH-resolved interpreter in any qml file or Model.js" "$hits"

# 2 -- the three absolute binaries are the only ones named, in either quote
#      style.
stripped_runners="$(strip_comments Runners.qml)"
for expected in /usr/bin/timeout /usr/bin/bash /usr/bin/hyprctl /usr/bin/setsid; do
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

# 5 -- every "command:" occurrence goes through THIS FILE'S OWN vetted
#      Runners instance, and never as a bare array. Checked once per
#      OCCURRENCE of "command:" on a line, not once per line: both halves
#      used to be anchored to the START of a line ("^[[:space:]]*command:"),
#      which only ever sees a "command:" that IS the first thing on its
#      line. Two Process blocks sharing one physical line -- Process { id:
#      a; command: run.tool("x") } Process { id: b; command: run.tool("y")
#      } -- is an idiomatic QML one-liner a real author would write (it is
#      exactly the shape check 6 already had to be fixed for, in the
#      previous round), and it put the file's SECOND "command:" entirely
#      outside an anchored pattern's view -- as would a single "command:"
#      that simply is not the first token on its line for any other reason.
#      Both checks below now scan every occurrence on a line via
#      command_occurrences(), never a single line-anchored match, and each
#      occurrence is judged independently -- a line with two commands only
#      passes if BOTH do.
command_occurrences() {
  # $1 = one comment-stripped line. Emits, one per output line, the text
  # immediately following each "command:" occurrence on it, to end of line
  # -- there can be more than one. "command:" must not be preceded by an
  # identifier character (the "(^|[^A-Za-z0-9_])" alternation), so a
  # hypothetical "subCommand:" property is not mistaken for one; this is
  # the same boundary care already used for helper-name matching elsewhere
  # in this file.
  awk '
    {
      s = $0
      while (match(s, /(^|[^A-Za-z0-9_])command:/)) {
        print substr(s, RSTART + RLENGTH)
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' <<<"$1"
}

trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "$t"; }

# Origin-qualification for 5b: a locally shadowed "function tool(raw) {
# return [...] }" satisfies a check that only verifies the NAME "tool(",
# and so does an unrelated object, "legacyToolbox.tool(...)". Neither can
# be told apart from the real thing by a name-only check. What CAN be
# checked without a parser is origin: this file's own "Runners { id: X }"
# declaration names the one instance that was actually wired up, and a call
# is only trusted if it is dot-qualified by exactly that id (whitespace
# around the dot is fine -- "root . tool(...)" is ordinary QML, not a
# decoy). A bare "tool(" (no qualifier) is rejected outright -- it cannot
# be told apart from a shadowed local function, so it is never trusted,
# real or not. A qualifier that is not the declared instance is rejected. A
# file with a "command:" but no "Runners { id: ... }" declaration at all
# fails, since there is then no vetted instance to have called.
#
# This still only verifies the TEXT of the call site, not that the object
# it is called on actually resolves to the real Runners component at
# runtime, and it takes the file's FIRST "Runners { id: ... }" declaration
# if more than one exists -- verifying resolution needs a parser, and this
# script is deliberately not one; see the header.
runners_instance_id() {
  # $1 = comment-stripped file content. Prints the id of the file's first
  # "Runners { id: X }" declaration (X on the same line or a following
  # one), or nothing if none is found. Unanchored and boundary-aware, like
  # command_occurrences() above: "Runners {" can legitimately appear
  # anywhere on a line (Item { Runners { id: runners } ... } is ordinary
  # QML, not only "Runners {" as the first thing on its own line), and the
  # boundary check keeps a type merely ending in "...Runners" (a
  # hypothetical "MyRunners {") from being mistaken for the genuine
  # component.
  awk '
      /(^|[^A-Za-z0-9_])Runners[[:space:]]*\{/ { inrun = 1 }
      inrun && /id:[[:space:]]*[A-Za-z_]/ {
          match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
          s = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
          print s; exit
      }
  ' <<<"$1"
}

hits_5a=""
hits_5b=""
for f in $(qml_files); do
  clean="$(strip_comments "$f")"
  mapfile -t lines <<<"$clean"
  n=${#lines[@]}
  runners_id="$(runners_instance_id "$clean")"
  for ((i = 0; i < n; i++)); do
    line="${lines[$i]}"
    [[ "$line" == *command:* ]] || continue
    while IFS= read -r occ; do
      same="$(trim "$occ")"

      # 5a -- cheap: a bare array literal starting right after THIS
      # occurrence of command:. Kept alongside 5b even though 5b subsumes
      # it -- two cheap checks that can disagree are easier to diagnose
      # than one clever one that might be wrong in a new way.
      if [[ "$same" == \[* ]]; then
        hits_5a="$hits_5a
$f:$((i + 1)): ${line}"
      fi

      # 5b -- anchored to THIS occurrence, origin-qualified. Falls through
      # to the next line only when nothing at all follows this particular
      # "command:" on its own line (a "[" or a call wrapped onto the next
      # line) -- not when a LATER "command:" occurrence on the same line
      # has content; that later occurrence is judged on its own next time
      # around this loop.
      if [[ -n "$same" ]]; then
        candidate="$same"
      else
        nextline=""
        (( i + 1 < n )) && nextline="$(trim "${lines[$((i + 1))]}")"
        candidate="$nextline"
      fi
      if [[ -z "$runners_id" ]]; then
        hits_5b="$hits_5b
$f:$((i + 1)): ${line} (no Runners { id: ... } declaration found in this file)"
      else
        helper_anchor_pat="^${runners_id}[[:space:]]*\.[[:space:]]*(runner|runnerOut|runnerErr|hypr|tool|launcher)\("
        if [[ ! "$candidate" =~ $helper_anchor_pat ]]; then
          hits_5b="$hits_5b
$f:$((i + 1)): ${line}"
        fi
      fi
    done < <(command_occurrences "$line")
  done
done
[[ -z "$hits_5a" ]] && ok "no bare array literal right after any command: occurrence" \
                     || bad "no bare array literal right after any command: occurrence" "$hits_5a"
[[ -z "$hits_5b" ]] && ok "every Process command begins with a call on this file's own Runners instance" \
                     || bad "every Process command begins with a call on this file's own Runners instance" "$hits_5b"

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
  # Brace-depth extraction, not a /start/,/end/ range: a range whose END
  # pattern is "a line starting with }" never matches when the WHOLE
  # onDestruction block is one line -- "Component.onDestruction: { a.running
  # = false }" is ordinary QML for a single-Process file, and the old range
  # then stayed "open" until the file's very last closing brace, silently
  # absorbing everything after it as if it were still inside teardown.
  # Counting braces from the opening line closes the block at its own "}"
  # regardless of how many lines that takes -- coarse (a brace inside a
  # string would confuse it), but the only strings this script ever expects
  # inside a teardown block are shell commands, which have no reason to
  # carry one.
  teardown="$(awk '
      BEGIN { capturing = 0; depth = 0 }
      {
          line = $0
          if (!capturing) {
              if (line !~ /Component\.onDestruction/) next
              capturing = 1
          }
          print line
          n = length(line)
          for (i = 1; i <= n; i++) {
              c = substr(line, i, 1)
              if (c == "{") depth++
              else if (c == "}") {
                  depth--
                  if (depth <= 0) { capturing = 0; i = n + 1 }
              }
          }
      }
  ' <<<"$clean")"
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

# 8 -- the watchdog Timer's own kill must retire the run it just killed, not
#      merely stop the four Processes. Round 1's watchdog stopped them
#      without bumping generation first: each Process still fires its own
#      terminal signal once actually killed, and without the bump that
#      signal's ctx.gen still matches root.generation, so e.g. evalProc's
#      onExited went on to call nextChunk(ctx) -- resuming the very
#      sequence the watchdog exists to end, straight through
#      claimAndLaunch/launchAll. Same brace-depth block extraction as check
#      6's teardown scan (a `Timer { id: watchdog ... }` on however many
#      lines), scanned for "generation += 1" or "generation++" -- either
#      spelling counts, since both retire the run before any queued signal
#      from it can be delivered.
#
#      BINDING THE PLACEMENT, not only the enclosing block: this check
#      stayed green when the bump was moved out of onTriggered into a
#      SIBLING handler of the same Timer -- `onIntervalChanged`, which never
#      fires -- because the bump was still, textually, inside the watchdog's
#      block. The watchdog then reported an error and stopped the four
#      Processes without retiring the run, which is round 1's defect exactly.
#      So the bump is now required inside the onTriggered HANDLER BODY, via
#      handler_body() below, and a watchdog with no locatable onTriggered
#      handler is a FAIL, not a pass: a handler this script cannot read is a
#      handler it cannot verify the bump is in.
#
#      The block extraction now ends where the ENCLOSING component's brace
#      closes (depth going negative), not at the first handler's own closing
#      brace -- otherwise a legitimate reordering that puts another braced
#      handler before onTriggered would push onTriggered out of view and
#      fail for the wrong reason.

# The text of one "onXxx:" handler, brace-aware. A handler is either a
# braced block over however many lines ("onTriggered: {" ... "}") or a
# single statement on the same line ("onTriggered: root.generation += 1");
# both are ordinary QML, so both are recognised -- the single-statement form
# ends at its own line, since it has no brace to close.
handler_body() {
  # $1 = block text, $2 = handler name
  awk -v h="$2" '
      BEGIN { capturing = 0; depth = 0; opened = 0 }
      {
          if (!capturing) {
              if ($0 !~ "(^|[^A-Za-z0-9_])" h "[[:space:]]*:") next
              capturing = 1; depth = 0; opened = 0
          }
          print
          n = length($0)
          for (i = 1; i <= n; i++) {
              c = substr($0, i, 1)
              if (c == "{") { depth++; opened = 1 }
              else if (c == "}") {
                  depth--
                  if (opened && depth <= 0) { capturing = 0; i = n + 1 }
              }
          }
          if (capturing && !opened) capturing = 0
      }
  ' <<<"$1"
}
for file in $(qml_files); do
  clean="$(strip_comments "$file")"
  grep -qE '(^|[^A-Za-z0-9_])id:[[:space:]]*watchdog([^A-Za-z0-9_]|$)' <<<"$clean" || continue
  block="$(awk '
      BEGIN { capturing = 0; depth = 0 }
      {
          line = $0
          if (!capturing) {
              if (line !~ /(^|[^A-Za-z0-9_])id:[[:space:]]*watchdog([^A-Za-z0-9_]|$)/) next
              capturing = 1
              depth = 0
          }
          print line
          n = length(line)
          for (i = 1; i <= n; i++) {
              c = substr(line, i, 1)
              if (c == "{") depth++
              else if (c == "}") {
                  depth--
                  if (depth < 0) { capturing = 0; i = n + 1 }
              }
          }
      }
  ' <<<"$clean")"
  triggered="$(handler_body "$block" onTriggered)"
  gen_bump_pat='(^|[^A-Za-z0-9_.])(root\.)?generation[[:space:]]*(\+=[[:space:]]*1|\+\+)([^A-Za-z0-9_]|$)'
  if [[ -z "$triggered" ]]; then
    bad "$file: the watchdog retires its own run (bumps generation) inside onTriggered" \
        "no onTriggered handler found in the watchdog's block -- a handler this script cannot locate is one it cannot verify the generation bump is in"
  elif grep -qE "$gen_bump_pat" <<<"$triggered"; then
    ok "$file: the watchdog retires its own run (bumps generation) inside onTriggered"
  else
    bad "$file: the watchdog retires its own run (bumps generation) inside onTriggered" \
        "no 'generation += 1' (or '++') inside the watchdog's onTriggered body -- in a sibling handler that never fires it is not a retirement, and a killed Process's own terminal signal would still match ctx.gen and resume the sequence"
  fi

  # 8b -- the watchdog is the ONLY release path for a Process that never
  #       emits `exited`, which is the whole reason the Timer exists (Qt
  #       emits no finished() on a failed start, and Quickshell.Io exposes no
  #       error signal). Both busy flags are otherwise cleared only by their
  #       own onExited, so a watchdog that stops the Processes without
  #       clearing them latches both queues for the rest of the session:
  #       every later load() returns at the busy branch and the
  #       configuration is never read again -- permanent, silent and total.
  #       Bound to the onTriggered body for the same reason as check 8: in a
  #       sibling handler these statements never run.
  missing=""
  for release in \
      'readBusy[[:space:]]*=[[:space:]]*false' \
      'evalBusy[[:space:]]*=[[:space:]]*false' \
      'pendingLoad[[:space:]]*=[[:space:]]*null' \
      'pendingChunkRun[[:space:]]*=[[:space:]]*null'; do
    grep -qE "(^|[^A-Za-z0-9_.])(root\.)?${release}([^A-Za-z0-9_]|$)" <<<"$triggered" \
      || missing="$missing ${release%%[*}"
  done
  if [[ -z "$missing" ]]; then
    ok "$file: the watchdog releases both busy flags and both pending slots"
  else
    bad "$file: the watchdog releases both busy flags and both pending slots" \
        "not released inside the watchdog's onTriggered body:$missing -- a Process that never emits 'exited' would latch its queue for the whole session"
  fi
done

# 9 -- no bare `Process.<CapitalisedName>` enum reference anywhere in the
#      qml tree. Round 3's own defect: `Process.NormalExit` reads like a
#      compile-time constant but the installed Quickshell.Io type
#      information (quickshell-io.qmltypes) declares ZERO Enum {} blocks on
#      Process, and "NormalExit" appears in no file at all under
#      /usr/lib/qt6/qml/ -- so the expression silently evaluates to
#      `undefined`, every comparison against it behaves as if the branch
#      were unconditionally taken, and nothing in test/harness.qml or
#      test/run-tests.sh can see it: Quickshell.Io cannot be loaded outside
#      the runtime, so this is exactly the class of defect this file's
#      header says a structural check can catch that no behavioural test
#      can. Comment-stripped, so a comment naming the old mistake (as this
#      file's own history now does, and as Service.qml's own comment
#      explaining the fix does) is not itself a hit.
hits="$(grep_stripped_all 'Process\.[A-Z][A-Za-z0-9_]*' || true)"
[[ -z "$hits" ]] && ok "no bare Process.<CapitalisedName> enum reference in any qml file" \
                 || bad "no bare Process.<CapitalisedName> enum reference in any qml file" "$hits"

# 9b -- the value the exitStatus comparison ACTUALLY READS must be 0 --
#       followed through the reference, not asserted about a declaration in
#       isolation. Check 9 above only forbids the old `Process.NormalExit`
#       spelling. The first version of this check then asserted that a
#       property NAMED normalExit was declared 0, which is half the
#       property: it stayed green for a comparison reading a DIFFERENT
#       property while a still-correct `normalExit: 0` sat declared
#       elsewhere in the file. That recreates round 3's defect exactly --
#       `exitStatus !== <something that is not 0>` rejects every NORMAL
#       exit, sessionStartOwed never comes down, launchAll() is never
#       reached, and the autostart silently never runs in any session, with
#       every shell/QML/structural assertion green. It also needs no
#       contrived decoy: an ordinary rename produces it.
#
#       So: find every explicit comparison against `exitStatus`, take the
#       operand it reads, and require THAT identifier's own declaration to
#       be 0. QProcess::ExitStatus::NormalExit is fixed at 0 by Qt, so 0 is
#       the only admissible binding; a numeric literal operand is accepted
#       only if it IS 0. Every declaration of the identifier is checked, not
#       merely the first, and an identifier with no declaration anywhere is
#       a FAIL -- `Process.NormalExit` lands there too, which is check 9's
#       finding reached a second way.
#
#       A comparison shape this script cannot read is a FAIL, not a pass:
#       same rule as check 8's onTriggered. Only an explicit
#       `exitStatus <op> <operand>` is recognised -- a truthiness test
#       (`if (exitStatus)`) is equivalent in behaviour but not readable
#       here, and would have to be spelled out to pass. What this still
#       cannot do, like check 5b, is verify that the operand's QUALIFIER
#       resolves to the object holding that declaration; the identifier
#       after the last dot is what is followed.
exit_cmp_pat='exitStatus[[:space:]]*(!==|===|!=|==)[[:space:]]*[A-Za-z0-9_.]+'
cmp_hits="$(grep_stripped_all "$exit_cmp_pat" || true)"
if [[ -z "$cmp_hits" ]]; then
  bad "the exitStatus comparison reads a constant declared 0" \
      "no explicit 'exitStatus <op> <operand>' comparison found in any qml file -- markerProc's guard against trusting exitCode after a signal-kill either lost its comparison or wears a shape this script cannot read; either way it cannot be verified"
else
  norm_bad=""
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    while IFS= read -r operand; do
      [[ -z "$operand" ]] && continue
      if [[ "$operand" =~ ^[0-9]+$ ]]; then
        [[ "$operand" == "0" ]] || norm_bad="$norm_bad
$hit -- compares against the literal $operand, and NormalExit is 0"
        continue
      fi
      ident="${operand##*.}"
      decl_pat="property[[:space:]]+int[[:space:]]+${ident}[[:space:]]*:"
      decl="$(grep_stripped_all "$decl_pat" || true)"
      if [[ -z "$decl" ]]; then
        norm_bad="$norm_bad
$hit -- reads '$operand', but no 'property int $ident:' is declared in any qml file"
      else
        wrong="$(grep -vE "${decl_pat}[[:space:]]*0[[:space:]]*$" <<<"$decl" || true)"
        [[ -n "$wrong" ]] && norm_bad="$norm_bad
$hit -- reads '$operand', declared as: $(tr '\n' ';' <<<"$wrong")"
      fi
    done < <(grep -oE "$exit_cmp_pat" <<<"$hit" \
             | sed -E 's/^.*(!==|===|!=|==)[[:space:]]*([A-Za-z0-9_.]+)$/\2/')
  done <<<"$cmp_hits"
  norm_bad="$(sed '/^$/d' <<<"$norm_bad")"
  [[ -z "$norm_bad" ]] && ok "the exitStatus comparison reads a constant declared 0" \
                       || bad "the exitStatus comparison reads a constant declared 0" "$norm_bad"
fi

# BarWidget.qml checks below all read through strip_comments, like every
# other check in this file -- a comment repeating the right words must never
# satisfy a check meant to verify real code. (Round-1 finding F2: checks 8
# and 9 below used to grep BarWidget.qml directly; replacing
# closeForPopoutSwitch()'s body with a comment carrying the same literal
# text left them green. This is the same evasion check 3's own comment
# already warns future checks about, reintroduced here and now closed the
# same way as everywhere else in this file.)
stripped_barwidget="$(strip_comments BarWidget.qml)"

# 8 -- the plugin lifecycle contract from the develop guide. DECLARED
#      only -- this proves the four functions and two properties exist
#      under the right names, nothing about what they do. Check 12
#      below closes the other half (FORWARDING) for the four
#      functions, the same way check 11 already does it for the two
#      properties: declared and forwarding are two separate claims in
#      this file, checked separately, because an empty body satisfies
#      this check exactly as well as a real one does (round-2
#      finding).
for needed in "function open()" "function close()" "function toggle()" \
              "function closeForPopoutSwitch()" \
              "readonly property bool opened" \
              "readonly property bool popoutSwitchClosing"; do
  grep -qF "$needed" <<<"$stripped_barwidget" \
    && ok "BarWidget declares $needed" \
    || bad "BarWidget declares $needed" "not found (comment-stripped)"
done

# 9 -- the bar glyph is present as an escape and not as a literal PUA
#      character, both checked on the comment-stripped view for the same
#      reason as check 8: a comment naming the right escape, or hiding a
#      raw glyph, must not stand in for the real property.
#      python3 rather than grep -P: with LC_ALL=C, PCRE rejects \x{} values
#      above 0xFF outright, so the check would end in an error instead of a
#      result. The stripped text is written to a temp file so the script
#      can still open it by path, exactly like the original file-argument
#      form -- only the input feeding it changed.
if grep -qE 'barGlyph:[[:space:]]*"\\u[0-9a-fA-F]{4}"' <<<"$stripped_barwidget"; then
  ok "BarWidget: bar glyph is written as a \\u escape"
else
  bad "BarWidget: bar glyph is written as a \\u escape" \
      "$(grep -n 'barGlyph' BarWidget.qml || echo 'no barGlyph at all')"
fi
pua_tmp="$(mktemp)"
printf '%s\n' "$stripped_barwidget" > "$pua_tmp"
if python3 - "$pua_tmp" <<'PUA'
import io, sys
text = io.open(sys.argv[1], encoding="utf-8", errors="replace").read()
sys.exit(1 if any(0xE000 <= ord(c) <= 0xF8FF for c in text) else 0)
PUA
then
  ok "BarWidget: no literal private-use character in the file"
else
  bad "BarWidget: no literal private-use character in the file" \
      "found a raw PUA codepoint -- write it as \\uXXXX"
fi
rm -f "$pua_tmp"

# 10 -- the glyph found by check 9 is not merely present somewhere in the
#       file, it is actually the text the bar button shows. Round-1 finding
#       F1: deleting `text: root.barGlyph` from the button left checks 8/9
#       green -- exactly the invisible-button failure this task's own
#       preamble warns about, undetected because nothing coupled the glyph
#       to the button. Scoped to this file's own `BarIconButton { ... }`
#       block (brace-depth extraction, the same technique check 6 uses for
#       a teardown block) so a decoy `text: root.barGlyph` sitting anywhere
#       else in the file could not satisfy this either.
icon_block="$(awk '
    BEGIN { capturing = 0; depth = 0 }
    {
        line = $0
        if (!capturing) {
            if (line !~ /(^|[^A-Za-z0-9_])BarIconButton[[:space:]]*\{/) next
            capturing = 1
            depth = 0
        }
        print line
        n = length(line)
        for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            if (c == "{") depth++
            else if (c == "}") {
                depth--
                if (depth <= 0) { capturing = 0; i = n + 1 }
            }
        }
    }
' <<<"$stripped_barwidget")"
if [[ -z "$icon_block" ]]; then
  bad "BarWidget: the bar button's text is bound to barGlyph" \
      "no 'BarIconButton { ... }' block found in BarWidget.qml"
elif grep -qE '(^|[^A-Za-z0-9_.])text:[[:space:]]*(root\.)?barGlyph([^A-Za-z0-9_]|$)' <<<"$icon_block"; then
  ok "BarWidget: the bar button's text is bound to barGlyph"
else
  bad "BarWidget: the bar button's text is bound to barGlyph" \
      "no 'text: (root.)barGlyph' inside the BarIconButton block: $icon_block"
fi

# The right-hand side of a `readonly property bool <name>:` declaration --
# same line after the colon, or (if nothing follows there) the next line.
# Same same-line-or-next-line handling check 6 already uses for
# onDestruction ids, and check 9b for exitStatus operands.
property_binding() {
  # $1 = comment-stripped content, $2 = property name
  awk -v name="$2" '
    { lines[NR] = $0 }
    END {
      pat = "(^|[^A-Za-z0-9_])readonly[[:space:]]+property[[:space:]]+bool[[:space:]]+" name "[[:space:]]*:"
      for (i = 1; i <= NR; i++) {
        if (match(lines[i], pat)) {
          rhs = substr(lines[i], RSTART + RLENGTH)
          gsub(/^[[:space:]]+/, "", rhs); gsub(/[[:space:]]+$/, "", rhs)
          if (rhs == "" && i < NR) {
            rhs = lines[i + 1]
            gsub(/^[[:space:]]+/, "", rhs); gsub(/[[:space:]]+$/, "", rhs)
          }
          print rhs
          exit
        }
      }
    }
  ' <<<"$1"
}

# 11 -- `opened` and `popoutSwitchClosing` are bound to the loaded panel's
#       real state, not merely declared under the right name. Round-1
#       finding F3: hardcoding `readonly property bool opened: true` --
#       which breaks the panel handoff outright -- left check 8 above
#       green, because check 8 only verifies the declaration's TEXT, never
#       the expression it holds. Applied to both lifecycle booleans, not
#       only the one the finding named, since the same defect shape is
#       equally possible on either. A literal true/false, or an expression
#       that never mentions the Loader, is rejected; only an expression
#       that reads panelLoader is accepted -- panelLoader is this file's
#       own Loader id, so this is origin-qualified the same way check 5b is
#       for Runners calls. Like check 8's onTriggered lookup, a property
#       this script cannot locate at all is a FAIL, not a pass.
for prop in opened popoutSwitchClosing; do
  rhs="$(property_binding "$stripped_barwidget" "$prop")"
  if [[ -z "$rhs" ]]; then
    bad "BarWidget: '$prop' is bound to panelLoader, not a literal" \
        "no expression found on the declaration's line or the next"
  elif [[ "$rhs" =~ ^(true|false)\;?$ ]]; then
    bad "BarWidget: '$prop' is bound to panelLoader, not a literal" \
        "bound to the hardcoded literal '$rhs'"
  elif [[ "$rhs" != *panelLoader* ]]; then
    bad "BarWidget: '$prop' is bound to panelLoader, not a literal" \
        "expression '$rhs' never mentions panelLoader"
  else
    ok "BarWidget: '$prop' is bound to panelLoader, not a literal"
  fi
done


# 12 -- the four lifecycle contract functions do not merely exist (check 8),
#       they forward toward the panel. Round-2 finding: an empty body --
#       `function closeForPopoutSwitch() { }`, no comment tricks needed --
#       left every check so far green, because check 8 only proves the
#       declaration's TEXT exists. This is the same gap check 11 closed for
#       the two lifecycle booleans, applied here for consistency: leaving
#       one member of the class unbound while its siblings are bound is the
#       inconsistency that makes a check suite hard to trust. Declared and
#       forwarding are two separate claims, checked separately, the same
#       way check 8 (declared) and check 11 (bound) are separate for the
#       properties.
#
#       Each function's own body (brace-depth extraction, same technique as
#       the watchdog block above) must reference either `panelLoader`
#       directly, or one of its three sibling contract functions by name.
#       The sibling alternative exists because `toggle()` reaches the panel
#       only through `open()`/`close()`, never `panelLoader` itself --
#       requiring the literal name everywhere would fail on that legitimate
#       body, not just on the empty one this check exists to catch.
#
#       Deliberately shallow, per ruling: this does not verify which
#       panelLoader call is made, or that the sibling a function calls is
#       the *right* one, only that the body is not a no-op. Going further --
#       verifying what the forwarded call does, or hardening against a dead
#       string literal naming panelLoader without using it -- is the shape
#       arms-race this file's own header already says this project
#       abandoned.
function_body() {
  # $1 = comment-stripped content, $2 = function name. Brace-depth
  # extraction, same style as the watchdog block extraction above.
  awk -v fn="$2" '
    BEGIN { capturing = 0; depth = 0; started = 0 }
    {
      line = $0
      if (!capturing) {
        if (line !~ "(^|[^A-Za-z0-9_])function[[:space:]]+" fn "[[:space:]]*\\(") next
        capturing = 1; depth = 0; started = 0
      }
      print line
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "{") { depth++; started = 1 }
        else if (c == "}") {
          depth--
          if (started && depth <= 0) { capturing = 0; i = n + 1 }
        }
      }
    }
  ' <<<"$1"
}

lifecycle_fns="open close toggle closeForPopoutSwitch"
reach_boundary='(^|[^A-Za-z0-9_])'
for fn in $lifecycle_fns; do
  body="$(function_body "$stripped_barwidget" "$fn")"
  if [[ -z "$body" ]]; then
    bad "BarWidget: $fn() forwards to the panel" \
        "no 'function $fn(...) { ... }' block found"
    continue
  fi
  reaches=0
  if grep -qE "${reach_boundary}panelLoader([^A-Za-z0-9_]|\$)" <<<"$body"; then
    reaches=1
  else
    for sibling in $lifecycle_fns; do
      [[ "$sibling" == "$fn" ]] && continue
      if grep -qE "${reach_boundary}${sibling}[[:space:]]*\(" <<<"$body"; then
        reaches=1
        break
      fi
    done
  fi
  if (( reaches )); then
    ok "BarWidget: $fn() forwards to the panel"
  else
    bad "BarWidget: $fn() forwards to the panel" \
        "body never mentions panelLoader or a sibling lifecycle function: $body"
  fi
done

# ---------------------------------------------------------------------------
# Panel.qml and the platform contract it stands on (task 15, fix round 1).
#
# All checks below read through strip_comments, like every other check in this
# file. The task brief spelled the first three against the RAW file; that is
# exactly the evasion round 1 already found and closed for the BarWidget
# checks (finding F2), where replacing closeForPopoutSwitch()'s body with a
# comment carrying the same literal text left them green. The positive checks
# gain the guarantee the rest of this file has, and the negative ones lose
# nothing: stripping removes comments, never code.
stripped_panel="$(strip_comments Panel.qml)"

# The text of the first `<TypeName> { ... }` block in a file, brace-depth
# extracted -- the same technique check 6 uses for a teardown block and check
# 10 for the bar button. Shared by the checks below rather than inlined three
# times.
block_of() {
  # $1 = comment-stripped content, $2 = type name
  awk -v type="$2" '
      BEGIN { capturing = 0; depth = 0 }
      {
          line = $0
          if (!capturing) {
              if (line !~ "(^|[^A-Za-z0-9_])" type "[[:space:]]*\\{") next
              capturing = 1
              depth = 0
          }
          print line
          n = length(line)
          for (i = 1; i <= n; i++) {
              c = substr(line, i, 1)
              if (c == "{") depth++
              else if (c == "}") {
                  depth--
                  if (depth <= 0) { capturing = 0; i = n + 1 }
              }
          }
      }
  ' <<<"$1"
}

# 13 -- the root type is the platform's own `Panel` (qs.Ui).
#
#       This is the answer to the surface problem, and it is load-bearing in a
#       way no other line in the file is: `Ui/Panel.qml` is what supplies
#       `controller`, `opened`, `bar` and the whole popup lifecycle. Demote the
#       root to a bare `Item` and every one of those references becomes
#       undefined at runtime -- the panel would load, pass qmllint, and never
#       open. Eight of the nine shipped panels use this type; only
#       disk-speedtest does not.
#
#       The root type is the first thing after the imports that opens a block.
#       Anything else appearing there is a FAIL, not a pass: a shape this
#       script cannot read is one it cannot verify, the same rule as check 8's
#       onTriggered.
root_type_of() {
  awk '
      { line = $0
        gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
        if (line == "") next
        if (line ~ /^import[[:space:]]/) next
        if (match(line, /^[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\{/)) {
            t = substr(line, RSTART, RLENGTH)
            sub(/[[:space:]]*\{$/, "", t)
            print t; exit
        }
        print "<unreadable: " line ">"; exit
      }
  ' <<<"$1"
}
panel_root="$(root_type_of "$stripped_panel")"
if [[ "$panel_root" == "Panel" ]]; then
  ok "Panel.qml's root type is the platform Panel"
else
  bad "Panel.qml's root type is the platform Panel" \
      "first type after the imports is '${panel_root:-<none found>}' -- a bare Item has no controller, no opened and no popup lifecycle, so the panel would load and never open"
fi

# 14 -- what Panel.qml itself declares. The four lifecycle functions are NOT
#       all here any more: `closeForPopoutSwitch` comes from the base type
#       (which also clears the flag through Qt.callLater, better than the
#       override this file used to carry), while open/close/toggle are
#       overridden so opening can read the configuration first -- the shipped
#       idiom, clock/Panel.qml does exactly this. `counted` is this plugin's
#       own signal and BarWidget.qml connects to it.
for needed in "function open()" "function close()" "function toggle()" \
              "signal counted("; do
  grep -qF "$needed" <<<"$stripped_panel" \
    && ok "Panel declares $needed" \
    || bad "Panel declares $needed" "not found (comment-stripped)"
done

# 15 -- and what it must NOT declare. Redeclaring a property the base type
#       already has is a COMPONENT CREATION ERROR: the panel fails to
#       instantiate, the bar widget's Loader reports an error, and the plugin
#       is simply absent. Nothing in this project can execute a file that
#       imports Quickshell, so this is precisely the class of defect only a
#       structural check can reach -- the same argument as check 9's.
#
#       This is also the trap the previous round walked into honestly: those
#       two booleans were declared by hand here, because the brief asked for
#       them, before the base type was known to provide them.
inherited="opened popoutSwitchClosing popoutSwitching bar settings moduleName ipcTarget manageIpc controller"
redeclared=""
for member in $inherited; do
  hit="$(grep -nE "(^|[^A-Za-z0-9_])property[[:space:]]+[A-Za-z_][A-Za-z0-9_<>]*[[:space:]]+${member}[[:space:]]*:" \
         <<<"$stripped_panel" || true)"
  [[ -n "$hit" ]] && redeclared="$redeclared
$member: $hit"
done
redeclared="$(sed '/^$/d' <<<"$redeclared")"
[[ -z "$redeclared" ]] && ok "Panel redeclares none of the base type's members" \
                       || bad "Panel redeclares none of the base type's members" "$redeclared"

# 16 -- the popup surface exists and is wired to the injected anchor.
#
#       A KeyboardPanel is the visible window; without it the root Item paints
#       wherever its host puts it, which for a bar widget's Loader means
#       nowhere useful. And an anchorItem that is not the INJECTED one cannot
#       position the card: KeyboardPanel reads its screen and its origin off
#       that item, so a hardcoded or missing anchor puts the popup at the
#       screen corner with no screen resolved. Scoped to the KeyboardPanel's
#       own block so a decoy binding elsewhere in the file cannot satisfy it.
keyboard_block="$(block_of "$stripped_panel" KeyboardPanel)"
if [[ -z "$keyboard_block" ]]; then
  bad "Panel: the KeyboardPanel surface is anchored to the injected anchorItem" \
      "no 'KeyboardPanel { ... }' block in Panel.qml -- the panel then has no window at all"
else
  surface_missing=""
  grep -qE '(^|[^A-Za-z0-9_.])anchorItem:[[:space:]]*root\.anchorItem([^A-Za-z0-9_]|$)' <<<"$keyboard_block" \
    || surface_missing="$surface_missing anchorItem:root.anchorItem"
  grep -qE '(^|[^A-Za-z0-9_.])open:[[:space:]]*root\.opened([^A-Za-z0-9_]|$)' <<<"$keyboard_block" \
    || surface_missing="$surface_missing open:root.opened"
  if [[ -z "$surface_missing" ]]; then
    ok "Panel: the KeyboardPanel surface is anchored to the injected anchorItem"
  else
    bad "Panel: the KeyboardPanel surface is anchored to the injected anchorItem" \
        "not bound inside the KeyboardPanel block:$surface_missing"
  fi
fi

# 17 -- applying is explicit. Moving real windows across real screens must not
#       be a side effect of a keystroke, so no field may write straight
#       through to disk.
hits="$(grep -nE 'onTextChanged:.*(writeProc|applyRules|config-write)' <<<"$stripped_panel" || true)"
[[ -z "$hits" ]] && ok "Panel: no field writes through on change" \
                 || bad "Panel: no field writes through on change" "$hits"

# 18 -- the class field is never handed to a JavaScript RegExp. The allowlist
#       permits nested quantifiers and QML gives JavaScript no timeout.
hits="$(grep -nE 'new RegExp|\.match\(|\.test\(' <<<"$stripped_panel" \
        | grep -vE 'WORKSPACE_RE|MONITOR_RE|ADDRESS_RE|ID_RE' || true)"
[[ -z "$hits" ]] && ok "Panel: no JavaScript RegExp over user patterns" \
                 || bad "Panel: no JavaScript RegExp over user patterns" "$hits"

# 19 -- the bar widget hands the panel its anchor.
#
#       THE PANEL CANNOT POSITION ITSELF WITHOUT THIS, and the failure is
#       silent: `anchorItem` stays null, KeyboardPanel resolves no screen, and
#       the popup either does not map or lands in a corner. The panel side is
#       already checked (16); this is the other half of the same handover, and
#       the two are separate claims for the same reason declared and forwarding
#       are separate for the lifecycle functions.
injectp_body="$(function_body "$stripped_barwidget" injectPanel)"
if [[ -z "$injectp_body" ]]; then
  bad "BarWidget: injectPanel() hands the panel its anchorItem" \
      "no 'function injectPanel(...) { ... }' block found -- the panel's popup has nothing to anchor to"
elif grep -qE '(^|[^A-Za-z0-9_])anchorItem[[:space:]]*=' <<<"$injectp_body"; then
  ok "BarWidget: injectPanel() hands the panel its anchorItem"
else
  bad "BarWidget: injectPanel() hands the panel its anchorItem" \
      "the body never assigns anchorItem: $injectp_body"
fi

# 20 -- and it is called from all four sites the platform needs.
#
#       Each one covers a different moment and none of them is redundant:
#       onLoaded is the only one that fires for a panel created before `bar`
#       is set; the deferred second call is what catches a `bar` that was
#       already set before this Loader ran (onBarChanged does not fire for a
#       value assigned earlier); and onBarChanged / onSettingsChanged catch
#       every later change. clock/BarWidget.qml wires exactly these four.
loader_block="$(block_of "$stripped_barwidget" Loader)"
onloaded_body="$(handler_body "$loader_block" onLoaded)"
if [[ -z "$onloaded_body" ]]; then
  bad "BarWidget: injectPanel() runs from the Loader's onLoaded, directly and deferred" \
      "no onLoaded handler found inside the Loader block"
else
  loaded_missing=""
  grep -qE '(^|[^A-Za-z0-9_])injectPanel[[:space:]]*\(' <<<"$onloaded_body" \
    || loaded_missing="$loaded_missing direct-call"
  grep -qE 'Qt\.callLater\([^)]*injectPanel' <<<"$onloaded_body" \
    || loaded_missing="$loaded_missing Qt.callLater"
  if [[ -z "$loaded_missing" ]]; then
    ok "BarWidget: injectPanel() runs from the Loader's onLoaded, directly and deferred"
  else
    bad "BarWidget: injectPanel() runs from the Loader's onLoaded, directly and deferred" \
        "missing in the onLoaded body:$loaded_missing"
  fi
fi
for handler in onBarChanged onSettingsChanged; do
  hbody="$(handler_body "$stripped_barwidget" "$handler")"
  if [[ -z "$hbody" ]]; then
    bad "BarWidget: injectPanel() runs from $handler" \
        "no $handler handler found -- a value arriving after construction would never reach the panel"
  elif grep -qE '(^|[^A-Za-z0-9_])injectPanel[[:space:]]*\(' <<<"$hbody"; then
    ok "BarWidget: injectPanel() runs from $handler"
  else
    bad "BarWidget: injectPanel() runs from $handler" "the handler never calls injectPanel: $hbody"
  fi
done

# 21 -- the Loader is eager, and not painted through the bar slot.
#
#       Lazy was the earlier ruling and it is wrong for this construction: the
#       anchor is injected from onLoaded, so with `active: false` the anchor
#       arrives only AFTER the first open -- the first click opens a popup with
#       nothing to position against. Eagerness costs nothing here because the
#       panel reads the configuration in open(), not at creation.
#       `visible: false` because the Loader's item is content, not a bar
#       control; the popup is a layer-shell window of its own.
if [[ -z "$loader_block" ]]; then
  bad "BarWidget: the panel Loader is eager and not painted in the bar slot" \
      "no 'Loader { ... }' block found in BarWidget.qml"
else
  loader_missing=""
  grep -qE '(^|[^A-Za-z0-9_.])active:[[:space:]]*true([^A-Za-z0-9_]|$)' <<<"$loader_block" \
    || loader_missing="$loader_missing active:true"
  grep -qE '(^|[^A-Za-z0-9_.])visible:[[:space:]]*false([^A-Za-z0-9_]|$)' <<<"$loader_block" \
    || loader_missing="$loader_missing visible:false"
  if [[ -z "$loader_missing" ]]; then
    ok "BarWidget: the panel Loader is eager and not painted in the bar slot"
  else
    bad "BarWidget: the panel Loader is eager and not painted in the bar slot" \
        "not set inside the Loader block:$loader_missing"
  fi
fi

printf '\nqml structure: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
