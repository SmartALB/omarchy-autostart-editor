// Autostart Editor -- all decision logic, plain JavaScript, no QML API.
// Kept free of QML imports so it can run headless in test/harness.qml.
//
// This plugin edits ONE file: ~/.config/hypr/autostart.lua. It reads that
// file, shows what it can represent of it, and writes one line of it at a
// time. It has no configuration of its own, applies nothing to the running
// compositor, and generates no Lua for `hyprctl eval`.
//
// THE ESCAPING BOUNDARY IS luaQuote, and it is the only one left. An earlier
// version of this plugin generated Lua chunks and handed them to
// `hyprctl eval`, and the defence there was luaBytes(): every value re-encoded
// as string.char(...) digits, so a quote or a brace in a window class could
// not be written down at all. That whole route is gone -- no chunks, no eval,
// no generated payload -- and with it luaBytes. What remains is one writer of
// one file, and its boundary is three things that hold together: the character
// allowlist in autostartCharRefused (a line break or a control character
// cannot be written at all), luaQuote's real escaping of the two characters a
// Lua literal can carry escaped, and the `luac5.1 -p` gate in
// bin/omarchy-autostart-hypr-write, which refuses a candidate file that does
// not compile. A readable literal is deliberate here: this file is
// hand-maintained by its owner, and string.char(110,105,109,98,117,115) in it
// would be safe and useless.

// THE BUILD, SHOWN IN THE PANEL so a user looking at two machines can tell
// which one is in front of them. That is the whole purpose, and it makes
// "the number shown is the number this build actually is" the requirement --
// a stale literal would defeat it entirely.
//
// WHY A LITERAL HERE AND NOT A READ OF manifest.json AT RUNTIME. Reading the
// installed manifest would make drift impossible by construction, and it was
// the first choice until two things ruled it out:
//
//   * the reading code would live in Panel.qml, which imports Quickshell.Io
//     and which NO suite in this project can execute. A read that silently
//     fails -- a path that does not resolve, JSON that does not parse, a
//     `loaded` signal that never fires -- shows an empty footer, on the very
//     machine where nothing is watching. This project has three recorded
//     defects of exactly that shape, all in code no suite could run: the
//     start marker that never claimed, `Process.NormalExit` evaluating to
//     undefined, and a two-argument handler on a one-argument signal.
//   * no plugin shipped with this platform reads its own manifest at runtime
//     (checked across /usr/share/omarchy/shell/plugins), so there is no
//     precedent to follow and `FileView` is exported in the installed type
//     information only as `FileViewInternal`.
//
// So the number is a literal in the ONE file every suite here can execute,
// and drift is refused where drift actually happens -- at release, in the
// repository: a shell assertion requires this to equal manifest.json's
// `version` exactly, in both directions, and three mutation probes bump each
// side on its own. Panel.qml spells no version at all; a structural check
// forbids a version-shaped literal there, so this cannot become the second
// source of truth it was written to avoid.
//
// AND BINDING THE REPOSITORY BINDS THE ARTIFACT, which is only true since
// `install` was fixed to replace the plugin directory rather than copy into
// it: the installed manifest.json and the installed Model.js are now provably
// from one source tree, asserted file-for-file by
// test_install_removes_what_the_plugin_no_longer_ships.
var VERSION        = "1.0.1";

// THE RUNNING-PROGRAMS PICKER, OFF BY REQUEST. One flag, one place, read
// exactly once in Panel.qml -- the shape Model.WRITE_PATH_ENABLED used for the
// cutover, and for the same reason: a feature switched off in several places
// is a feature nobody can switch back on with confidence.
//
// The user asked for it to be HIDDEN, not removed -- "das ist noch nicht so
// weit" -- so nothing is deleted: bin/omarchy-autostart-windows,
// autostartCandidatesForWindow and every assertion over the ranking, the
// unstable-path warning and the already-present check all stay exactly where
// they are. Turning this to true is the whole of bringing it back.
//
// WHAT IT GATES is the panel's "Running programs" button and the route behind
// it. TWO USES OF ONE READ, deliberately, and the second is the one that
// matters: this project's own rule -- written into test/qml-structure.sh when
// the cutover was checked -- is that a hidden control is NOT a closed route,
// because it has already shipped one gate that read as armed and was inert.
// So the route returns early as well, and a structural check requires the
// guard to come before the reads rather than beside them.
//
// WHAT STAYS REACHABLE while it is off: the installed-applications picker and
// typing a command by hand. Those are the two ways to add an entry now.
var RUNNING_PROGRAMS_ENABLED = false;

var MAX_NAME       = 100;
var MAX_COMMAND    = 500;

// Every code the bin/ helpers can answer with, across BOTH of them:
// bin/omarchy-autostart-hypr and bin/omarchy-autostart-hypr-write. Declared
// once so two halves can bind the class between them without either being a
// hand-copied claim: test/harness.qml requires every code IN HERE to have
// wording, and test/run-tests.sh derives THIS LIST from the two scripts and
// fails if one turns up without wording. Neither half alone would notice a
// code added to a script, and neither would notice wording quietly dropped.
//
// THREE OF THESE WERE UNWORDED UNTIL THE REMOVAL EXPOSED IT: the shell
// assertion read the deleted bin/omarchy-autostart-config and
// bin/omarchy-autostart-hypr, and never the writer -- so does-not-compile,
// is-a-symlink and no-lua-compiler reached the user through envelopeText's
// unknown-code fallback. Losing the config script is what made the writer the
// second emitter and put them in front of the assertion.
function envelopeCodes() {
    return ["does-not-compile", "insecure-permissions", "internal",
            "is-a-symlink", "no-lua-compiler", "not-a-file", "stale",
            "too-large", "unreadable", "write-failed"];
}

// Plain wording for the envelope the bin/ helpers answer with. Every code the
// reader and the writer can emit has a sentence here; a shell assertion in
// test/run-tests.sh derives the code list FROM BOTH SCRIPTS and fails if one
// turns up without wording, so a code added there cannot reach the user as a
// bare identifier.
//
// This lived in Panel.qml, and was moved for the reason every other wording
// function in this file was moved: wording in QML is wording no suite in this
// project can execute.
//
// THE EMPTY CASE IS EXPLICIT, and it is not hypothetical. Empty stdout is what
// a missing script, a timeout kill, and any non-zero exit taken outside the
// script's own two reporters all look like from here -- the QML version
// printed the literal text "undefined: " for all of them.
function envelopeText(code, detail) {
    var extra = (detail === undefined || detail === null || String(detail) === "")
                ? "" : " " + String(detail);
    if (code === undefined || code === null || String(code) === "")
        return "The helper gave no answer at all." + extra;
    if (code === "insecure-permissions")
        return "autostart.lua can be written by someone else, so it was not used."
             + " Make it writable only by you." + extra;
    if (code === "too-large")
        return "autostart.lua is too large for this panel to handle." + extra;
    if (code === "stale")
        return "The file changed on disk since the panel read it."
             + " Close and reopen the panel, then try again." + extra;
    if (code === "not-a-file")
        return "That path is not a regular file; a directory there is refused." + extra;
    if (code === "is-a-symlink")
        return "autostart.lua is a symlink, and this panel will not write through"
             + " one -- it would replace the link or the file at the other end of"
             + " it, and neither is what you asked for. Edit it by hand." + extra;
    if (code === "does-not-compile")
        return "The changed file did not compile as Lua, so nothing was written."
             + " Your file is exactly as it was." + extra;
    if (code === "no-lua-compiler")
        return "luac5.1 is not installed, so the changed file cannot be checked"
             + " before it is written -- and a file that runs at every login is"
             + " not written unchecked. Install lua51 (or luac5.1) and try again." + extra;
    if (code === "write-failed")
        return "autostart.lua could not be written, so nothing was changed." + extra;
    if (code === "internal")
        return "The helper could not build its answer." + extra;
    if (code === "unreadable")
        return "Your autostart.lua could not be read, so nothing is shown." + extra;
    // Named rather than shown bare -- the same rule every other wording
    // function in this file follows.
    return "The helper reported an unknown problem: " + String(code) + "." + extra;
}

// The build, as the panel's footer shows it. A "v" prefix and nothing else:
// this is a footnote, and a sentence around it would make it a heading.
//
// The empty case returns "" rather than a bare "v", and the footer binds its
// visibility on that -- showing "v" with no number would be worse than
// showing nothing, because the one thing this indicator must never do is
// look like it answered.
function versionText() {
    var v = String(VERSION === undefined || VERSION === null ? "" : VERSION);
    return v === "" ? "" : "v" + v;
}

// Remove the field codes of the desktop entry specification. %% is an escaped
// percent sign and becomes one; codes we do not know are left alone rather
// than guessed at, because a wrong guess produces a command that fails at
// login with no one watching.
//
// This does not track quoting, so a field code inside a quoted argument is
// stripped too (the freedesktop specification explicitly leaves that case
// undefined) and the whitespace collapse below can turn a double space
// inside a quoted argument into a single one. Accepted: the collapse is what
// cleans up the gap a removed code leaves behind, and a deliberate double
// space inside a quoted Exec= argument is essentially unheard of.
function stripFieldCodes(exec) {
    var known = Object.create(null);
    known["f"] = 1; known["F"] = 1; known["u"] = 1; known["U"] = 1;
    known["d"] = 1; known["D"] = 1; known["n"] = 1; known["N"] = 1;
    known["i"] = 1; known["c"] = 1; known["k"] = 1; known["v"] = 1; known["m"] = 1;
    var out = "", i = 0;
    while (i < exec.length) {
        if (exec.charAt(i) === "%" && i + 1 < exec.length) {
            var next = exec.charAt(i + 1);
            if (next === "%") { out += "%"; i += 2; continue; }
            if (known[next])  { i += 2; continue; }
        }
        out += exec.charAt(i);
        i += 1;
    }
    return out.replace(/\s+/g, " ").replace(/^ | $/g, "");
}

// The command line an installed application declares, cleaned of the desktop
// entry field codes. It had two callers -- the removed half's programFromApp
// and the autostart panel's application picker; the picker is the one left,
// and it fills the add field with what this returns.
//
// It is a GUESS -- Exec= is a command line for a file manager to run, not
// necessarily the one a user wants at login -- which is why the picker fills
// the field with it instead of writing it, and shows it beside the name.
function commandFromApp(app) {
    var source = app || {};
    return stripFieldCodes(String(source.exec === undefined ? "" : source.exec));
}

// What to tell the user about an application list that did not arrive whole.
//
// Two facts, three outcomes, and they are NOT interchangeable: "too long" is
// something a user can act on and "broken" is not, and the previous round
// could only say the second one because the panel threw away the marker that
// distinguishes them. "" means nothing went wrong and nothing is said.
//
// Here rather than in Panel.qml for the reason envelopeText is here: wording
// in QML is wording no suite in this project can execute, and this one is not
// merely wording -- it is a decision over two inputs.
//
// The substring Panel.qml looks for on stderr is Runners.qml's own truncation
// marker; test/qml-structure.sh binds those two files together so a reworded
// marker cannot silently stop being recognised.
function appsProblem(unparseable, truncated) {
    if (unparseable && truncated) {
        return "The list of installed applications is too long to read in full, so it"
             + " could not be used. Nothing else is affected.";
    }
    if (unparseable) {
        return "Could not read the list of installed applications.";
    }
    if (truncated) {
        // Parsed, but cut short: the picker works and is incomplete, which is a
        // third thing again -- saying "broken" here would be false and saying
        // nothing would leave an application mysteriously absent from the list.
        return "The list of installed applications was cut short, so an application"
             + " may be missing from it.";
    }
    return "";
}

// Single-quote for bash -c. Inside single quotes a shell metacharacter is
// inert; the only thing to handle is the quote itself.
function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

// The ONE consumer of this is the hand-over of the new file content to
// bin/omarchy-autostart-hypr-write on stdin. An unquoted expansion of a whole
// file's text into a shell command line is the one mistake here that would be
// catastrophic and silent, which is why the structural suite asserts the call
// site rather than trusting it.

// ==========================================================================
// THE READER FOR autostart.lua
// ==========================================================================
//
// One hand-maintained file, with German section comments and factual notes in
// it. This reader never writes; the writer below it does, one line at a time.
// What the reader must guarantee is the foundation that line surgery rests on:
//
//   * every entry carries `line` (1-based) and `raw` (the line verbatim),
//   * a line that calls a known helper in a form this code cannot take
//     apart is returned as an entry with editable:false and a filled `raw`
//     -- never guessed at, never silently dropped,
//   * a line that calls no known helper is not an entry at all. It stays
//     part of the file and is the writer's business, not the reader's.
//
// Parsing is LINE BY LINE. No regular expression here ever sees more than
// one line, and none of them nests a quantifier inside a quantifier: the
// input is a file this plugin does not own, and a parser that can be made
// to run for minutes over 31 lines is a defect, not a curiosity.
//
// The helpers are defined in /usr/share/omarchy/default/hypr/helpers.lua:
//   o.launch(c)            = "uwsm-app -- " .. c
//   o.exec_on_start(c)     runs c at hyprland.start
//   o.launch_on_start(c)   = o.exec_on_start(o.launch(c))
// which is why `o.launch_on_start("nimbus")` and
// `o.exec_on_start(o.launch("nimbus"))` are the SAME fact and are reported
// identically, with `launcher: "uwsm-app"`.

// ONE file. This was a list of three -- autostart.lua, windowrules.lua and
// workspaces.lua were all read and shown -- and it stays a LIST rather than a
// bare string for the reason parseHyprFiles still loops over it: the section
// shape the panel renders, and the "a file that is absent SAYS so" guarantee,
// are per-name and do not change because there is one name.
var HYPR_FILE_NAMES = ["autostart.lua"];

// A file this reader looks at is small and hand-written. The cap is here so
// that a pathological input costs a bounded amount of work rather than
// however much it feels like: the bin/ script already caps the bytes, this
// caps the lines it is worth turning into entries.
var MAX_HYPR_LINES = 2000;

// Why an entry could not be taken apart. Codes, never shown raw -- see
// hyprReasonText, and the same two-sided guarantee the envelope codes have:
// this list is what the parsers can set, and the harness proves every one of
// them has wording.
// FOUR CODES WERE DELETED WITH THE WINDOW-RULE AND WORKSPACE PARSERS --
// table-match, unsupported-option, missing-option and value-out-of-range.
// Nothing can produce them any more, and the harness assertion that every
// code here has wording would have gone on passing over all four: an
// assertion standing over something that no longer exists is how a suite
// starts proving nothing.
var HYPR_REASONS = [
    "nested-call",           // o.exec_on_start(o.launch_webapp_sole(...))
    "not-a-string",          // an argument that is not a plain Lua string
    "incomplete-call"        // the call does not end on this line
];

function hyprReasons() { return HYPR_REASONS.slice(); }

function hyprReasonText(code) {
    // THE EMPTY REASON, and it is the same defect envelopeText was fixed for:
    // falling through to the named-code fallback with nothing to name prints
    // the literal word "undefined" at the user. An entry can only reach the
    // panel with editable:false and a reason set, so this is a belt -- but it
    // is the belt whose absence was, once, the whole visible error message.
    if (code === undefined || code === null || String(code) === "") {
        return "This line cannot be represented by this panel, and no reason "
             + "was recorded for it.";
    }
    switch (code) {
    case "nested-call":
        return "This line wraps another helper call, which cannot be taken "
             + "apart into a command. It is shown exactly as it stands.";
    case "not-a-string":
        return "An argument on this line is not a plain quoted string, so it "
             + "cannot be read as a value.";
    case "incomplete-call":
        return "This call does not end on its own line; only whole one-line "
             + "calls can be read.";
    }
    return "This line cannot be represented by this panel: " + String(code) + ".";
}

// --- Lua string literals --------------------------------------------------
//
// Decoded, not copied. `"(nimbus-chatgpt\\.com__-Default)"` in the file is
// the characters `(nimbus-chatgpt\.com__-Default)` in the compositor, and
// that is what the panel has to show. The verbatim form is preserved
// anyway -- it is in `raw`.
//
// A character loop, not a regular expression. An escape-aware quoted-string
// regex is the classic place a nested quantifier goes quadratic, and this
// input is a file this plugin does not own.
//
// Returns { value: <decoded>, next: <index after the closing quote> } or
// null. Null means "this reader does not understand it", which upstream
// becomes editable:false -- never a guess.
var LUA_SIMPLE_ESCAPES = {
    "a": "\u0007", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
    "t": "\t", "v": "\u000b", "\\": "\\", "\"": "\"", "'": "'"
};

function luaStringAt(line, start) {
    var quote = line.charAt(start);
    if (quote !== "\"" && quote !== "'") return null;
    var out = "";
    var i = start + 1;
    while (i < line.length) {
        var c = line.charAt(i);
        if (c === quote) return { value: out, next: i + 1 };
        if (c !== "\\") { out += c; i += 1; continue; }
        // An escape. A backslash as the last character on the line is an
        // unterminated literal or Lua's line continuation -- neither is
        // something this reader claims to understand.
        if (i + 1 >= line.length) return null;
        var e = line.charAt(i + 1);
        if (LUA_SIMPLE_ESCAPES.hasOwnProperty(e)) {
            out += LUA_SIMPLE_ESCAPES[e];
            i += 2;
            continue;
        }
        if (e === "x") {
            var hex = line.substr(i + 2, 2);
            if (!/^[0-9A-Fa-f][0-9A-Fa-f]$/.test(hex)) return null;
            out += String.fromCharCode(parseInt(hex, 16));
            i += 4;
            continue;
        }
        if (e >= "0" && e <= "9") {
            // Up to three decimal digits, Lua's \ddd.
            var digits = "";
            var j = i + 1;
            while (j < line.length && digits.length < 3
                   && line.charAt(j) >= "0" && line.charAt(j) <= "9") {
                digits += line.charAt(j);
                j += 1;
            }
            var code = parseInt(digits, 10);
            if (code > 255) return null;
            out += String.fromCharCode(code);
            i = j;
            continue;
        }
        // \z (skip whitespace), or anything Lua itself would reject.
        return null;
    }
    // Ran off the end of the line without a closing quote.
    return null;
}

// The whole of `text` as one Lua string, or null.
function luaStringWhole(text) {
    var s = String(text);
    var parsed = luaStringAt(s, 0);
    if (!parsed) return null;
    if (parsed.next !== s.length) return null;
    return parsed.value;
}

// --- the shape every line goes through ------------------------------------
//
// A recognised helper call must be the WHOLE statement on its line: the
// opening parenthesis right after the name, the matching close at the end,
// and nothing after it but whitespace and at most one semicolon. Anything
// else -- a call continued on the next line, a trailing `-- note` after the
// code -- becomes an entry with editable:false rather than a rewrite that
// would eat the note.
//
// Returns { name, args, reason } or null. Null means the line calls nothing
// this reader knows, and a line like that is not an entry at all.
function hyprCallOnLine(line, names) {
    var s = String(line);
    var lead = /^[ \t]*/.exec(s)[0];
    var body = s.substring(lead.length);
    var name = null;
    for (var i = 0; i < names.length; i++) {
        var candidate = names[i];
        if (body.substring(0, candidate.length) !== candidate) continue;
        if (!/^[ \t]*\(/.test(body.substring(candidate.length))) continue;
        name = candidate;
        break;
    }
    if (name === null) return null;

    var afterName = body.substring(name.length);
    var inner = afterName.substring(afterName.indexOf("(") + 1);

    // Strip the trailing `)` plus an optional `;` and whitespace. Parentheses
    // are not balance-counted: what matters is that the statement ENDS here,
    // and a call that does not is reported as incomplete rather than
    // reconstructed. The `.*` is greedy and matches within one line only, so
    // the last `)` on the line is the one taken.
    var tail = /^(.*)\)[ \t]*;?[ \t]*$/.exec(inner);
    if (!tail) return { name: name, args: null, reason: "incomplete-call" };
    return { name: name, args: tail[1].replace(/^[ \t]+/, "").replace(/[ \t]+$/, ""),
             reason: null };
}

function hyprEntry(file, lineNumber, raw, name, kind) {
    return { file: file, line: lineNumber, raw: raw, fn: name, kind: kind,
             editable: false, reason: null };
}

// --- Lua long brackets, which is how a line can be code and yet not run ---
//
// A LINE-BY-LINE parser cannot see a comment that spans lines, and this one
// could not:
//
//     --[[
//     o.launch_on_start("nimbus")
//     ]]
//
// The middle line's text begins with a call this reader knows, so it came
// back as an editable entry -- a program the user had deliberately switched
// off, offered as one that is running. On its own that was a display defect.
// With the writer in place it is worse: changing that entry would rewrite a
// line inside a comment, and removing it would delete a line the user was
// keeping. Found in review of task 18 (finding 3), before any surgery
// shipped.
//
// Neither the user's three files nor Omarchy's entire default tree contains a
// single long bracket -- the reviewer grepped both -- so this is prevention,
// and its fixtures are constructed rather than found.
//
// The level of a long bracket at `at`, or -1 for none: `[[` is level 0,
// `[=[` is 1, `[==[` is 2, and the same shape with `]` closes it. Lua
// requires the closing level to MATCH, which is the whole point of the
// equals signs.
function hyprBracketLevelAt(line, at, bracket) {
    if (line.charAt(at) !== bracket) return -1;
    var i = at + 1, equals = 0;
    while (line.charAt(i) === "=") { equals += 1; i += 1; }
    if (line.charAt(i) !== bracket) return -1;
    return equals;
}

// For each line, whether it BEGINS inside a long bracket -- a block comment
// or a long string. Such a line is not code, so it is not an entry at all,
// exactly like a line starting with `--`.
//
// A character walk over the whole text, not a regular expression: this has
// to carry state across lines, and it has to skip quoted strings (a `"--[["`
// inside a string opens nothing) and stop at a line comment (a `--[[` after
// a `--` is comment text). Quoted strings are skipped with luaStringAt, the
// same scanner the value reader uses.
//
// FAIL-CLOSED where it cannot tell: a quoted string luaStringAt refuses is
// walked one character further rather than skipped, so an unterminated
// literal containing a bracket opener puts the reader INSIDE a bracket and
// the following lines become non-entries. An entry that disappears is
// visible in the panel and safe; an entry wrongly offered as editable is the
// defect this exists to close.
function hyprLineStartsInBracket(lines) {
    var flags = [];
    var level = -1;   // -1 = code; 0 and up = inside a bracket of that level
    for (var n = 0; n < lines.length; n++) {
        var line = String(lines[n]);
        flags.push(level >= 0);
        var i = 0;
        while (i < line.length) {
            if (level >= 0) {
                var closing = hyprBracketLevelAt(line, i, "]");
                if (closing === level) { level = -1; i += closing + 2; continue; }
                i += 1;
                continue;
            }
            var c = line.charAt(i);
            if (c === "\"" || c === "'") {
                var str = luaStringAt(line, i);
                i = str ? str.next : i + 1;
                continue;
            }
            if (c === "-" && line.charAt(i + 1) === "-") {
                var comment = hyprBracketLevelAt(line, i + 2, "[");
                if (comment >= 0) { level = comment; i += 4 + comment; continue; }
                break;   // a line comment: everything after it is comment text
            }
            var long_ = hyprBracketLevelAt(line, i, "[");
            if (long_ >= 0) { level = long_; i += 2 + long_; continue; }
            i += 1;
        }
    }
    return flags;
}

// Line splitting for all three parsers. `raw` is the element of THIS array
// at index line-1, which is the round-trip guarantee the writer rests on --
// comment lines and blank lines are counted like every other line, because a
// parser that skipped them would shift every entry below by however many it
// skipped.
function hyprLines(text) {
    return String(text === undefined || text === null ? "" : text).split("\n");
}

// --- autostart.lua --------------------------------------------------------
//
// Recognised, and reported as the SAME fact:
//   o.launch_on_start("notes-app")
//   o.exec_on_start(o.launch("notes-app"))     -- helpers.lua:118-120
// both give launcher "uwsm-app" and command "notes-app".
//
// Recognised as its own form:
//   o.exec_on_start("some-command")                  -- launcher "shell"
//
// Deliberately NOT editable, and this is the case the brief names:
//   o.exec_on_start(o.launch_webapp_sole("Chat", "https://chat.example.org/"))
// A nested two-argument helper whose result is a shell line built inside
// Lua. Showing it and refusing to rewrite it is the whole point.
var AUTOSTART_CALLS = ["o.launch_on_start", "o.exec_on_start"];

function parseAutostartLua(text, fileName) {
    var name = fileName || "autostart.lua";
    var lines = hyprLines(text);
    var inBracket = hyprLineStartsInBracket(lines);
    var entries = [];
    var limit = Math.min(lines.length, MAX_HYPR_LINES);
    for (var n = 0; n < limit; n++) {
        if (inBracket[n]) continue;   // inside a block comment or a long string
        var raw = lines[n];
        var call = hyprCallOnLine(raw, AUTOSTART_CALLS);
        if (!call) continue;
        var entry = hyprEntry(name, n + 1, raw, call.name, "autostart");
        if (call.reason) { entry.reason = call.reason; entries.push(entry); continue; }

        var direct = luaStringWhole(call.args);
        if (direct !== null) {
            entry.editable = true;
            entry.command = direct;
            entry.launcher = (call.name === "o.launch_on_start") ? "uwsm-app" : "shell";
            entries.push(entry);
            continue;
        }
        // The one nested form helpers.lua makes exactly equivalent.
        var wrapped = /^o\.launch[ \t]*\((.*)\)$/.exec(call.args);
        if (call.name === "o.exec_on_start" && wrapped) {
            var inner = luaStringWhole(wrapped[1].replace(/^[ \t]+/, "").replace(/[ \t]+$/, ""));
            if (inner !== null) {
                entry.editable = true;
                entry.command = inner;
                entry.launcher = "uwsm-app";
                entries.push(entry);
                continue;
            }
        }
        entry.reason = /^o\.[A-Za-z_]/.test(call.args) ? "nested-call" : "not-a-string";
        entries.push(entry);
    }
    return entries;
}

// The three sections, always in file order and always all three -- a file
// the reader did not find is a section that SAYS so, not a section that is
// missing. Takes the `files` array of the bin/omarchy-autostart-hypr
// envelope; it does no I/O of its own.
function parseHyprFiles(files) {
    var given = files || [];
    var byName = {};
    for (var i = 0; i < given.length; i++) {
        if (given[i] && given[i].name) byName[String(given[i].name)] = given[i];
    }
    var sections = [];
    for (var n = 0; n < HYPR_FILE_NAMES.length; n++) {
        var fileName = HYPR_FILE_NAMES[n];
        var f = byName[fileName] || {};
        var present = f.present === true;
        sections.push({
            name: fileName,
            path: String(f.path || ""),
            present: present,
            truncated: f.truncated === true,
            mtime: Number(f.mtime || 0),
            lineCount: present ? hyprLines(f.content).length : 0,
            // THE BYTES, carried through verbatim. autostartApply() needs the
            // text it is doing surgery on, and the only text it may use is the
            // one the entries' `line` and `raw` were derived from -- taking
            // the file's content from a second read would be taking it from a
            // possibly different file. An absent file has no content, and ""
            // is not the same claim as "the file is empty": `present` is what
            // says which.
            content: present ? String(f.content || "") : "",
            // parseAutostartLua by name and not through a lookup table: there
            // is one parser, and a table of one entry is a table whose lookup
            // can only ever answer one way.
            entries: present ? parseAutostartLua(String(f.content || ""), fileName) : []
        });
    }
    return sections;
}

function hyprEditableCount(sections) {
    var total = 0;
    for (var i = 0; i < (sections || []).length; i++) {
        var entries = sections[i].entries || [];
        for (var j = 0; j < entries.length; j++) if (entries[j].editable) total += 1;
    }
    return total;
}

// The section by name, or null. The panel asks for "autostart.lua" by the
// name in HYPR_FILE_NAMES rather than by an index, because the order of the
// sections is parseHyprFiles' business and not the panel's.
function hyprSectionNamed(sections, name) {
    var list = sections || [];
    for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].name) === String(name)) return list[i];
    }
    return null;
}

// Which section this plugin may WRITE. It is still a PREDICATE and not the
// tautology it now looks like: a section that is absent or truncated is not
// writable, because line surgery against a partial read would target line
// numbers the file does not have. The name comparison stays too -- the panel
// must not classify a section by its file name, which was finding 1 of the
// task 18 review, made in the one file no suite can execute.
function hyprSectionIsWritable(section) {
    var s = section || {};
    if (String(s.name) !== "autostart.lua") return false;
    if (s.present !== true) return false;
    if (s.truncated === true) return false;
    return true;
}

// The bar widget's ONE number: how many entries autostart.lua has. The
// second number was hyprPlacementCount, everything the other two files
// carried, and it is gone with them -- a tooltip saying "0 placements" would
// describe a feature that no longer exists.
function hyprProgramCount(sections) {
    var section = hyprSectionNamed(sections, "autostart.lua");
    return section ? (section.entries || []).length : 0;
}

// The one note under a section header, or "" when the section has nothing to
// say. Finding 2 of the task 18 review: these three sentences were written
// inline in Panel.qml, sixty lines under a comment forbidding exactly that,
// and so were the only sentences in that section the harness could not
// reach.
//
// The order is the order of severity: a file that is not there cannot be
// truncated, and a truncated file's entry list is not the whole file's.
function hyprSectionNoteText(section) {
    var s = section || {};
    if (s.present !== true) return "Not found: " + String(s.path === undefined ? "" : s.path);
    if (s.truncated === true) {
        return "This file is larger than this panel reads; what is shown is "
             + "the beginning of it.";
    }
    if ((s.entries || []).length === 0) {
        return "No line in this file is one this panel recognises.";
    }
    return "";
}

// What the autostart section says about itself: how many of its entries this
// panel can edit, and -- when any cannot -- that they are left alone. The
// second half is the honest naming of the one real limitation of this task,
// and hyprEditableCount is what measures it.
function hyprAutostartNoteText(sections) {
    var section = hyprSectionNamed(sections, "autostart.lua");
    if (!section || section.present !== true) return "";
    var entries = section.entries || [];
    if (entries.length === 0) return "";
    var editable = hyprEditableCount([section]);
    var text = editable + " of " + entries.length + " entries can be changed or "
             + "removed here.";
    if (editable < entries.length) {
        text += " The rest are shown as they stand and left alone -- edit "
              + "autostart.lua by hand for those.";
    }
    return text;
}

// The one line in the head of the panel: which file this edits, and whether
// it was actually read. It named three files and said which of them was read
// only; there is one now, and it is the writable one.
//
// The absent case is still spelled out rather than left to an empty list. A
// user whose autostart.lua does not exist must be told that, not shown an
// empty panel -- and this plugin does not create the file, because a file that
// runs at every login is not brought into existence by a panel the user opened
// to look at it.
function hyprHeaderText(sections) {
    var list = sections || [];
    var read = [], absent = [];
    for (var i = 0; i < list.length; i++) {
        if (list[i].present) {
            read.push(list[i].name + " (" + (list[i].entries || []).length + ")");
        } else {
            absent.push(list[i].name);
        }
    }
    var text = "This panel edits your autostart.lua and nothing else. ";
    text += (read.length === 0) ? "No file was read."
                                : "Read: " + read.join(", ") + ".";
    if (absent.length > 0) text += " Not found: " + absent.join(", ") + ".";
    return text;
}

// One entry as one line of text. A non-editable entry is shown by its RAW
// line and nothing else -- there is no reading of it to offer, and inventing
// one is the failure this whole task exists to avoid.
//
// NO LINE NUMBER. Every return path used to begin with "<n>: ", and the
// entries are simply listed one under another now. The number carried
// bookkeeping rather than information: the panel is a list of what starts
// with the session, not a concordance of a file the user can open themselves.
//
// THE NUMBER IS STILL IN THE DATA, and nothing about that changed. It is what
// autostartApply targets, what the panel's autostartEditLine keys on, and
// what oneLineDifference proves a write touched exactly one of. Only the
// DISPLAY dropped it, and no assertion about the surgery reads the displayed
// text: the round-trip proof compares `raw` against the input line, and
// lineNumbersOf pins the numbers themselves.
//
// The two things that are NOT numbers stay, because they carry information a
// reader cannot get otherwise: the "(shell)" marker, which says an entry runs
// through o.exec_on_start rather than the uwsm-app launcher, and -- for a
// non-editable entry -- the raw line, which is the only honest thing to show
// for a form this reader cannot take apart.
function hyprEntryText(entry) {
    var e = entry || {};
    if (!e.editable) return String(e.raw === undefined ? "" : e.raw);
    if (e.kind === "autostart") {
        return String(e.command) + (e.launcher === "uwsm-app" ? "" : "  (shell)");
    }
    // A kind this function does not know falls through to the raw line, which
    // is the same answer a non-editable entry gets: the line as it stands,
    // never an invention. The "window" and "workspace" branches that stood
    // here are gone with their parsers.
    return String(e.raw === undefined ? "" : e.raw);
}

// ==========================================================================
// WRITING autostart.lua
// ==========================================================================
//
// The write half of the reader above, and it lives here for one reason: the
// new file content is produced by a PURE FUNCTION -- old text plus one
// operation gives new text, no file I/O, no QML -- so every surgery case is
// a unit test with a byte-exact expected result in the one file this project
// can actually execute. bin/omarchy-autostart-hypr-write does the atomic
// write, the staleness check and the luac5.1 gate; it never reasons about
// content.
//
// THE FILE RUNS AT EVERY LOGIN. A malformed autostart.lua means the user's
// programs do not start and Hyprland reports a Lua error at the next login.
// That is why there are three operations and no more, why each of them
// touches exactly one line, and why anything that cannot be written back
// readably is refused rather than encoded.

// Every character a command may contain, expressed as the ones it may not.
//
// THIS FILE IS READ BY A PERSON: autostart.lua is hand-maintained, often
// carries the owner's own section comments, and
// `o.launch_on_start(string.char(110,105,109,98,117,115))` in it would be unusable
// even though it is safe -- which is what the removed `eval` route wrote,
// because nothing there was ever read by a person. So the writer emits a real
// Lua string literal, and pays for that legibility with an allowlist, because
// a literal cannot express a line break at all.
//
// Refused, and each of them for a reason that is about the FILE, not about
// taste:
//   < 0x20        a line break, a carriage return, a tab, a NUL -- a literal
//                 cannot carry them, and a line break would end the
//                 statement mid-string
//   0x7F          DEL
//   0x80 - 0x9F   the C1 controls, invisible in an editor
//   U+2028/2029   Unicode line separators, invisible and line-break-shaped
// Everything else passes, including non-ASCII text: a path with an umlaut in
// it is written as its own bytes and read back as the same characters.
function autostartCharRefused(code) {
    if (code < 0x20) return true;
    if (code === 0x7F) return true;
    if (code >= 0x80 && code <= 0x9F) return true;
    if (code === 0x2028 || code === 0x2029) return true;
    return false;
}

// A real Lua string literal: `\\` and `\"`, and nothing else.
//
// It THROWS on a character the allowlist refuses rather than returning
// something, and that is deliberate: a caller that forgot to ask
// autostartCommandRefusal() first cannot smuggle a line break into the file
// by not checking; it gets an exception instead.
//
// The two escapes are spelled through BACKSLASH and QUOTE rather than as
// backslash-heavy literals. Two reasons, and neither is taste: a reader can
// see which branch does what without counting backslashes, and a mutation
// probe can address exactly ONE of the two -- with both branches written as
// literals the two lines are indistinguishable to any pattern short of a
// line number, and a probe that cannot name one guard cannot prove it holds.
var BACKSLASH = "\\";
var QUOTE = "\"";

function luaQuote(s) {
    var text = String(s);
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i);
        if (autostartCharRefused(code)) {
            throw new Error("luaQuote: character not writable as a Lua string literal "
                            + "at index " + i + ": code " + code);
        }
        var c = text.charAt(i);
        if (c === BACKSLASH) { out += BACKSLASH + BACKSLASH; continue; }
        if (c === QUOTE) { out += BACKSLASH + QUOTE; continue; }
        out += c;
    }
    return QUOTE + out + QUOTE;
}

// The one line shape this writer emits, in the style the file already uses:
//   o.launch_on_start("<command>")
// No indentation, no trailing semicolon, no comment -- exactly what
// parseAutostartLua reads back as an editable entry with launcher
// "uwsm-app". The round-trip assertion in the harness is what binds the two.
function autostartLine(command) {
    return "o.launch_on_start(" + luaQuote(command) + ")";
}

// Why an operation was refused. Codes, never shown raw -- see
// autostartWriteReasonText, and the same two-sided guarantee hyprReasons()
// has: this list is what autostartApply() can return, and the harness proves
// every one of them has wording.
var AUTOSTART_WRITE_REASONS = [
    "empty-command",         // nothing, or only spaces and tabs
    "command-too-long",      // past MAX_COMMAND
    "unwritable-character",  // see autostartCharRefused
    "no-entry-on-line",      // the line named holds no autostart entry
    "entry-not-editable",    // it holds one this reader cannot represent
    "file-too-long",         // more lines than the reader looks at
    "unknown-operation"      // not add, change or remove
];

function autostartWriteReasons() { return AUTOSTART_WRITE_REASONS.slice(); }

function autostartWriteReasonText(code) {
    if (code === undefined || code === null || String(code) === "") {
        return "This change was refused, and no reason was recorded for it.";
    }
    switch (code) {
    case "empty-command":
        return "A command line is needed -- this one is empty.";
    case "command-too-long":
        return "This command is longer than " + MAX_COMMAND + " characters, "
             + "which is more than this panel writes into your file.";
    case "unwritable-character":
        return "This command contains a line break or a control character, "
             + "which cannot be written into a Lua string. Shorten or retype "
             + "it, or edit the file by hand.";
    case "no-entry-on-line":
        return "There is no autostart entry on that line any more. Reopen the "
             + "panel so it reads your file again.";
    case "entry-not-editable":
        return "This line is one this panel cannot represent, so it is neither "
             + "changed nor removed. Edit autostart.lua by hand for it.";
    case "file-too-long":
        return "This file has more lines than this panel reads, so it will not "
             + "edit it.";
    case "unknown-operation":
        return "This panel does not know that operation.";
    }
    return "This change was refused: " + String(code) + ".";
}

// What the panel says after a successful write, and it is the whole of what
// this task promises: the file changed, the desktop did not. No
// `hyprctl reload`, nothing evaluated, nothing started, nothing killed.
function autostartWrittenText() {
    return "Written. This takes effect at your next login -- this panel "
         + "starts nothing and reloads nothing.";
}

// The content lines of a file. `hyprLines` splits on "\n", so a file that
// ends with a newline -- as a hand-written Lua file does, and it is the
// convention this writer keeps -- yields a trailing empty element that is
// NOT a line. Dropping
// exactly one of them is what makes "the file gained one line" mean what it
// says, here and in oneLineDifference().
function autostartContentLines(text) {
    var lines = hyprLines(text);
    if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    return lines;
}

// Content lines back to file text, always terminated by exactly one "\n" --
// the file's own convention, and no blank line at the end. An empty list gives
// an empty file rather than a lone newline.
function autostartJoinLines(lines) {
    if (lines.length === 0) return "";
    return lines.join("\n") + "\n";
}

// Is a command writable at all? null when it is, a reason code when it is
// not. Nothing is trimmed or repaired: a command this refuses is refused,
// with a sentence that says why, rather than quietly turned into a different
// command than the one the user typed.
function autostartCommandRefusal(command) {
    var text = String(command === undefined || command === null ? "" : command);
    if (/^[ \t]*$/.test(text)) return "empty-command";
    if (text.length > MAX_COMMAND) return "command-too-long";
    for (var i = 0; i < text.length; i++) {
        if (autostartCharRefused(text.charCodeAt(i))) return "unwritable-character";
    }
    return null;
}

// THE PURE FUNCTION. Old text plus one operation gives new text.
//
//   { action: "add",    command: "<command line>" }
//   { action: "change", line: <1-based>, command: "<command line>" }
//   { action: "remove", line: <1-based> }
//
// Returns { ok: true, text: <new file text> } or { ok: false, error: <code> }.
//
// Exactly one line changes. Add appends one as the LAST line -- no section
// detection, nothing sorted into a "matching" comment block, because
// guessing which of the file's own section comments a new program belongs under
// is exactly the kind of surprise this design exists to avoid. Change
// replaces the line named and no other. Remove deletes the line named and no
// other.
//
// Change and remove re-read the text they were handed and refuse anything
// but an editable autostart entry on that line. That refusal is the one the
// brief names: `o.exec_on_start(o.launch_webapp_sole("Chat", ...))` is
// SHOWN, and neither changed nor removed, because the plugin does not touch
// what it cannot represent.
function autostartApply(text, op) {
    var source = String(text === undefined || text === null ? "" : text);
    var operation = op || {};
    var action = String(operation.action === undefined ? "" : operation.action);
    var lines = autostartContentLines(source);
    if (lines.length > MAX_HYPR_LINES) return { ok: false, error: "file-too-long" };

    if (action === "add") {
        var refusal = autostartCommandRefusal(operation.command);
        if (refusal) return { ok: false, error: refusal };
        var appended = lines.slice();
        appended.push(autostartLine(String(operation.command)));
        return { ok: true, text: autostartJoinLines(appended) };
    }

    if (action !== "change" && action !== "remove") {
        return { ok: false, error: "unknown-operation" };
    }

    // The line has to be an editable autostart entry of THIS text. Parsing
    // it again here rather than trusting a `line` the caller carried over
    // from an older read is the point: the panel's entry list can be stale,
    // and a stale line number is how a rewrite lands on the wrong line.
    var wanted = Number(operation.line);
    if (!isFinite(wanted) || Math.floor(wanted) !== wanted
        || wanted < 1 || wanted > lines.length) {
        return { ok: false, error: "no-entry-on-line" };
    }
    var entries = parseAutostartLua(source, "autostart.lua");
    var found = null;
    for (var i = 0; i < entries.length; i++) {
        if (entries[i].line === wanted) { found = entries[i]; break; }
    }
    if (found === null) return { ok: false, error: "no-entry-on-line" };
    if (found.editable !== true) return { ok: false, error: "entry-not-editable" };
    // The reader's own round-trip guarantee, asserted rather than assumed:
    // `raw` is the element of the split array at index line-1. If it ever
    // were not, the surgery below would rewrite a line the panel never
    // showed.
    if (found.raw !== lines[wanted - 1]) return { ok: false, error: "no-entry-on-line" };

    var out = lines.slice();
    if (action === "remove") {
        out.splice(wanted - 1, 1);
        return { ok: true, text: autostartJoinLines(out) };
    }
    var changeRefusal = autostartCommandRefusal(operation.command);
    if (changeRefusal) return { ok: false, error: changeRefusal };
    out[wanted - 1] = autostartLine(String(operation.command));
    return { ok: true, text: autostartJoinLines(out) };
}

// THE ONE-LINE ASSERTION, as a function rather than as a habit.
//
// "Looks right" is not the property; "old and new differ in exactly one
// line" is. Returns one of:
//   "same"           byte-identical content lines
//   "changed:<n>"    line n replaced, nothing else moved
//   "added:<n>"      one line inserted at n, everything else intact
//   "removed:<n>"    one line deleted at n, everything else intact
//   "multiple"       anything else, which is a defect in the writer
//
// Linear, not a diff: the three shapes above are the only ones autostartApply
// can produce, so each is checked for directly. A longest-common-subsequence
// pass would answer the same question at O(n*m) and would also happily
// report "one line" for two edits that happen to cancel out in its
// bookkeeping.
function oneLineDifference(oldText, newText) {
    var a = autostartContentLines(String(oldText === undefined || oldText === null ? "" : oldText));
    var b = autostartContentLines(String(newText === undefined || newText === null ? "" : newText));
    var i;
    if (a.length === b.length) {
        var at = -1;
        for (i = 0; i < a.length; i++) {
            if (a[i] === b[i]) continue;
            if (at !== -1) return "multiple";
            at = i;
        }
        return (at === -1) ? "same" : ("changed:" + (at + 1));
    }
    if (b.length === a.length + 1) {
        for (i = 0; i < a.length; i++) if (a[i] !== b[i]) break;
        for (var j = i; j < a.length; j++) if (a[j] !== b[j + 1]) return "multiple";
        return "added:" + (i + 1);
    }
    if (a.length === b.length + 1) {
        for (i = 0; i < b.length; i++) if (a[i] !== b[i]) break;
        for (var k = i; k < b.length; k++) if (a[k + 1] !== b[k]) return "multiple";
        return "removed:" + (i + 1);
    }
    return "multiple";
}

// --- FROM A RUNNING PROGRAM TO AN AUTOSTART COMMAND ------------------------
//
// A window has a CLASS, not a command. Measured on a real session, the gap
// between the two is not a rounding error, it is three distinct defects
// waiting to be written into a file that runs at every login:
//
//   com.example.modelbox  ->  /tmp/.mount_modelbFjMMHD/modelbox
//       An AppImage mount path. It changes at every start, so the entry is
//       dead at the next boot -- and looks perfectly right until then.
//   nimbus-browser
//   nimbus-mail.example.com__mail_-Default
//   nimbus-chat.example.org__-Default   ->  ONE command line, all three
//       Three windows of one process. /proc cannot say that the webmail
//       window needs `nimbus --app=https://mail.example.com/mail/`; worse,
//       the line it does report happens to END in that flag, so the plain
//       browser window reports a command that is actively wrong for it.
//   ~/.local/share/applications/Webmail-nimbus.desktop
//       holds exactly that command -- and has NO StartupWMClass, so a
//       class-to-desktop match never finds it.
//
// So this produces SUGGESTIONS, ordered, each naming where it came from, and
// nothing writes until the user has confirmed the line. The plugin cannot
// know which of these is meant; only the person at the keyboard can.

// How many suggestions one window can produce. A browser binary alone can
// match five .desktop files by basename, and a window that offered twenty would not
// be a choice, it would be a wall.
var MAX_CANDIDATES = 12;

// Path prefixes that do not survive a reboot. /tmp and /run are cleared,
// /proc and /dev/shm are not filesystems anything is installed in.
var UNSTABLE_PREFIXES = ["/tmp/", "/run/", "/proc/", "/dev/shm/"];

// The program a command line runs: the first word, without its directory.
// This is the ONE derivation both sides of the .desktop-by-binary match use
// -- `nimbus` out of `/opt/nimbus-bin/nimbus --ozone-platform=wayland ...` and
// `nimbus` out of `nimbus --app=https://mail.example.com/mail/` -- which is
// why it is a named function rather than two open-coded splits that could
// drift apart.
function commandProgram(command) {
    var text = String(command === undefined || command === null ? "" : command);
    var first = text.replace(/^[ \t]+/, "").split(/[ \t]/)[0] || "";
    var parts = first.split("/");
    return parts[parts.length - 1];
}

// Whitespace-collapsed, for comparing two command lines that mean the same
// thing written with different spacing. Never used to WRITE a command: what
// goes into the file is what the user confirmed, byte for byte.
function commandNormalized(command) {
    return String(command === undefined || command === null ? "" : command)
           .replace(/[ \t]+/g, " ").replace(/^ | $/g, "");
}

// Does this command start from a path that will not exist at the next boot?
//
// THIS IS THE MOST IMPORTANT WARNING IN THIS TASK. The Modelbox window
// reports /tmp/.mount_modelbFjMMHD/modelbox, the mount point of a running
// AppImage. Written verbatim the entry fails silently at the next login,
// months later, with nobody watching.
//
// Two rules: the command STARTS under one of the volatile directories, or it
// contains a path segment beginning with ".mount_" anywhere -- the second
// catches an AppImage mounted somewhere other than /tmp, which is what
// $TMPDIR being set does.
function commandIsUnstablePath(command) {
    var text = commandNormalized(command);
    var first = text.split(" ")[0] || "";
    for (var i = 0; i < UNSTABLE_PREFIXES.length; i++) {
        if (first.indexOf(UNSTABLE_PREFIXES[i]) === 0) return true;
    }
    return /(^|[\/ \t])\.mount_/.test(text);
}

// The host a webapp window names in its own class. Chromium and Nimbus build
// the class of an --app window out of the URL:
//   nimbus-mail.example.com__mail_-Default
// and that dotted token is the only thing in the whole window that says WHICH
// of the five nimbus .desktop entries is the one. It is used for ORDERING
// only: a candidate is never dropped for failing to contain it, and no
// candidate is ever synthesised from it.
//
// "" when the class carries no dotted token. A class such as
// org.example.chatterbox yields one too ("org.example.chatterbox"); no command
// contains that string, so it reorders nothing -- which is the correct
// outcome, not a lucky one.
// MEASURED, not assumed: the first version of this returned
// "nimbus-mail.example.com" for the webapp window -- the leftmost dotted
// match swallows the browser name in front of the host, because a hostname
// label may contain a hyphen and the regular expression cannot know that this
// particular hyphen separates the browser from the host. That token appears in
// no command, so it reordered nothing and that window offered the wrong
// webapp entry first. Hence the second step: everything up to the last hyphen BEFORE
// the first dot is dropped. A host whose own first label contains a hyphen
// ("nimbus-web-app.example.com") loses that label too and yields
// "app.example.com" -- still a substring of the URL in the command, so the
// ordering still lands right.
function classHostToken(windowClass) {
    var match = /([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/.exec(
        String(windowClass === undefined || windowClass === null ? "" : windowClass));
    if (!match) return "";
    var token = match[0];
    var firstDot = token.indexOf(".");
    var lastDash = token.lastIndexOf("-", firstDot);
    if (lastDash >= 0) token = token.substring(lastDash + 1);
    // A token that lost its own first label entirely, or that no longer holds
    // a dot, identifies nothing and is dropped rather than used.
    if (token.charAt(0) === "." || token.indexOf(".") < 0) return "";
    return token;
}

// The program the window's own process runs. `program` comes from
// bin/omarchy-autostart-windows, which derives it from argv 0 and therefore
// still has it when the whole command line was past the cap and arrived
// empty. The fallback derives it from the command line, so a window object
// built by hand -- in a test, or by a future caller -- behaves the same.
function windowProgram(window) {
    var source = window || {};
    var named = String(source.program === undefined || source.program === null
                       ? "" : source.program);
    return named !== "" ? commandProgram(named) : commandProgram(source.command);
}

// Where a suggestion came from, shown on every row. The user is choosing
// between a packaged command and a measured one, and that difference is the
// whole basis for choosing.
var CANDIDATE_SOURCES = ["desktop-class", "desktop-binary", "running"];

function candidateSources() { return CANDIDATE_SOURCES.slice(); }

function candidateSourceText(source) {
    switch (source) {
    case "desktop-class":
        return "from its installed .desktop file, matched on the window class";
    case "desktop-binary":
        return "from an installed .desktop file that runs the same program";
    case "running":
        return "the command line this window is running right now";
    }
    return "from an unknown source (" + String(source) + ")";
}

var CANDIDATE_WARNINGS = ["unstable-path", "already-present", "program-already-present"];

function candidateWarnings() { return CANDIDATE_WARNINGS.slice(); }

function candidateWarningText(code) {
    // THE EMPTY CASE IS EXPLICIT, for the reason envelopeText's is: the
    // QML version of that function printed the literal text "undefined: "
    // to the user for every one of the several ways a value can go missing.
    if (code === undefined || code === null || String(code) === "") return "";
    switch (code) {
    case "unstable-path":
        return "This path will not exist after a restart -- it is a temporary "
             + "mount, the kind an AppImage gets a new one of at every start. "
             + "Written like this the entry works today and fails silently at "
             + "some later login. Prefer a suggestion that names the program "
             + "without a path.";
    case "already-present":
        return "This exact command is already in autostart.lua.";
    case "program-already-present":
        return "autostart.lua already starts this program, with a different "
             + "command line.";
    }
    return "Take care with this suggestion (" + String(code) + ").";
}

// Which warnings a command earns, in the order they matter. Both are
// returned: one is about the next boot and the other about a duplicate, and
// suppressing either because the other applies would hide exactly the fact
// the user needed.
function candidateWarningsFor(command, entries) {
    var out = [];
    if (commandIsUnstablePath(command)) out.push("unstable-path");
    var wanted = commandNormalized(command);
    var program = commandProgram(command);
    var exact = false, sameProgram = false;
    var list = entries || [];
    for (var i = 0; i < list.length; i++) {
        var entry = list[i];
        // Only the entries this reader can represent carry a command at all.
        // The nested `o.exec_on_start(o.launch_webapp_sole("Chat", ...))`
        // line does not, so such a suggestion is NOT reported
        // as already present -- a known blind spot of this comparison, and the
        // honest one: the alternative is to guess what that Lua helper expands
        // to and be wrong.
        if (!entry || entry.editable !== true || typeof entry.command !== "string") continue;
        if (commandNormalized(entry.command) === wanted) { exact = true; break; }
        if (program !== "" && commandProgram(entry.command) === program) sameProgram = true;
    }
    if (exact) out.push("already-present");
    else if (sameProgram) out.push("program-already-present");
    return out;
}

// THE SUGGESTION LIST for one open window, ordered, deduplicated by command.
//
//   entry.command   the exact line that would go into the file
//   entry.source    one of CANDIDATE_SOURCES, shown on the row
//   entry.name      the Name= of the .desktop file it came from, so five
//                   nimbus entries can be told apart; "" for "running"
//   entry.warning   the first of entry.warnings, or ""
//   entry.warnings  every warning that applies, none suppressed
//
// The order: the .desktop file matched on the window class first (packaged,
// stable, and the class is a strong signal), then the .desktop files that run
// the same program -- those whose command mentions the host in the window
// class ahead of those that do not, which is what puts Webmail (Nimbus) at the
// top for the webmail window instead of Music (Web) -- and the running
// command line last, because it is the one most likely to carry a volatile
// path or the wrong window's flags.
//
// `entries` is the autostart.lua entry list from parseAutostartLua and only
// feeds the already-present warnings. Absent, the suggestions are the same
// and simply carry no duplicate warning.
function autostartCandidatesForWindow(window, apps, entries) {
    var source = window || {};
    var windowClass = String(source["class"] === undefined || source["class"] === null
                             ? "" : source["class"]);
    var wanted = windowClass.toLowerCase();
    var program = windowProgram(source);
    var host = classHostToken(windowClass);
    var list = apps || [];
    var byClass = [], hosted = [], other = [], i;

    for (i = 0; i < list.length; i++) {
        var app = list[i];
        if (!app || typeof app !== "object") continue;
        // String() around every value: the application list is built from
        // files this plugin does not own, and a missing Exec= must not throw
        // and take the whole suggestion list with it.
        var command = commandFromApp(app);
        if (command === "") continue;
        var name = String(app.name === undefined || app.name === null ? "" : app.name);
        var wmclass = String(app.wmclass === undefined || app.wmclass === null ? "" : app.wmclass);
        if (wmclass !== "" && windowClass !== "" && wmclass.toLowerCase() === wanted) {
            byClass.push({ command: command, source: "desktop-class", name: name });
            continue;
        }
        if (program !== "" && commandProgram(command) === program) {
            var row = { command: command, source: "desktop-binary", name: name };
            if (host !== "" && command.indexOf(host) >= 0) hosted.push(row);
            else other.push(row);
        }
    }

    var running = String(source.command === undefined || source.command === null
                         ? "" : source.command);
    var ordered = byClass.concat(hosted, other);
    if (running !== "") {
        ordered.push({ command: running, source: "running", name: "" });
    }

    // Deduplicated on the command itself, first occurrence kept: the highest
    // ranked source wins, and Termpane -- whose .desktop file matches both
    // by class and by binary -- offers `termpane` once, not twice.
    // Object.create(null), not {}: a command of "__proto__" would read back
    // as already seen from a plain object, because every plain object has
    // that key inherited.
    var seen = Object.create(null);
    var out = [];
    for (i = 0; i < ordered.length && out.length < MAX_CANDIDATES; i++) {
        var candidate = ordered[i];
        if (seen[candidate.command]) continue;
        seen[candidate.command] = true;
        var warnings = candidateWarningsFor(candidate.command, entries);
        out.push({ command: candidate.command, source: candidate.source,
                   name: candidate.name,
                   warning: warnings.length > 0 ? warnings[0] : "",
                   warnings: warnings });
    }
    return out;
}

// WHY A WINDOW HAS NOTHING TO OFFER. Such a window is SHOWN with this reason,
// never left out of the list -- a window that silently disappears is one the
// user cannot even ask about.
//
// "" when there is at least one suggestion. The two codes are distinguishable
// for free and are not the same problem: `program` survives the command line
// cap in bin/omarchy-autostart-windows, so a program name with no command
// means the line was too long to offer, while neither means /proc could not
// be read at all (a window of another user, or a process that exited between
// the two reads).
var CANDIDATE_REASONS = ["no-command-line", "command-too-long"];

function candidateReasons() { return CANDIDATE_REASONS.slice(); }

function autostartCandidateReason(window, candidates) {
    if ((candidates || []).length > 0) return "";
    return windowProgram(window) === "" ? "no-command-line" : "command-too-long";
}

function candidateReasonText(code) {
    switch (code) {
    case "no-command-line":
        return "No installed application matches this window, and its command "
             + "line could not be read. Type the command by hand.";
    case "command-too-long":
        return "No installed application matches this window, and its command "
             + "line is longer than this panel will write. Type the command by "
             + "hand.";
    }
    if (code === undefined || code === null || String(code) === "") {
        return "";
    }
    return "This window offers nothing to add (" + String(code) + ").";
}

// How one open window is named in the picker: the class, which is what
// identifies it, and the title, which is what the user recognises. Here
// rather than in Panel.qml for the reason every other piece of wording is:
// a string built in QML is a string no suite in this project can execute.
function autostartWindowLabel(window) {
    var source = window || {};
    var windowClass = String(source["class"] === undefined || source["class"] === null
                             ? "" : source["class"]);
    var title = String(source.title === undefined || source.title === null
                       ? "" : source.title).substring(0, MAX_NAME);
    if (windowClass === "" && title === "") return "(a window with no class and no title)";
    if (title === "") return windowClass;
    if (windowClass === "") return title;
    return windowClass + " -- " + title;
}
