# Comment-stripped view of one QML/JS source line, used by
# test/qml-structure.sh so a comment can never satisfy a check meant for
# code. Quote-aware and escape-aware, not a blunt "//.*" truncation: a
# backslash-prefixed character (\", \', \/, ...) is always consumed as one
# atomic unit before anything else is checked, both inside and outside a
# string. That single rule does two jobs at once -- it keeps an escaped
# quote from ending a string early, and it keeps a "//" built from two
# escaped-slash halves (as in Runners.qml's `/^file:\/\//` regex literal)
# from being misread as two adjacent, unescaped slashes. Only a "//" that is
# neither inside a string nor built from escaped characters starts a
# comment, and everything from there to the end of the line is dropped.
{
  line = $0
  out = ""
  in_str = 0
  qc = ""
  i = 1
  n = length(line)
  while (i <= n) {
    c = substr(line, i, 1)
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
    if (c == "\"" || c == "'") {
      in_str = 1
      qc = c
      out = out c
      i++
      continue
    }
    if (c == "/" && i < n && substr(line, i + 1, 1) == "/") {
      break
    }
    out = out c
    i++
  }
  print out
}
