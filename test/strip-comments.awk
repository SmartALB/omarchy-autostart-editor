# Comment-stripped view of a QML/JS source file, used by test/qml-structure.sh
# so a comment can never satisfy a check meant for code. Quote-aware and
# escape-aware, not a blunt "//.*" truncation: a backslash-prefixed character
# (\", \', \`, \/, ...) is always consumed as one atomic unit before anything
# else is checked, whether or not we are currently inside a string. That
# single rule does two jobs at once -- it keeps an escaped quote from ending
# a string early, and it keeps a "//" built from two escaped-slash halves (as
# in Runners.qml's own `/^file:\/\//` regex literal) from being misread as
# two adjacent, unescaped slashes.
#
# Three quote types are tracked: " and ', and ` -- a QML/JS template literal,
# which (unlike " and ') can legitimately span multiple lines, so quote state
# is deliberately NOT reset at the start of every line the way it was before
# this round: a "//" or a rule-construction call sitting inside an open
# multi-line template literal must stay invisible/visible exactly as it
# would inside a single-line string. /* ... */ block comments are tracked the
# same way, for the same reason -- a block comment can span lines too, and
# was not handled at all before this round.
#
# Only a "//" that is neither inside a string/template nor inside a block
# comment, and not built from escaped characters, starts a line comment; only
# a "/*" in that same "not already inside something" state starts a block
# comment. Everything from a line comment to the end of its line is dropped;
# everything from a block comment's "/*" to its closing "*/" (which may be
# many lines later) is dropped.
BEGIN {
  in_str = 0
  qc = ""
  in_block = 0
}
{
  line = $0
  out = ""
  i = 1
  n = length(line)
  while (i <= n) {
    c = substr(line, i, 1)

    if (in_block) {
      if (c == "*" && i < n && substr(line, i + 1, 1) == "/") {
        in_block = 0
        i += 2
      } else {
        i++
      }
      continue
    }

    if (c == "\\" && i < n) {
      out = out c substr(line, i + 1, 1)
      i += 2
      continue
    }

    if (in_str) {
      out = out c
      if (c == qc) in_str = 0
      i++
      continue
    }

    if (c == "/" && i < n && substr(line, i + 1, 1) == "*") {
      in_block = 1
      i += 2
      continue
    }
    if (c == "/" && i < n && substr(line, i + 1, 1) == "/") {
      break
    }
    if (c == "\"" || c == "'" || c == "`") {
      in_str = 1
      qc = c
      out = out c
      i++
      continue
    }

    out = out c
    i++
  }
  print out
}
