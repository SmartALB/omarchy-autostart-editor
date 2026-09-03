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
# EXTEND THIS WHENEVER A BINARY IS ADDED ANYWHERE IN THE PLUGIN. It is a
# fixed list, task 13's round-4 implementer said so in as many words, and
# nobody extended it: `mktemp` and `rm` arrived with task 15 and could have
# been PATH-resolved through all five suites. Check 2b below is the standing
# answer -- it needs no list at all -- but this one still names what must
# never appear quoted-and-bare.
interp_names="bash sh timeout hyprctl head jq setsid mktemp rm uwsm-app"

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

interp_pat="[\"'](bash|sh|timeout|hyprctl|head|jq|setsid|mktemp|rm)[\"']"
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

# 2 -- the four binaries this fixed list names are each named absolutely, in
#      either quote style. Runners.qml declares SIX tool paths; the remaining
#      two (binMktemp, binRm) are covered by construction in check 2b below,
#      which requires every declared bin<Something> to be an absolute
#      literal. So nothing here is unguarded -- the list is a floor, not the
#      whole set, and it used to say "three" while checking four.
stripped_runners="$(strip_comments Runners.qml)"
for expected in /usr/bin/timeout /usr/bin/bash /usr/bin/hyprctl /usr/bin/setsid; do
  bin_pat="[\"']${expected}[\"']"
  grep -qE "$bin_pat" <<<"$stripped_runners" \
    && ok "Runners.qml names $expected absolutely" \
    || bad "Runners.qml names $expected absolutely" "not found"
done

# 2b -- EVERY tool path Runners.qml declares is absolute, whatever it is
#       called. This is the class-level answer to check 1's fixed list: a
#       binary added in some future task is covered the moment it is declared,
#       with nobody having to remember a list in a different file. Any
#       `property string bin<Something>: "..."` whose value does not start with
#       "/" is a hit; a value that is not a literal at all is also a hit,
#       because a computed tool path is exactly what this rule exists to
#       forbid.
#
#       THE ONE EXEMPTION, named here so it is argued rather than invisible,
#       the same way check 1 names uwsm-app. `binDir` is not a tool, it is the
#       plugin's own install directory, and it MUST be computed: the path
#       depends on where the user installed the plugin, which is not knowable
#       when this file is written. It is exempt BY NAME, so a future
#       `binSomething` that is computed still fails.
bin_exempt="binDir"
bin_props="$(grep -nE '(^|[^A-Za-z0-9_])property[[:space:]]+string[[:space:]]+bin[A-Za-z0-9_]*[[:space:]]*:' \
             <<<"$stripped_runners" || true)"
if [[ -z "$bin_props" ]]; then
  bad "Runners.qml: every declared bin* path is absolute" \
      "no 'property string bin<Name>:' declarations found at all -- the call helpers cannot be naming their tools"
else
  relative=""
  while IFS= read -r decl; do
    [[ -z "$decl" ]] && continue
    name="$(grep -oE 'bin[A-Za-z0-9_]*[[:space:]]*:' <<<"$decl" | head -1 | sed 's/[[:space:]]*:$//')"
    case " $bin_exempt " in *" $name "*) continue ;; esac
    grep -qE 'property[[:space:]]+string[[:space:]]+bin[A-Za-z0-9_]*[[:space:]]*:[[:space:]]*"/' <<<"$decl" \
      || relative="$relative
$decl"
  done <<<"$bin_props"
  relative="$(sed '/^$/d' <<<"$relative")"
  [[ -z "$relative" ]] && ok "Runners.qml: every declared bin* path is absolute" \
                       || bad "Runners.qml: every declared bin* path is absolute" "$relative"
fi

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

# 14 -- what Panel.qml itself declares, AND that the bodies do something.
#       `closeForPopoutSwitch` is not in the list: it comes from the base type
#       (which also clears the flag through Qt.callLater, better than the
#       override this file used to carry), while open/close/toggle are
#       overridden so opening can read the configuration first -- the shipped
#       idiom, clock/Panel.qml does exactly this. `counted` is this plugin's
#       own signal and BarWidget.qml connects to it.
#
#       DECLARED AND FORWARDING ARE TWO CLAIMS, checked separately. Commit
#       36886b7 closed this exact gap for the bar widget (check 12) one commit
#       before this file's Panel checks were written declares-only, so this is
#       the instance-not-class pattern reaching the same suite twice. An empty
#       `function close() { }` satisfies a declaration check perfectly, and the
#       panel would then never close -- it would also never open, because the
#       base type's `controller.show()` is the only route to the popup and an
#       override that does not call it replaces the working inherited body
#       with nothing.
for needed in "function open()" "function close()" "function toggle()" \
              "signal counted("; do
  grep -qF "$needed" <<<"$stripped_panel" \
    && ok "Panel declares $needed" \
    || bad "Panel declares $needed" "not found (comment-stripped)"
done

# open() and close() must reach the base type's controller -- that IS the
# popup, and an override that skips it silently disables the panel. toggle()
# reaches it through the other two, so it is allowed to name them instead
# (the same sibling allowance check 12 makes for the widget's toggle).
for fn in open close; do
  body="$(function_body "$stripped_panel" "$fn")"
  if [[ -z "$body" ]]; then
    bad "Panel: $fn() drives the base type's controller" "no 'function $fn(...) { ... }' block found"
  elif grep -qE '(^|[^A-Za-z0-9_])controller[[:space:]]*\.' <<<"$body"; then
    ok "Panel: $fn() drives the base type's controller"
  else
    bad "Panel: $fn() drives the base type's controller" \
        "the body never touches controller, so it replaces the working inherited body with nothing: $body"
  fi
done
toggle_body="$(function_body "$stripped_panel" toggle)"
if [[ -z "$toggle_body" ]]; then
  bad "Panel: toggle() reaches open() and close()" "no 'function toggle(...) { ... }' block found"
elif grep -qE '(^|[^A-Za-z0-9_])open[[:space:]]*\(' <<<"$toggle_body" \
     && grep -qE '(^|[^A-Za-z0-9_])close[[:space:]]*\(' <<<"$toggle_body"; then
  ok "Panel: toggle() reaches open() and close()"
else
  bad "Panel: toggle() reaches open() and close()" \
      "the body does not call both: $toggle_body"
fi

# A signal nobody emits is a signal the bar widget waits on forever: its
# tooltip would stay at the honest-but-permanent "Autostart Layout".
if grep -qE '(^|[^A-Za-z0-9_.])(root\.)?counted[[:space:]]*\(' \
     <<<"$(grep -v 'signal[[:space:]]\+counted' <<<"$stripped_panel")"; then
  ok "Panel: counted is actually emitted, not only declared"
else
  bad "Panel: counted is actually emitted, not only declared" \
      "no call to counted(...) anywhere outside its own signal declaration -- the bar widget's counts would never arrive"
fi

# 15 -- and what it must NOT declare.
#
#       THE MECHANISM, MEASURED, because the first version of this comment got
#       it wrong and an overstated comment has already cost this project two
#       defects. Redeclaring a property the base type provides is NOT an error:
#       offscreen qml, a stub base declaring `readonly property bool opened:
#       controller.open` and a derived component adding `property bool opened:
#       true`, exits 0 with nothing on either stream. What it does is SHADOW,
#       silently -- measured on that stub:
#         inherited            opened=true  controller.open=true  tracks=true
#         redeclared : true    opened=true  controller.open=false tracks=false
#         redeclared, no init  opened=false controller.open=true  tracks=false
#       So the cost is not an absent plugin, it is `opened` no longer tracking
#       `panelController.open`: the bar reads a value the panel does not mean,
#       Bar.findPanelWidget routes summon/hide by it, and nothing anywhere
#       reports a problem. Smaller than the old claim, and still worth a check
#       -- nothing in this project can execute a file that imports Quickshell,
#       so this is the only place that divergence can be caught.
#
#       The no-initializer form is included deliberately: the third measured
#       line above is the WORST of the three (the property reads false forever)
#       and the pattern used to require a colon, so it saw nothing.
inherited="opened popoutSwitchClosing popoutSwitching bar settings moduleName ipcTarget manageIpc controller"
redeclared=""
for member in $inherited; do
  hit="$(grep -nE "(^|[^A-Za-z0-9_])property[[:space:]]+[A-Za-z_][A-Za-z0-9_<>]*[[:space:]]+${member}([^A-Za-z0-9_]|\$)" \
         <<<"$stripped_panel" || true)"
  [[ -n "$hit" ]] && redeclared="$redeclared
$member: $hit"
done
redeclared="$(sed '/^$/d' <<<"$redeclared")"
[[ -z "$redeclared" ]] && ok "Panel redeclares none of the base type's members" \
                       || bad "Panel redeclares none of the base type's members" "$redeclared"

# 16 -- the popup surface exists, is wired to the injected anchor, AND has
#       something to give keyboard focus to.
#
#       Round 3 found this blind to two things it should have covered from the
#       start. `focusTarget` is how KeyboardPanel gets an active-focus target
#       inside the surface once it maps -- its own comment says layer-shell
#       grants the SURFACE focus but Qt still needs an item, so without it no
#       Keys handler ever fires and Escape does nothing. And the
#       `PanelKeyCatcher` was never required to exist at all, though it is what
#       owns Escape and Tab in this panel since the hand-rolled
#       Keys.onEscapePressed was removed.
#
#       focusTarget is origin-qualified rather than merely present: it has to
#       name an id this file actually declares a PanelKeyCatcher with, the same
#       way check 5b insists a helper call be qualified by the declared Runners
#       instance. Scoped to the KeyboardPanel's own block so a decoy elsewhere
#       cannot satisfy it.
keyboard_block="$(block_of "$stripped_panel" KeyboardPanel)"
if [[ -z "$keyboard_block" ]]; then
  bad "Panel: the KeyboardPanel surface is anchored, opened and focusable" \
      "no 'KeyboardPanel { ... }' block in Panel.qml -- the panel then has no window at all"
else
  surface_missing=""
  grep -qE '(^|[^A-Za-z0-9_.])anchorItem:[[:space:]]*root\.anchorItem([^A-Za-z0-9_]|$)' <<<"$keyboard_block" \
    || surface_missing="$surface_missing anchorItem:root.anchorItem"
  grep -qE '(^|[^A-Za-z0-9_.])open:[[:space:]]*root\.opened([^A-Za-z0-9_]|$)' <<<"$keyboard_block" \
    || surface_missing="$surface_missing open:root.opened"

  focus_id="$(grep -oE '(^|[^A-Za-z0-9_.])focusTarget:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' <<<"$keyboard_block" \
              | head -1 | sed -E 's/.*focusTarget:[[:space:]]*//')"
  if [[ -z "$focus_id" ]]; then
    surface_missing="$surface_missing focusTarget"
  else
    # The catcher's OWN id, not any id in its subtree. A first version asked
    # only whether "id: <focusTarget>" appeared anywhere inside the
    # PanelKeyCatcher block -- and the ScrollView is a CHILD of that block, so
    # `focusTarget: scrollArea` satisfied it while pointing keyboard focus at
    # a Flickable that fires none of the catcher's Keys handlers. Found by
    # mutation probe; the check was blind exactly the way the four it replaced
    # were. Same first-id-after-the-opener technique as runners_instance_id().
    catcher_id="$(awk '
        /(^|[^A-Za-z0-9_])PanelKeyCatcher[[:space:]]*\{/ { incatcher = 1 }
        incatcher && /id:[[:space:]]*[A-Za-z_]/ {
            match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
            t = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", t)
            print t; exit
        }
    ' <<<"$keyboard_block")"
    if [[ -z "$catcher_id" ]]; then
      surface_missing="$surface_missing PanelKeyCatcher-with-an-id"
    elif [[ "$focus_id" != "$catcher_id" ]]; then
      surface_missing="$surface_missing focusTarget($focus_id)-is-not-the-PanelKeyCatcher($catcher_id)"
    fi
  fi

  if [[ -z "$surface_missing" ]]; then
    ok "Panel: the KeyboardPanel surface is anchored, opened and focusable"
  else
    bad "Panel: the KeyboardPanel surface is anchored, opened and focusable" \
        "not wired inside the KeyboardPanel block:$surface_missing"
  fi
fi

# 16b -- and the key catcher yields while a field has focus, or typing is
#        swallowed. PanelKeyCatcher runs Keys.priority: Keys.BeforeItem, so it
#        takes keys even when a descendant has activeFocus: "x" in the Command
#        field would fire deleteRequested and "j" would never arrive. Its own
#        header prescribes `blocked: <editor>.activeFocus`; this panel has two
#        editors per expanded row, created by a Repeater, so the expression is
#        a count instead of a reference -- what is required here is that
#        `blocked` is bound to SOMETHING this file declares, never to a
#        literal, which is check 11's rule applied to the one binding that
#        decides whether the panel can be typed into at all.
if [[ -n "$keyboard_block" ]]; then
  blocked_rhs="$(grep -oE '(^|[^A-Za-z0-9_.])blocked:[[:space:]]*.*' <<<"$keyboard_block" \
                 | head -1 | sed -E 's/.*blocked:[[:space:]]*//')"
  if [[ -z "$blocked_rhs" ]]; then
    bad "Panel: the key catcher yields while a field has focus" \
        "no 'blocked:' binding inside the KeyboardPanel block -- Keys.BeforeItem would swallow every keystroke meant for a field"
  elif [[ "$blocked_rhs" =~ ^(true|false)\;?$ ]]; then
    bad "Panel: the key catcher yields while a field has focus" \
        "bound to the hardcoded literal '$blocked_rhs'"
  elif grep -qE "(^|[^A-Za-z0-9_])property[[:space:]]+[A-Za-z_][A-Za-z0-9_<>]*[[:space:]]+$(sed -E 's/^root\.//; s/[^A-Za-z0-9_].*$//' <<<"$blocked_rhs")([^A-Za-z0-9_]|\$)" \
         <<<"$stripped_panel"; then
    ok "Panel: the key catcher yields while a field has focus"
  else
    bad "Panel: the key catcher yields while a field has focus" \
        "expression '$blocked_rhs' names no property declared in this file"
  fi
fi

# 17 -- applying is explicit: a keystroke or a value change never persists or
#       moves anything. Moving real windows across real screens, and writing
#       the file, must be the consequence of a CLICK.
#
#       The first version named one handler (`onTextChanged`) and three needles
#       (`writeProc|applyRules|config-write`), which made it blind twice over:
#       blind to `root.apply()` -- the one entry point a careless refactor
#       would actually reach for -- and, once the fields moved to
#       `onTextEdited` in this very round, blind to the only handler they use.
#       A check naming the handler it was written against stops covering the
#       code the moment the code is edited.
#
#       So: every handler that fires from INPUT rather than from a deliberate
#       click is scanned, against every entry point that writes or dispatches.
#       onClicked and onPressed are deliberately NOT in the list -- the Apply
#       button's own `onClicked: root.apply()` is the correct shape and must
#       stay legal.
input_handlers='on(TextEdited|TextChanged|EditingFinished|Accepted|Changed|ValueChanged|Toggled|ActiveFocusChanged|Modified)'
persist_calls='(root\.)?(apply|applyRules|nextChunk|launchMissing)[[:space:]]*\(|writeProc|evalProc|launchProc|config-write'
hits=""
mapfile -t panel_all <<<"$stripped_panel"
for ((i = 0; i < ${#panel_all[@]}; i++)); do
  grep -qE "$input_handlers:" <<<"${panel_all[$i]}" || continue
  # A window, not the single line: a handler body may wrap onto the next few.
  window="${panel_all[$i]}"
  for ((k = 1; k <= 3; k++)); do
    (( i + k < ${#panel_all[@]} )) && window="$window
${panel_all[$((i + k))]}"
  done
  grep -qE "$persist_calls" <<<"$window" \
    && hits="$hits
Panel.qml:$((i + 1)): ${panel_all[$i]}"
done
hits="$(sed '/^$/d' <<<"$hits")"
[[ -z "$hits" ]] && ok "Panel: no input handler writes or dispatches" \
                 || bad "Panel: no input handler writes or dispatches" "$hits"

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

# 22 -- a reason code is never shown to the user raw. Every place Panel.qml
#       touches a `.reason` has to hand it to Model.reasonText, which is the
#       one function that turns a code into English and the one place a test
#       can check the wording exists at all.
#
#       This is the class-level half of round 2's defect. The instance was
#       that Model.js had no wording for "class-conflict"; the reason nobody
#       noticed for a round is that this file spelled the sentence out twice
#       BY HAND for the blocked channel and never called reasonText on it, so
#       the only place a reason becomes English was the only place that reason
#       never went. Wording duplicated into QML is wording no suite here can
#       reach -- nothing in this project can execute a file that imports
#       Quickshell.
#
#       Line-scoped with its neighbours, the same same-line-or-adjacent
#       idiom checks 6 and 9b already use for values that wrap. `.reasonText`
#       itself is excluded by the boundary so the call does not count as its
#       own subject.
reason_pat='\.reason([^A-Za-z0-9_]|$)'
raw_reasons=""
mapfile -t panel_lines <<<"$stripped_panel"
for ((i = 0; i < ${#panel_lines[@]}; i++)); do
  grep -qE "$reason_pat" <<<"${panel_lines[$i]}" || continue
  window="${panel_lines[$i]}"
  (( i > 0 )) && window="${panel_lines[$((i - 1))]}
$window"
  (( i + 1 < ${#panel_lines[@]} )) && window="$window
${panel_lines[$((i + 1))]}"
  grep -qF 'Model.reasonText(' <<<"$window" \
    || raw_reasons="$raw_reasons
Panel.qml:$((i + 1)): ${panel_lines[$i]}"
done
raw_reasons="$(sed '/^$/d' <<<"$raw_reasons")"
[[ -z "$raw_reasons" ]] && ok "Panel: every reason code is worded through Model.reasonText" \
                       || bad "Panel: every reason code is worded through Model.reasonText" "$raw_reasons"

# 23 -- an envelope error is never shown to the user raw either, for the same
#       reason and by the same rule as check 22. `explain()` lived in this file
#       for a round after reasonText was moved out of it, three of the config
#       helper's eight codes had no wording at all, and on empty stdout -- a
#       missing script, a timeout kill, an exit outside the script's own two
#       reporters -- it printed the literal text "undefined: ". Wording in QML
#       is wording no suite here can execute.
env_pat='envelope\.error'
raw_env=""
for ((i = 0; i < ${#panel_all[@]}; i++)); do
  grep -qE "$env_pat" <<<"${panel_all[$i]}" || continue
  window="${panel_all[$i]}"
  (( i > 0 )) && window="${panel_all[$((i - 1))]}
$window"
  (( i + 1 < ${#panel_all[@]} )) && window="$window
${panel_all[$((i + 1))]}"
  grep -qF 'Model.envelopeText(' <<<"$window" \
    || raw_env="$raw_env
Panel.qml:$((i + 1)): ${panel_all[$i]}"
done
raw_env="$(sed '/^$/d' <<<"$raw_env")"
[[ -z "$raw_env" ]] && ok "Panel: every envelope error is worded through Model.envelopeText" \
                    || bad "Panel: every envelope error is worded through Model.envelopeText" "$raw_env"

# 24/25 -- the fix for this task's worst defect, bound as a class.
#
#          THE DEFECT: collapsing a row while one of its fields has focus
#          clears no focus and fires no activeFocusChanged, so the focus
#          counter sticks above zero. Escape is then swallowed for the rest of
#          the open session, and -- worse -- the now-invisible field remains
#          the window's activeFocusItem, so keystrokes go on editing the draft
#          with Apply ready to persist them. Measured, offscreen qml, a stub of
#          Panel.qml's exact shape:
#            collapsed without the hand-over  editorsFocused=1 blocked=true  activeFocusItem=field1 fieldVisible=false
#            collapsed with it                editorsFocused=0 blocked=false activeFocusItem=keyCatcher
#
#          THE FIX was held by nothing at all: deleting the hand-over line
#          leaves all five suites AND qmllint green. Two checks bind it,
#          because either alone is insufficient -- the hand-over is only
#          reached if every collapse goes through the setter, and the setter is
#          only useful if the hand-over happens before the write.
#
#          Neither check can see whether focus actually moves at runtime; that
#          part is measured in the stub above and recorded in the task report,
#          not here. What these bind is the SHAPE the measurement was taken of.

# The line numbers a named function's brace-delimited body spans, so order
# inside it can be compared. Same brace-depth technique as function_body(),
# which returns the text but loses the positions.
function_line_range() {
  # $1 = comment-stripped content, $2 = function name. Prints "START END".
  awk -v fn="$2" '
    BEGIN { capturing = 0; depth = 0; started = 0; s = 0 }
    {
      if (!capturing) {
        if ($0 !~ "(^|[^A-Za-z0-9_])function[[:space:]]+" fn "[[:space:]]*\\(") next
        capturing = 1; depth = 0; started = 0; s = NR
      }
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "{") { depth++; started = 1 }
        else if (c == "}") {
          depth--
          if (started && depth <= 0) { print s " " NR; exit }
        }
      }
    }
  ' <<<"$1"
}

# The PanelKeyCatcher's own id, so the hand-over below is origin-qualified
# rather than merely a call to some forceActiveFocus. Same
# first-id-after-the-opener technique check 16 uses, on the same block.
panel_catcher_id="$(awk '
    /(^|[^A-Za-z0-9_])PanelKeyCatcher[[:space:]]*\{/ { incatcher = 1 }
    incatcher && /id:[[:space:]]*[A-Za-z_]/ {
        match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
        t = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", t)
        print t; exit
    }
' <<<"$keyboard_block")"

expanded_write_pat='(^|[^A-Za-z0-9_.])(root\.)?expandedRow[[:space:]]*=[[:space:]]*[^=]'
setter_range="$(function_line_range "$stripped_panel" setExpandedRow)"

# 24 -- the hand-over happens, on the key catcher, and BEFORE the write.
#       Order is the whole point: handing focus over after expandedRow has
#       already changed is handing it over after the field is gone, which is
#       the unfixed behaviour with an extra line in it.
if [[ -z "$setter_range" ]]; then
  bad "Panel: setExpandedRow hands focus to the key catcher before writing" \
      "no 'function setExpandedRow(...) { ... }' block found -- the collapse paths have nowhere to route through"
elif [[ -z "$panel_catcher_id" ]]; then
  bad "Panel: setExpandedRow hands focus to the key catcher before writing" \
      "no PanelKeyCatcher id could be read, so a hand-over cannot be qualified against it"
else
  setter_start="${setter_range%% *}"; setter_end="${setter_range##* }"
  handover_line=0; write_line=0
  for ((i = setter_start; i <= setter_end; i++)); do
    line="${panel_all[$((i - 1))]}"
    if (( handover_line == 0 )) \
       && grep -qE "(^|[^A-Za-z0-9_])${panel_catcher_id}[[:space:]]*\.[[:space:]]*forceActiveFocus[[:space:]]*\(" <<<"$line"; then
      handover_line=$i
    fi
    if (( write_line == 0 )) && grep -qE "$expanded_write_pat" <<<"$line"; then
      write_line=$i
    fi
  done
  if (( handover_line == 0 )); then
    bad "Panel: setExpandedRow hands focus to the key catcher before writing" \
        "no '${panel_catcher_id}.forceActiveFocus()' inside setExpandedRow -- collapsing then strands focus on an invisible field and blocks Escape for the session"
  elif (( write_line == 0 )); then
    bad "Panel: setExpandedRow hands focus to the key catcher before writing" \
        "setExpandedRow never writes expandedRow at all"
  elif (( handover_line < write_line )); then
    ok "Panel: setExpandedRow hands focus to the key catcher before writing"
  else
    bad "Panel: setExpandedRow hands focus to the key catcher before writing" \
        "the hand-over is on line $handover_line and the write on line $write_line -- after the write the field is already gone, which is the unfixed behaviour with an extra line in it"
  fi
fi

# 25 -- and it is the ONLY write site. This is what makes check 24 sufficient:
#       a direct assignment anywhere else bypasses the hand-over completely,
#       and there were five such sites before this round (close, removeProgram,
#       reload, revert, and the two row buttons) -- routing them through the
#       setter is the entire reason the fix reaches every collapse.
write_sites=""
for ((i = 0; i < ${#panel_all[@]}; i++)); do
  grep -qE "$expanded_write_pat" <<<"${panel_all[$i]}" || continue
  write_sites="$write_sites
$((i + 1)): ${panel_all[$i]}"
done
write_sites="$(sed '/^$/d' <<<"$write_sites")"
site_count=0
[[ -n "$write_sites" ]] && site_count="$(grep -c . <<<"$write_sites")"
if (( site_count != 1 )); then
  bad "Panel: expandedRow has exactly one write site, inside setExpandedRow" \
      "found $site_count write site(s); every one outside the setter bypasses the focus hand-over:$write_sites"
elif [[ -z "$setter_range" ]]; then
  bad "Panel: expandedRow has exactly one write site, inside setExpandedRow" \
      "the single write site cannot be placed: no setExpandedRow block found"
else
  only_line="${write_sites%%:*}"
  only_line="$(tr -d '[:space:]' <<<"$only_line")"
  if (( only_line >= ${setter_range%% *} && only_line <= ${setter_range##* } )); then
    ok "Panel: expandedRow has exactly one write site, inside setExpandedRow"
  else
    bad "Panel: expandedRow has exactly one write site, inside setExpandedRow" \
        "the write is on line $only_line, outside setExpandedRow (lines $setter_range) -- it bypasses the focus hand-over"
  fi
fi

# 26 -- the truncation marker Panel.qml watches for is the text Runners.qml
#       actually writes.
#
#       Runners.qml catches the producer's SIGPIPE (141) and turns it into a
#       success, because output past the cap is truncation and not failure --
#       and it says so on stderr. Panel.qml's appsProc collects that stream and
#       recognises the announcement by substring, which is what lets it tell
#       "the list was too long" from "the list was broken". Reword the marker in
#       one file and the recognition in the other stops working: the panel would
#       go back to reporting a merely-long list as broken, with every suite
#       green -- there is no runtime here to notice.
#
#       Both sides are checked against ONE literal named here, comment-stripped
#       like everything else in this file, so a comment quoting the marker
#       cannot stand in for either the writer or the reader.
truncation_marker="producer output exceeded the cap"
marker_missing=""
grep -qF "$truncation_marker" <<<"$stripped_runners" \
  || marker_missing="$marker_missing Runners.qml(writer)"
grep -qF "$truncation_marker" <<<"$stripped_panel" \
  || marker_missing="$marker_missing Panel.qml(reader)"
if [[ -z "$marker_missing" ]]; then
  ok "the truncation marker is the same text in the file that writes it and the file that reads it"
else
  bad "the truncation marker is the same text in the file that writes it and the file that reads it" \
      "the literal '$truncation_marker' is absent from:$marker_missing -- a reworded marker stops being recognised and a merely-long application list is reported as broken"
fi

# --- THE LAUNCH ROUTE ------------------------------------------------------
#
# THE GAP THIS CLOSES, measured by the final review: swapping
# `run.launcher(` for `run.runner(` at Service.qml's launch site left ALL
# FIVE suites green -- 70 structural, 6 runner-shape, 213 shell -- and kills
# the user's programs 120 s after login. `--foreground`, `setsid -f` and the
# `bash -n` gate appeared in NO test in this repository. They are the three
# measured fixes that keep a launched program alive past `timeout`'s deadline
# and past a Quickshell Process teardown, and the wrapper carrying them is
# duplicated verbatim in two files with nothing binding the copies.
#
# Read through the comment-stripped view like everything else here, and
# scoped to the launch FUNCTION rather than to the file, so a mention
# anywhere else cannot stand in for the call that actually launches.

# The body of one function, from its header to the line that starts the
# process, on the comment-stripped view.
launch_block() {
  local file="$1" start="$2"
  strip_comments "$file" \
    | awk -v start="$start" '
        $0 ~ start { inb = 1 }
        inb { print }
        inb && /launchProc\.running[[:space:]]*=[[:space:]]*true/ { exit }'
}

for pair in "Service.qml:function launchAll" "Panel.qml:function launchMissing"; do
  lf="${pair%%:*}"; lstart="${pair#*:}"
  block="$(launch_block "$lf" "$lstart")"

  if [[ -z "$block" ]]; then
    bad "$lf: the launch function was found at all" \
        "no block between '$lstart' and 'launchProc.running = true' -- every check below would have been vacuous"
    continue
  fi
  ok "$lf: the launch function was found at all"

  # 1. The route. run.runner() lets GNU timeout put its child in a new
  #    process group and signal the WHOLE group at the deadline; measured,
  #    0 of 2 backgrounded grandchildren survived without --foreground.
  if grep -qE 'launchProc\.command[[:space:]]*=[[:space:]]*run\.launcher\(' <<<"$block"; then
    ok "$lf: the launch goes through run.launcher()"
  else
    bad "$lf: the launch goes through run.launcher()" \
        "no 'launchProc.command = run.launcher(' in the launch function: $block"
  fi

  # 2. And not through the plain runner, which is the exact one-word swap
  #    that killed the programs and stayed green.
  if grep -qE 'run\.runner\(' <<<"$block"; then
    bad "$lf: the launch does NOT go through run.runner()" \
        "run.runner( appears inside the launch function -- that is the swap that kills every launched program at timeout's deadline"
  else
    ok "$lf: the launch does NOT go through run.runner()"
  fi

  # 3. Each entry detached, so a teardown of this Process
  #    (Component.onDestruction, or a superseded generation) cannot reach
  #    the programs either. --foreground alone does not cover that.
  if grep -qE 'binSetsid[[:space:]]*\+[[:space:]]*"[[:space:]]*-f[[:space:]]*"' <<<"$block"; then
    ok "$lf: each launched entry is detached with setsid -f"
  else
    bad "$lf: each launched entry is detached with setsid -f" \
        "no 'binSetsid + \" -f \"' in the launch function -- a Process teardown then reaches the launched programs"
  fi

  # 4. The parse gate. Closing the entry's stdio also closes the only
  #    channel on which it could report a syntax error, and Model.validate
  #    accepts an unbalanced quote (a shell-syntax problem, not a
  #    field-shape one). Without the gate the failure is silent.
  if grep -qE 'binBash[[:space:]]*\+[[:space:]]*"[[:space:]]*-n[[:space:]]+-c[[:space:]]*"' <<<"$block"; then
    ok "$lf: each entry is gated by a bash -n parse check"
  else
    bad "$lf: each entry is gated by a bash -n parse check" \
        "no 'binBash + \" -n -c \"' in the launch function -- a malformed command line then fails with nothing on any stream"
  fi
done

# The class-level answer to the two file-scoped blocks above: a THIRD launch
# site added in some future task is covered the moment it assigns
# launchProc.command, with nobody having to remember to extend a list here.
# Every such assignment in any qml file must name run.launcher().
launch_assign="$(grep_stripped_all 'launchProc\.command[[:space:]]*=' || true)"
launch_bad="$(grep -vE 'run\.launcher\(' <<<"$launch_assign" | sed '/^$/d' || true)"
launch_count="$(grep -c . <<<"$launch_assign" || true)"
if [[ "$launch_count" -lt 2 ]]; then
  bad "every launchProc.command assignment goes through run.launcher()" \
      "found $launch_count assignment(s); there are two launch sites (Service.qml, Panel.qml), so the discovery pattern is broken and this check proves nothing"
elif [[ -n "$launch_bad" ]]; then
  bad "every launchProc.command assignment goes through run.launcher()" "$launch_bad"
else
  ok "every launchProc.command assignment goes through run.launcher() ($launch_count sites)"
fi

# --foreground itself, in the helper the two sites above go through. Grepping
# it over test/ returned no hits before this block existed.
launcher_body="$(awk '/function[[:space:]]+launcher[[:space:]]*\(/ {inb=1} inb {print} inb && /^[[:space:]]*}/ && !/function/ {exit}' <<<"$stripped_runners")"
runner_body="$(awk '/function[[:space:]]+runner[[:space:]]*\(/ {inb=1} inb {print} inb && /^[[:space:]]*}/ && !/function/ {exit}' <<<"$stripped_runners")"
if grep -qF -- '--foreground' <<<"$launcher_body"; then
  ok "Runners.qml: launcher() passes --foreground to timeout"
else
  bad "Runners.qml: launcher() passes --foreground to timeout" \
      "not in the launcher() body: $launcher_body -- without it timeout signals the whole process group at the deadline and every launched program dies with it"
fi
# The two helpers must stay distinguishable: if runner() also carried
# --foreground, a launch site swapped onto runner() would look harmless here.
if grep -qF -- '--foreground' <<<"$runner_body"; then
  bad "Runners.qml: runner() is the plain route and does NOT pass --foreground" \
      "runner() carries --foreground, so the launcher/runner distinction the launch checks rely on no longer exists: $runner_body"
else
  ok "Runners.qml: runner() is the plain route and does NOT pass --foreground"
fi

stripped_service="$(strip_comments Service.qml)"

# --- the two appliers must judge hyprctl the same way ----------------------
#
# Service.qml and Panel.qml send the SAME payload through the SAME run.hypr()
# helper. Panel.qml used to read only exitCode while Service.qml also required
# the answer "ok", which made the interactive path -- the one where the user
# pressed Apply and is watching -- the weaker of the two. Bound across both
# files against one literal, comment-stripped, so a comment saying the right
# thing cannot stand in for either check.
ok_missing=""
grep -qE '!==[[:space:]]*"ok"' <<<"$stripped_service" || ok_missing="$ok_missing Service.qml"
grep -qE '!==[[:space:]]*"ok"' <<<"$stripped_panel"   || ok_missing="$ok_missing Panel.qml"
if [[ -z "$ok_missing" ]]; then
  ok "both appliers require hyprctl's \"ok\", not just a zero exit"
else
  bad "both appliers require hyprctl's \"ok\", not just a zero exit" \
      "the '!== \"ok\"' check is absent from:$ok_missing -- a chunk hyprctl refused then reads as applied on that path"
fi

# --- no second copy of a Model.js bound in Panel.qml ------------------------
#
# Panel.qml's own header declares that every derivation lives in Model.js.
# workspaceOptions() restated MAX_WORKSPACES as a bare 99, which is the copy
# that drifts silently: the picker would offer a number validate() rejects, or
# stop offering one it accepts.
ws_opts="$(awk '/function[[:space:]]+workspaceOptions[[:space:]]*\(/ {inb=1} inb {print} inb && /^[[:space:]]*}/ && !/function/ {exit}' <<<"$stripped_panel")"
if [[ -z "$ws_opts" ]]; then
  bad "Panel.qml: workspaceOptions takes its bound from Model, not a literal" \
      "workspaceOptions() was not found at all, so this check would have been vacuous"
elif ! grep -qF 'Model.MAX_WORKSPACES' <<<"$ws_opts"; then
  bad "Panel.qml: workspaceOptions takes its bound from Model, not a literal" \
      "no Model.MAX_WORKSPACES in workspaceOptions(): $ws_opts"
elif grep -qE '(^|[^A-Za-z0-9_.])99([^A-Za-z0-9_]|$)' <<<"$ws_opts"; then
  bad "Panel.qml: workspaceOptions takes its bound from Model, not a literal" \
      "a bare 99 is still in workspaceOptions(), so the bound exists twice: $ws_opts"
else
  ok "Panel.qml: workspaceOptions takes its bound from Model, not a literal"
fi

printf '\nqml structure: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
