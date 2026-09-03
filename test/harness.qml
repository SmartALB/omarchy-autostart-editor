import QtQml
import "../Model.js" as Model

QtObject {
    Component.onCompleted: {
        var failed = 0, total = 0;
        var currentTestName = "";  // Can be one test behind: check(name, got, want) evaluates got before check is entered

        function check(name, got, want) {
            total++;
            currentTestName = name;
            if (got !== want) {
                failed++;
                console.warn("FAIL " + name + "\n       got  " + got + "\n       want " + want);
            } else {
                console.warn("ok   " + name);
            }
        }

        function checkThrows(name, fn, expectedPattern) {
            if (!expectedPattern) {
                throw new Error("checkThrows('" + name + "') was called without an expected "
                                + "message pattern -- without one, any exception counts as a pass");
            }
            total++;
            currentTestName = name;
            try {
                fn();
                failed++;
                console.warn("FAIL " + name + " -- expected a throw, got none");
            } catch (e) {
                var message = String((e && e.message) || e);
                if (!expectedPattern.test(message)) {
                    failed++;
                    console.warn("FAIL " + name + " -- threw the wrong error\n       got  " + message
                                 + "\n       want a message matching " + expectedPattern);
                } else {
                    console.warn("ok   " + name);
                }
            }
        }

        try {
            // --- stripFieldCodes ----------------------------------------------
            check("stripFieldCodes: %U goes",        Model.stripFieldCodes("cursor %U"), "cursor");
            check("stripFieldCodes: %F goes",        Model.stripFieldCodes("gimp %F"), "gimp");
            check("stripFieldCodes: %i %c %k go",    Model.stripFieldCodes("app %i %c %k"), "app");
            check("stripFieldCodes: %f in the middle",
                  Model.stripFieldCodes("app %f --flag"), "app --flag");
            check("stripFieldCodes: %% survives as a literal percent",
                  Model.stripFieldCodes("app %% x"), "app % x");
            check("stripFieldCodes: an unknown code is left alone",
                  Model.stripFieldCodes("app %z"), "app %z");
            check("stripFieldCodes: quoted arguments survive",
                  Model.stripFieldCodes('nimbus --app=https://a.example/ %U'),
                  "nimbus --app=https://a.example/");
            check("stripFieldCodes: nothing to strip",
                  Model.stripFieldCodes("modelbox"), "modelbox");

            // --- appsProblem ---------------------------------------------------
            // Two facts, three outcomes. The point of the pair is that "too
            // long" and "broken" are not the same sentence: the first is
            // something the user can act on. The panel could only ever say the
            // second one until the stderr marker was collected.
            check("appsProblem: nothing wrong, nothing said",
                  Model.appsProblem(false, false), "");
            check("appsProblem: too long to read in full says so",
                  Model.appsProblem(true, true).indexOf("too long to read in full") !== -1, true);
            check("appsProblem: a broken answer does NOT claim it was too long",
                  Model.appsProblem(true, false).indexOf("too long") , -1);
            check("appsProblem: a broken answer says it could not be read",
                  Model.appsProblem(true, false),
                  "Could not read the list of installed applications.");
            check("appsProblem: cut short but usable is its own third case",
                  Model.appsProblem(false, true).indexOf("may be missing from it") !== -1, true);
            check("appsProblem: the three cases are three different sentences",
                  (function() {
                      var a = Model.appsProblem(true, true), b = Model.appsProblem(true, false),
                          c = Model.appsProblem(false, true);
                      return (a !== b && b !== c && a !== c) ? "distinct" : "collapsed";
                  })(), "distinct");

            // RESTORED, not inherited: this helper stood among the deleted
            // reasonText assertions and every surviving wording claim below
            // depends on it -- the envelope codes, the reader's refusal codes,
            // the write-refusal codes and the candidate wording.
            //
            // "Has wording" has to mean MORE than "is not the bare code", and a
            // mutation probe is how that was learned: deleting the
            // write-failed branch left this assertion GREEN, because the
            // fallback is a polite sentence naming the code rather than the
            // bare code itself. So the fallback's own shape is asked for with
            // a sentinel and then rendered for each real code -- derived from
            // the function under test, not copied from it, so it keeps working
            // if the fallback wording changes.
            function unwordedAmong(codes, worder) {
                var fallback = worder("__sentinel__"), without = [];
                for (var i = 0; i < codes.length; i++) {
                    var worded = worder(codes[i]);
                    if (worded === codes[i]
                        || worded === fallback.replace("__sentinel__", codes[i])
                        || String(worded).length < 12) without.push(codes[i]);
                }
                return without.join(",");
            }

            // --- envelopeText --------------------------------------------------
            //
            // The class claim is split across two files on purpose (see
            // Model.envelopeCodes): this half proves every listed code has
            // wording, and test/run-tests.sh proves the list is the script's.
            // Same rule as reasonText: not the bare code back, and long enough
            // to be a sentence rather than a decorated identifier.
            check("envelopeText: every code the bin/ helpers can emit has plain wording",
                  unwordedAmong(Model.envelopeCodes(),
                                function(c) { return Model.envelopeText(c, ""); }), "");
            check("envelopeText: the list it checks is not empty",
                  Model.envelopeCodes().length, 10);

            // THE EMPTY ENVELOPE. Empty stdout is what a missing script, a
            // timeout kill and a non-zero exit outside the script's own two
            // reporters all look like from here; the QML version this replaced
            // printed the literal text "undefined: ".
            check("envelopeText: an absent code does not print undefined",
                  Model.envelopeText(undefined, undefined).indexOf("undefined"), -1);
            check("envelopeText: an empty code does not print undefined",
                  Model.envelopeText("", "").indexOf("undefined"), -1);
            check("envelopeText: an absent code says so in words",
                  Model.envelopeText(undefined, undefined),
                  "The helper gave no answer at all.");
            check("envelopeText: an unknown code is named, not shown bare",
                  Model.envelopeText("brand-new", ""),
                  "The helper reported an unknown problem: brand-new.");
            check("envelopeText: the detail is appended when there is one",
                  Model.envelopeText("too-large", "300000 bytes"),
                  "autostart.lua is too large for this panel to handle. 300000 bytes");
            check("envelopeText: no trailing space when there is no detail",
                  Model.envelopeText("too-large", ""),
                  "autostart.lua is too large for this panel to handle.");
            // THE THREE CODES THE REMOVAL EXPOSED. Losing the config script
            // made bin/omarchy-autostart-hypr-write the second emitter, and
            // does-not-compile, is-a-symlink and no-lua-compiler had reached
            // the user through the unknown-code fallback until then. Named one
            // by one, because the completeness loop above passes on a sentence
            // of any content and these three are the ones that were missing.
            check("envelopeText: the writer's does-not-compile says the file is untouched",
                  Model.envelopeText("does-not-compile", "")
                       .indexOf("exactly as it was") >= 0, true);
            check("envelopeText: the writer's is-a-symlink says to edit it by hand",
                  Model.envelopeText("is-a-symlink", "").indexOf("by hand") >= 0, true);
            check("envelopeText: the writer's no-lua-compiler names the package to install",
                  Model.envelopeText("no-lua-compiler", "").indexOf("lua51") >= 0, true);

            // --- versionText ---------------------------------------------------
            //
            // The panel's footer. The shell suite pins Model.VERSION to
            // manifest.json's `version`; these pin the RENDERING of it, which
            // is the half no grep over the manifest can see.
            check("versionText: it is the version with a v in front",
                  Model.versionText(), "v" + Model.VERSION);
            check("versionText: and the version itself is reachable and non-empty",
                  Model.VERSION.length > 0, true);
            check("versionText: it names the whole version, not a truncation",
                  Model.versionText().indexOf(Model.VERSION) >= 0, true);
            // INDEPENDENT OF THE IMPLEMENTATION, and that is the point: the
            // three assertions above all derive their expectation from
            // Model.VERSION, so they hold the RELATIONSHIP and would accept a
            // malformed version travelling intact to the footer. This one
            // judges the rendered string on its own.
            check("versionText: it reads as a version and not as arbitrary text",
                  /^v[0-9]+\.[0-9]+\.[0-9]+$/.test(Model.versionText()), true);
            // The empty case, which the footer's `visible` binding depends on:
            // a bare "v" would look like an answer where there is none.
            check("versionText: nothing to show is shown as nothing, not as a bare v",
                  (function() {
                      var saved = Model.VERSION;
                      Model.VERSION = "";
                      var got = Model.versionText();
                      Model.VERSION = saved;
                      return got;
                  })(), "");
            check("versionText: and restoring it put the real version back",
                  Model.versionText(), "v" + Model.VERSION);

            // --- shellQuote ----------------------------------------------------
            check("shellQuote: plain path",      Model.shellQuote("/a/b"), "'/a/b'");
            check("shellQuote: a space",         Model.shellQuote("a b"), "'a b'");
            check("shellQuote: a single quote",  Model.shellQuote("a'b"), "'a'\\''b'");
            check("shellQuote: a semicolon is inert inside quotes",
                  Model.shellQuote("a; rm -rf /"), "'a; rm -rf /'");
            check("shellQuote: a dollar sign is inert inside quotes",
                  Model.shellQuote("$HOME"), "'$HOME'");


            // =================================================================
            // THE READER FOR THE USER'S HYPRLAND LUA FILES
            // =================================================================
            //
            // THE FIXTURE IS THE USER'S OWN FILE, VERBATIM, byte for
            // byte as it stood on 2026-09-03 -- generated from
            // ~/.config/hypr/autostart.lua rather than retyped, because a fixture that
            // is merely LIKE the real forms proves the parser handles the
            // fixture. German section comments, the factual notes, the blank
            // lines and the trailing newline are all part of them: the line
            // numbers this reader reports are only correct if every one of
            // those lines is counted.
            //
            // It is an array of LINES joined with "\n", so the round-trip
            // assertion below can compare `raw` against the very array element
            // the line number indexes into.
            //
            // TWO MORE FIXTURES STOOD HERE -- the user's windowrules.lua and
            // workspaces.lua, with the parsers, the round-trip proofs and the
            // line-number assertions that went with them. Both files are read
            // by nothing in this plugin now.
            var AUTOSTART_LINES = [
                    "-- Autostart. Portiert aus autostart.conf.",
                    "",
                    "-- Dienstliche Kommunikation",
                    "o.launch_on_start(\"notes-app\")",
                    "o.launch_on_start(\"nimbus --app=https://mail.example.com/mail/\")",
                    "",
                    "-- Private Kommunikation",
                    "o.exec_on_start(o.launch_webapp_sole(\"Chat\", \"https://chat.example.org/\"))",
                    "o.launch_on_start(\"Chatterbox\")",
                    "",
                    "-- Browser",
                    "o.launch_on_start(\"nimbus\")",
                    "",
                    "-- Schluesselverwaltung",
                    "o.launch_on_start(\"keyring-gui\")",
                    "",
                    "-- Modelbox (am 28.08.2026 nach dem Upgrade neu installiert).",
                    "-- Hinweis: modelbox.service startet den Server ohnehin headless",
                    "-- (--run-as-service); diese Zeile oeffnet zusaetzlich das GUI-Fenster,",
                    "-- so wie es vor dem Upgrade in autostart.conf stand.",
                    "o.launch_on_start(\"modelbox\")",
                    ""
            ];
            var AUTOSTART_TEXT = AUTOSTART_LINES.join("\n");

            // THE ROUND-TRIP PROOF, and it is the assertion the whole later
            // line surgery rests on: for every entry the reader returns, `raw`
            // must be EXACTLY the line the input text has at `line`. Without
            // it every other property here is decoration -- a parser that
            // reports the right command against the wrong line number would
            // pass all of them and then, when the writer lands, edit somebody
            // else's line. This project has already had that exact class of
            // defect reach a real window.
            //
            // Returns the offending line numbers as a string, so the failure
            // message names them; "" is the pass. One check() per file, not
            // one per entry, because the harness's assertion-count guard
            // requires every call site to be countable and a call site inside
            // a loop is not.
            function roundTripBreaks(lines, entries) {
                var broken = [];
                for (var i = 0; i < entries.length; i++) {
                    var e = entries[i];
                    // Both halves matter: an out-of-range line number is as
                    // fatal to line surgery as a mismatched text, and
                    // lines[undefined] would compare equal to an undefined raw.
                    if (typeof e.line !== "number" || e.line < 1 || e.line > lines.length) {
                        broken.push("line " + e.line + " out of range");
                    } else if (lines[e.line - 1] !== e.raw) {
                        broken.push(String(e.line));
                    }
                }
                return broken.join(", ");
            }

            var autostartEntries = Model.parseAutostartLua(AUTOSTART_TEXT, "autostart.lua");

            // FAIL-CLOSED FIRST: a round-trip proof over zero entries proves
            // nothing at all, which is this project's own blind-test shape. So
            // the counts are asserted before the proof is trusted.
            check("hypr: the real autostart.lua yields entries to prove anything about",
                  autostartEntries.length, 7);

            check("hypr ROUND TRIP: every autostart.lua entry's raw is the line at its number",
                  roundTripBreaks(AUTOSTART_LINES, autostartEntries), "");

            // And the proof can fail. Without this, roundTripBreaks returning
            // "" for a genuinely broken reader would be indistinguishable from
            // it returning "" because it never compares anything -- which is
            // exactly how a green suite lies.
            check("hypr ROUND TRIP: the proof itself notices a shifted line number",
                  roundTripBreaks(AUTOSTART_LINES,
                                  [{ line: 4, raw: AUTOSTART_LINES[4] }]), "4");
            check("hypr ROUND TRIP: the proof itself notices a line number off the end",
                  roundTripBreaks(AUTOSTART_LINES,
                                  [{ line: 9999, raw: "x" }]).indexOf("out of range") >= 0, true);

            // --- the line numbers, against the real comment layout ------------
            //
            // autostart.lua has a German comment on line 3 and the first call
            // on line 4; the last call is on line 21, after a FOUR-LINE note
            // (17-20) about Modelbox. A parser that does not count comment and
            // blank lines reports 1 and 12 here, and every entry below the
            // first comment is then wrong by exactly the number of lines it
            // skipped.
            function lineNumbersOf(entries) {
                var out = [];
                for (var i = 0; i < entries.length; i++) out.push(entries[i].line);
                return out.join(",");
            }
            check("hypr: autostart.lua line numbers count comments and blanks",
                  lineNumbersOf(autostartEntries), "4,5,8,9,12,15,21");

            // --- autostart.lua: the recognised forms --------------------------
            check("hypr autostart: launch_on_start gives the bare command",
                  autostartEntries[0].command, "notes-app");
            check("hypr autostart: launch_on_start is the uwsm-app route",
                  autostartEntries[0].launcher, "uwsm-app");
            check("hypr autostart: launch_on_start is editable",
                  autostartEntries[0].editable, true);
            check("hypr autostart: a command with an = and a URL survives whole",
                  autostartEntries[1].command,
                  "nimbus --app=https://mail.example.com/mail/");
            check("hypr autostart: the entry carries its file name",
                  autostartEntries[0].file, "autostart.lua");
            check("hypr autostart: the entry carries the helper it called",
                  autostartEntries[0].fn, "o.launch_on_start");

            // THE NESTED FORM, and it is the case the brief names by hand:
            // o.exec_on_start(o.launch_webapp_sole("Chat", "https://chat.example.org/"))
            // It is line 8 of the user's real file.
            check("hypr autostart: the nested webapp helper is NOT editable",
                  autostartEntries[2].editable, false);
            check("hypr autostart: the nested webapp helper says why",
                  autostartEntries[2].reason, "nested-call");
            check("hypr autostart: the nested webapp helper still carries its raw line",
                  autostartEntries[2].raw,
                  "o.exec_on_start(o.launch_webapp_sole(\"Chat\", \"https://chat.example.org/\"))");
            check("hypr autostart: the nested webapp helper invents no command",
                  autostartEntries[2].command, undefined);

            // helpers.lua:118-120 makes these two lines the same fact, so the
            // reader must report them identically rather than by their spelling.
            var equivalent = Model.parseAutostartLua(
                "o.launch_on_start(\"nimbus\")\no.exec_on_start(o.launch(\"nimbus\"))");
            check("hypr autostart: both spellings of the same fact give two entries",
                  equivalent.length, 2);
            check("hypr autostart: exec_on_start(o.launch(...)) is the uwsm-app route too",
                  equivalent[1].launcher, "uwsm-app");
            check("hypr autostart: and the same command",
                  equivalent[1].command, equivalent[0].command);
            check("hypr autostart: and it is editable",
                  equivalent[1].editable, true);
            check("hypr autostart: a plain exec_on_start string is the shell route",
                  Model.parseAutostartLua("o.exec_on_start(\"echo hi\")")[0].launcher, "shell");

            // --- a line that calls nothing known is NOT an entry ---------------
            //
            // This is the other half of the contract: the reader must not turn
            // a comment, a blank line or an unrelated statement into an entry
            // it would then offer to rewrite. Those lines belong to the file.
            check("hypr: a comment-only file yields no entry",
                  Model.parseAutostartLua("-- nur ein Kommentar\n-- und noch einer\n").length, 0);
            check("hypr: an empty file yields no entry",
                  Model.parseAutostartLua("").length, 0);
            check("hypr: an absent text yields no entry rather than throwing",
                  Model.parseAutostartLua(undefined).length, 0);
            check("hypr: a blank-lines-only file yields no entry",
                  Model.parseAutostartLua("\n\n\n").length, 0);
            check("hypr: an unrelated statement is not an entry",
                  Model.parseAutostartLua("require(\"hypr.monitors\")").length, 0);
            check("hypr: a commented-out call is not an entry",
                  Model.parseAutostartLua("-- o.launch_on_start(\"nimbus\")").length, 0);
            check("hypr: windowrules calls are not read out of autostart.lua",
                  Model.parseAutostartLua("o.window(\"x\", { workspace = \"2\" })").length, 0);
            check("hypr: an indented call is still an entry",
                  Model.parseAutostartLua("    o.launch_on_start(\"nimbus\")")[0].editable, true);
            check("hypr: an indented call keeps its indentation in raw",
                  Model.parseAutostartLua("    o.launch_on_start(\"nimbus\")")[0].raw,
                  "    o.launch_on_start(\"nimbus\")");

            // --- parseHyprFiles: the one section --------------------------------
            //
            // ONE section now, where there were three. It stays a LIST, and the
            // guarantees that made it one still hold and still matter: a file
            // the reader did not find is a section that SAYS so rather than a
            // section that vanished, and a name the envelope carries that this
            // plugin does not read is ignored rather than shown.
            var envelope = [
                { name: "autostart.lua", path: "/h/autostart.lua", present: true,
                  mtime: 11, truncated: false, content: AUTOSTART_TEXT }
            ];
            var sections = Model.parseHyprFiles(envelope);
            check("hypr sections: exactly one", sections.length, 1);
            check("hypr sections: and it is autostart.lua", sections[0].name, "autostart.lua");
            check("hypr sections: the mtime is carried through",
                  sections[0].mtime, 11);
            // The absent and truncated envelopes, each in full, because both
            // are what hyprSectionIsWritable and hyprSectionNoteText below are
            // judged against and neither can be read off `sections`.
            var absentSections = Model.parseHyprFiles(
                [{ name: "autostart.lua", path: "/h/autostart.lua", present: false,
                   mtime: 0, truncated: false, content: "" }]);
            var truncSections = Model.parseHyprFiles(
                [{ name: "autostart.lua", path: "/h/autostart.lua", present: true,
                   mtime: 13, truncated: true, content: AUTOSTART_TEXT }]);
            check("hypr sections: a missing file is present:false",
                  absentSections[0].present, false);
            check("hypr sections: a missing file has no entries",
                  absentSections[0].entries.length, 0);
            check("hypr sections: a missing file still names its path",
                  absentSections[0].path, "/h/autostart.lua");
            check("hypr sections: the truncation flag is carried through",
                  truncSections[0].truncated, true);
            check("hypr sections: an entirely absent envelope still gives a section",
                  Model.parseHyprFiles(undefined).length, 1);
            check("hypr sections: and it does not claim to be present",
                  Model.parseHyprFiles(undefined)[0].present, false);
            check("hypr sections: an unknown file name in the envelope is ignored",
                  Model.parseHyprFiles([{ name: "bindings.lua", present: true,
                                          content: "o.launch_on_start(\"x\")" }]).length, 1);
            check("hypr sections: an unknown name yields nothing present, not its content",
                  Model.parseHyprFiles([{ name: "bindings.lua", present: true,
                                          content: "o.launch_on_start(\"x\")" }])[0].present,
                  false);
            check("hypr sections: how many entries are editable",
                  Model.hyprEditableCount(sections), 6);

            // --- the wording ----------------------------------------------------
            //
            // The same two-sided guarantee reasonText and envelopeText have:
            // this half proves every code the parsers can set has plain
            // wording, and the parser assertions above are what prove the list
            // is the set they actually set.
            check("hypr wording: every refusal code has plain wording",
                  unwordedAmong(Model.hyprReasons(), Model.hyprReasonText), "");
            check("hypr wording: the list it checks is not empty",
                  Model.hyprReasons().length, 3);
            check("hypr wording: an absent code does not print undefined",
                  Model.hyprReasonText(undefined).indexOf("undefined"), -1);
            check("hypr wording: an unknown code is named, not shown bare",
                  Model.hyprReasonText("brand-new").indexOf("brand-new") >= 0, true);

            check("hypr header: it says this panel edits autostart.lua and nothing else",
                  Model.hyprHeaderText(sections)
                       .indexOf("edits your autostart.lua and nothing else") >= 0, true);
            check("hypr header: it names the file it read, with its entry count",
                  Model.hyprHeaderText(sections).indexOf("Read: autostart.lua (7)") >= 0, true);
            check("hypr header: it names the file it did not find",
                  Model.hyprHeaderText(absentSections).indexOf("Not found: autostart.lua") >= 0,
                  true);
            check("hypr header: with nothing read at all it says so",
                  Model.hyprHeaderText(Model.parseHyprFiles(undefined))
                       .indexOf("No file was read") >= 0, true);

            check("hypr entry text: the line number comes first",
                  Model.hyprEntryText(autostartEntries[0]), "4: notes-app");
            check("hypr entry text: a non-editable entry shows its raw line and nothing invented",
                  Model.hyprEntryText(autostartEntries[2]),
                  "8: " + autostartEntries[2].raw);

            // --- the Lua string scanner ------------------------------------------
            check("luaStringAt: a plain string",
                  Model.luaStringWhole("\"abc\""), "abc");
            check("luaStringAt: a single-quoted string",
                  Model.luaStringWhole("'abc'"), "abc");
            check("luaStringAt: an escaped backslash decodes to one",
                  Model.luaStringWhole("\"a\\\\b\""), "a\\b");
            check("luaStringAt: an escaped quote decodes",
                  Model.luaStringWhole("\"a\\\"b\""), "a\"b");
            check("luaStringAt: a decimal escape decodes",
                  Model.luaStringWhole("\"\\65\""), "A");
            check("luaStringAt: a hex escape decodes",
                  Model.luaStringWhole("\"\\x41\""), "A");
            check("luaStringAt: an unterminated string is refused",
                  Model.luaStringWhole("\"abc"), null);
            check("luaStringAt: an unknown escape is refused rather than guessed",
                  Model.luaStringWhole("\"a\\zb\""), null);
            check("luaStringAt: trailing content after the quote is refused",
                  Model.luaStringWhole("\"abc\" .. x"), null);
            check("luaStringAt: something that is not a string at all is refused",
                  Model.luaStringWhole("abc"), null);

            // --- the command an application declares ---------------------------
            //
            // One derivation. It had two callers -- programFromApp, of the
            // removed half, and the autostart picker; the picker is the one
            // left, and it fills the add field with this rather than writing
            // it, because Exec= is a guess. The assertion that the two callers
            // agreed went with the other one.
            check("commandFromApp: the field codes are stripped",
                  Model.commandFromApp({ exec: "nimbus %U" }), "nimbus");
            check("commandFromApp: an escaped percent survives",
                  Model.commandFromApp({ exec: "printf 100%% %f" }), "printf 100%");
            check("commandFromApp: no exec at all gives an empty command",
                  Model.commandFromApp({ name: "x" }), "");
            check("commandFromApp: nothing at all gives an empty command",
                  Model.commandFromApp(undefined), "");
            check("commandFromApp: and what it gives round-trips into a line",
                  roundTrip(Model.commandFromApp(
                      { exec: "nimbus --app=https://x/ %U" })), "");

            // --- the bytes the surgery works on --------------------------------
            //
            // autostartApply() may only do surgery on the text the entries'
            // line numbers were derived from, so the section carries it.
            check("hypr sections: the content is carried through byte for byte",
                  sections[0].content, AUTOSTART_TEXT);
            check("hypr sections: an absent file carries no content",
                  absentSections[0].content, "");
            check("hypr sections: the entries agree with the content it carries",
                  Model.parseAutostartLua(sections[0].content, "autostart.lua")[0].raw,
                  sections[0].entries[0].raw);

            // --- which section may be written ----------------------------------
            //
            // Five assertions that pinned the name check against the user's own
            // windowrules.lua and workspaces.lua are gone with those fixtures.
            // The name check itself is NOT gone and must not go soft: it is
            // what stops the panel classifying a section by its file name, and
            // the predicate is public -- Panel.qml calls it on whatever section
            // it holds. So it is judged against hand-built sections that differ
            // from a writable one in NOTHING BUT THE NAME, which is exactly the
            // discrimination the deleted fixtures used to prove.
            check("hypr writable: autostart.lua is the one",
                  Model.hyprSectionIsWritable(sections[0]), true);
            check("hypr writable: a section identical but for its name is refused",
                  Model.hyprSectionIsWritable({ name: "windowrules.lua", present: true,
                                                truncated: false,
                                                entries: sections[0].entries,
                                                content: sections[0].content }), false);
            check("hypr writable: and so is a second one, so it is not one special case",
                  Model.hyprSectionIsWritable({ name: "workspaces.lua", present: true,
                                                truncated: false,
                                                entries: sections[0].entries,
                                                content: sections[0].content }), false);
            check("hypr writable: while the same section under the right name is writable",
                  Model.hyprSectionIsWritable({ name: "autostart.lua", present: true,
                                                truncated: false,
                                                entries: sections[0].entries,
                                                content: sections[0].content }), true);
            check("hypr writable: an absent autostart.lua is not",
                  Model.hyprSectionIsWritable(absentSections[0]), false);
            check("hypr writable: a truncated autostart.lua is not",
                  Model.hyprSectionIsWritable(truncSections[0]), false);
            check("hypr writable: nothing at all is not",
                  Model.hyprSectionIsWritable(undefined), false);

            // --- the counting the panel used to do itself ---------------------
            //
            // Finding 1 of the task 18 review: the bar widget's numbers were
            // derived in Panel.qml by comparing section names, where nothing
            // can execute them. They are derived here now.
            //
            // THERE IS ONE NUMBER LEFT. hyprPlacementCount and hyprEntryCount
            // counted the other two files, so the "the two halves add up to
            // the total" assertion had no halves left to add.
            check("hypr counts: the programs are the autostart entries",
                  Model.hyprProgramCount(sections), 7);
            check("hypr counts: a section that is not there counts as none",
                  Model.hyprProgramCount(Model.parseHyprFiles(undefined)), 0);
            check("hypr counts: the section is found by name, not by position",
                  Model.hyprSectionNamed(sections, "autostart.lua").name, "autostart.lua");
            check("hypr counts: a name no section carries gives null",
                  Model.hyprSectionNamed(sections, "bindings.lua"), null);

            // --- the three section notes ---------------------------------------
            //
            // Finding 2 of the task 18 review: these three sentences were inline
            // in Panel.qml. The empty string is the fourth case and the one that
            // decides whether the note is shown at all.
            check("hypr note: an absent file names its path",
                  Model.hyprSectionNoteText(absentSections[0]), "Not found: /h/autostart.lua");
            check("hypr note: a truncated file says what is shown",
                  Model.hyprSectionNoteText(truncSections[0])
                       .indexOf("larger than this panel reads") >= 0,
                  true);
            check("hypr note: a file with nothing recognised says so",
                  Model.hyprSectionNoteText({ name: "autostart.lua", present: true,
                                              truncated: false, entries: [] }),
                  "No line in this file is one this panel recognises.");
            check("hypr note: a file with entries has nothing to add",
                  Model.hyprSectionNoteText(sections[0]), "");
            check("hypr note: an absent path does not print undefined",
                  Model.hyprSectionNoteText({ present: false }).indexOf("undefined"), -1);

            check("hypr autostart note: it counts what can be edited",
                  Model.hyprAutostartNoteText(sections).indexOf("6 of 7 entries") >= 0, true);
            check("hypr autostart note: and names the limitation of the rest",
                  Model.hyprAutostartNoteText(sections).indexOf("by hand") >= 0, true);
            check("hypr autostart note: with everything editable it does not mention hand editing",
                  Model.hyprAutostartNoteText(Model.parseHyprFiles(
                      [{ name: "autostart.lua", path: "/h/a.lua", present: true, mtime: 1,
                         truncated: false, content: "o.launch_on_start(\"nimbus\")\n" }]))
                       .indexOf("by hand"), -1);
            check("hypr autostart note: an absent file says nothing at all",
                  Model.hyprAutostartNoteText(Model.parseHyprFiles(undefined)), "");

            // --- a Lua block comment is not code -------------------------------
            //
            // Finding 3 of the task 18 review, and it GATED the writer: a rule
            // inside `--[[ ... ]]` came back editable:true, so changing it would
            // have rewritten a line the user had deliberately switched off and
            // removing it would have deleted a line he was keeping. The line
            // number and the raw text were always right, so no neighbour was
            // ever at risk -- but the entry itself should never have been
            // offered. Neither his files nor Omarchy's default tree contains a
            // long bracket, so every fixture here is constructed.
            var blockCommented = Model.parseAutostartLua(
                "o.launch_on_start(\"one\")\n--[[\no.launch_on_start(\"two\")\n]]\n"
                + "o.launch_on_start(\"three\")\n", "autostart.lua");
            check("hypr bracket: a line inside a block comment is not an entry",
                  blockCommented.length, 2);
            check("hypr bracket: the live lines are the ones outside it",
                  blockCommented[0].command + "," + blockCommented[1].command, "one,three");
            check("hypr bracket: and their line numbers still count the comment lines",
                  blockCommented[0].line + "," + blockCommented[1].line, "1,5");
            check("hypr bracket: a levelled block comment is recognised too",
                  Model.parseAutostartLua(
                      "--[==[\no.launch_on_start(\"x\")\n]==]\n", "autostart.lua").length, 0);
            check("hypr bracket: a closer at the wrong level does not end it",
                  Model.parseAutostartLua(
                      "--[==[\n]]\no.launch_on_start(\"x\")\n]==]\n", "autostart.lua").length, 0);
            check("hypr bracket: a long STRING spanning lines is not code either",
                  Model.parseAutostartLua(
                      "local s = [[\no.launch_on_start(\"x\")\n]]\n", "autostart.lua").length, 0);
            check("hypr bracket: a bracket opener inside a quoted string opens nothing",
                  Model.parseAutostartLua(
                      "o.launch_on_start(\"a--[[b\")\no.launch_on_start(\"y\")\n",
                      "autostart.lua").length, 2);
            check("hypr bracket: a block comment opened and closed on one line ends there",
                  Model.parseAutostartLua(
                      "--[[ off ]]\no.launch_on_start(\"y\")\n", "autostart.lua").length, 1);
            check("hypr bracket: a plain line comment still ends at the line",
                  Model.parseAutostartLua(
                      "-- o.launch_on_start(\"off\")\no.launch_on_start(\"y\")\n",
                      "autostart.lua").length, 1);
            check("hypr bracket: the level of `[[` is 0",
                  Model.hyprBracketLevelAt("[[x", 0, "["), 0);
            check("hypr bracket: the level of `[==[` is 2",
                  Model.hyprBracketLevelAt("[==[x", 0, "["), 2);
            check("hypr bracket: a lone `[` is not a long bracket",
                  Model.hyprBracketLevelAt("[x]", 0, "["), -1);

            // ==================================================================
            // WRITING autostart.lua
            // ==================================================================
            //
            // THE FILE RUNS AT EVERY LOGIN, so every case below asserts the
            // WHOLE new text byte for byte, and then asserts separately that old
            // and new differ in exactly one line. "Looks right" is not the
            // property; those two together are.
            //
            // The fixture is AUTOSTART_LINES -- the user's own 21-line file,
            // byte-identical to it (the task 18 review verified that), with the
            // trailing "" that makes AUTOSTART_TEXT end in exactly one newline.
            var LIVE = AUTOSTART_LINES.slice(0, 21);   // the 21 content lines

            // --- add: one line, appended, nothing sorted anywhere -------------
            var added = Model.autostartApply(AUTOSTART_TEXT,
                                             { action: "add", command: "obsidian" });
            check("autostart add: it succeeds", added.ok, true);
            check("autostart add: the whole new text, byte for byte",
                  added.text,
                  LIVE.concat(["o.launch_on_start(\"obsidian\")", ""]).join("\n"));
            check("autostart add: old and new differ in exactly ONE line, the new last one",
                  Model.oneLineDifference(AUTOSTART_TEXT, added.text), "added:22");
            check("autostart add: the file still ends with exactly one newline",
                  /[^\n]\n$/.test(added.text), true);
            check("autostart add: and the new line is the last one",
                  added.text.split("\n")[21], "o.launch_on_start(\"obsidian\")");
            check("autostart add: the reader takes the new line back as an entry",
                  Model.parseAutostartLua(added.text, "autostart.lua").length, 8);
            check("autostart add: and as an editable one",
                  Model.parseAutostartLua(added.text, "autostart.lua")[7].editable, true);
            check("autostart add: with the command that was asked for",
                  Model.parseAutostartLua(added.text, "autostart.lua")[7].command, "obsidian");

            // --- change: exactly the line named, no other ---------------------
            var changedLive = LIVE.slice();
            changedLive[3] = "o.launch_on_start(\"notes-app --disable-gpu\")";
            var changed = Model.autostartApply(
                AUTOSTART_TEXT,
                { action: "change", line: 4, command: "notes-app --disable-gpu" });
            check("autostart change: it succeeds", changed.ok, true);
            check("autostart change: the whole new text, byte for byte",
                  changed.text, changedLive.concat([""]).join("\n"));
            check("autostart change: old and new differ in exactly ONE line, line 4",
                  Model.oneLineDifference(AUTOSTART_TEXT, changed.text), "changed:4");
            check("autostart change: the line count is unchanged",
                  changed.text.split("\n").length, AUTOSTART_TEXT.split("\n").length);
            check("autostart change: his German comment on line 3 is untouched",
                  changed.text.split("\n")[2], "-- Dienstliche Kommunikation");

            // --- remove: exactly the line named, no other ---------------------
            var removedLive = LIVE.slice();
            removedLive.splice(11, 1);                 // line 12: o.launch_on_start("nimbus")
            var removed = Model.autostartApply(AUTOSTART_TEXT,
                                               { action: "remove", line: 12 });
            check("autostart remove: it succeeds", removed.ok, true);
            check("autostart remove: the whole new text, byte for byte",
                  removed.text, removedLive.concat([""]).join("\n"));
            check("autostart remove: old and new differ in exactly ONE line, line 12",
                  Model.oneLineDifference(AUTOSTART_TEXT, removed.text), "removed:12");
            check("autostart remove: the file is one line shorter",
                  removed.text.split("\n").length,
                  AUTOSTART_TEXT.split("\n").length - 1);
            check("autostart remove: the blank line that followed it is still there",
                  removed.text.split("\n")[11], "");
            check("autostart remove: and the entry is gone from the reader's answer",
                  Model.parseAutostartLua(removed.text, "autostart.lua").length, 6);
            check("autostart remove: the file still ends with exactly one newline",
                  /[^\n]\n$/.test(removed.text), true);

            // --- THE NON-EDITABLE ENTRY, which is his Chat line -----------
            //
            // Line 8 of his file:
            //   o.exec_on_start(o.launch_webapp_sole("Chat", "https://..."))
            // The plugin SHOWS it and does not touch it. Neither operation may
            // reach it, and neither may return any text at all -- a refusal that
            // still carried a candidate would be one accidental write away from
            // deleting a line whose meaning this plugin does not understand.
            var refusedChange = Model.autostartApply(AUTOSTART_TEXT,
                                                     { action: "change", line: 8, command: "x" });
            var refusedRemove = Model.autostartApply(AUTOSTART_TEXT,
                                                     { action: "remove", line: 8 });
            check("autostart non-editable: change is refused", refusedChange.ok, false);
            check("autostart non-editable: change says why", refusedChange.error,
                  "entry-not-editable");
            check("autostart non-editable: change produces no text at all",
                  refusedChange.text, undefined);
            check("autostart non-editable: remove is refused", refusedRemove.ok, false);
            check("autostart non-editable: remove says why", refusedRemove.error,
                  "entry-not-editable");
            check("autostart non-editable: remove produces no text at all",
                  refusedRemove.text, undefined);
            check("autostart non-editable: the line it protects is the Chat one",
                  AUTOSTART_LINES[7],
                  "o.exec_on_start(o.launch_webapp_sole(\"Chat\", \"https://chat.example.org/\"))");
            check("autostart non-editable: a commented-out line cannot be reached either",
                  Model.autostartApply("--[[\no.launch_on_start(\"x\")\n]]\n",
                                       { action: "remove", line: 2 }).error,
                  "no-entry-on-line");

            // --- lines that are not entries -----------------------------------
            check("autostart line: a comment line holds no entry",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "remove", line: 3 }).error,
                  "no-entry-on-line");
            check("autostart line: a blank line holds no entry",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "remove", line: 2 }).error,
                  "no-entry-on-line");
            check("autostart line: line 0 is not a line",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "remove", line: 0 }).error,
                  "no-entry-on-line");
            check("autostart line: a line past the end is not a line",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "remove", line: 999 }).error,
                  "no-entry-on-line");
            check("autostart line: a fractional line number is not a line",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "remove", line: 4.5 }).error,
                  "no-entry-on-line");
            check("autostart line: no line number at all is not a line",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "remove" }).error,
                  "no-entry-on-line");
            check("autostart operation: an operation this writer does not know is refused",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "reorder", line: 4 }).error,
                  "unknown-operation");
            check("autostart operation: no operation at all is refused",
                  Model.autostartApply(AUTOSTART_TEXT, undefined).error, "unknown-operation");

            // --- THE ESCAPING ROUND TRIP --------------------------------------
            //
            // Write the command, read the generated line back with
            // parseAutostartLua, and require the command to come out identical.
            // A readable escaper is only worth having if it is reversible, and
            // the reader is the thing that has to reverse it -- so the proof
            // goes through the reader rather than through a second escaper
            // written to agree with the first.
            //
            // One helper, one check() per input: the assertion-count guard
            // requires countable call sites, so no loop.
            // Split in two so the proof can be turned on itself: roundTripWith
            // takes the LINE, so a line that was not generated from the command
            // can be handed to the same comparison. A proof that cannot fail is
            // not a proof, and this project has shipped one of those before.
            function roundTripWith(line, command) {
                var back = Model.parseAutostartLua(line + "\n", "autostart.lua");
                if (back.length !== 1) return "parsed " + back.length + " entries";
                if (back[0].editable !== true) return "not editable: " + back[0].reason;
                if (back[0].launcher !== "uwsm-app") return "launcher " + back[0].launcher;
                if (back[0].command !== command) return "came back as " + back[0].command;
                return "";
            }
            function roundTrip(command) {
                return roundTripWith(Model.autostartLine(command), command);
            }
            check("autostart escape round trip: a single quote",
                  roundTrip("nimbus --app='https://example.com/x'"), "");
            check("autostart escape round trip: a double quote",
                  roundTrip("sh -c \"echo hi\""), "");
            check("autostart escape round trip: a backslash",
                  roundTrip("wine C:\\dir\\app.exe"), "");
            check("autostart escape round trip: a command substitution",
                  roundTrip("nimbus --user-data-dir=$(mktemp -d)"), "");
            check("autostart escape round trip: a semicolon",
                  roundTrip("sh -c 'a; b'"), "");
            check("autostart escape round trip: a percent sign",
                  roundTrip("printf 100% done"), "");
            check("autostart escape round trip: arguments and a --flag=value",
                  roundTrip("nimbus --app=https://mail.example.com/mail/ --new-window"),
                  "");
            check("autostart escape round trip: all of them at once",
                  roundTrip("sh -c 'printf \"%s\\n\" $(echo a;b)' --flag=v"), "");
            check("autostart escape round trip: the proof itself notices a mangled line",
                  roundTripWith("o.launch_on_start(\"other\")", "nimbus"),
                  "came back as other");
            check("autostart escape round trip: and a line it cannot read at all",
                  roundTripWith("o.exec_on_start(o.launch_webapp_sole(\"a\", \"b\"))", "a")
                      .indexOf("not editable") >= 0, true);

            // The generated line, spelled out once so the shape is not only
            // asserted through the reader.
            check("autostart line: the shape it writes",
                  Model.autostartLine("nimbus"), "o.launch_on_start(\"nimbus\")");
            check("autostart line: a double quote is escaped, not encoded",
                  Model.autostartLine("a\"b"), "o.launch_on_start(\"a\\\"b\")");
            check("autostart line: a backslash is escaped",
                  Model.autostartLine("a\\b"), "o.launch_on_start(\"a\\\\b\")");
            check("autostart line: nothing else is escaped, so a person can read it",
                  Model.autostartLine("nimbus --app=https://x/?a=1&b=2"),
                  "o.launch_on_start(\"nimbus --app=https://x/?a=1&b=2\")");
            check("autostart line: it is not the byte encoding the eval route uses",
                  Model.autostartLine("nimbus").indexOf("string.char"), -1);

            // --- what is refused, and it is refused rather than encoded -------
            check("autostart refusal: an empty command",
                  Model.autostartCommandRefusal(""), "empty-command");
            check("autostart refusal: a command of only spaces and tabs",
                  Model.autostartCommandRefusal(" \t "), "empty-command");
            check("autostart refusal: a line break",
                  Model.autostartCommandRefusal("a\nb"), "unwritable-character");
            check("autostart refusal: a carriage return",
                  Model.autostartCommandRefusal("a\rb"), "unwritable-character");
            check("autostart refusal: a tab inside the command",
                  Model.autostartCommandRefusal("a\tb"), "unwritable-character");
            check("autostart refusal: a NUL byte",
                  Model.autostartCommandRefusal("a" + String.fromCharCode(0) + "b"),
                  "unwritable-character");
            check("autostart refusal: a control character",
                  Model.autostartCommandRefusal("a" + String.fromCharCode(7) + "b"),
                  "unwritable-character");
            check("autostart refusal: a DEL",
                  Model.autostartCommandRefusal("a" + String.fromCharCode(127) + "b"),
                  "unwritable-character");
            check("autostart refusal: a Unicode line separator",
                  Model.autostartCommandRefusal("a" + String.fromCharCode(0x2028) + "b"),
                  "unwritable-character");
            check("autostart refusal: one character too long",
                  Model.autostartCommandRefusal(new Array(502).join("x")),
                  "command-too-long");
            check("autostart refusal: exactly at the cap is allowed",
                  Model.autostartCommandRefusal(new Array(501).join("x")), null);
            check("autostart refusal: an ordinary command is not refused",
                  Model.autostartCommandRefusal("nimbus --app=https://x/"), null);
            check("autostart refusal: non-ASCII text is written, not refused",
                  Model.autostartCommandRefusal("nimbus --app=https://x/\u00fcber"), null);
            check("autostart refusal: and it round-trips",
                  roundTrip("nimbus /home/user/B\u00fccher/a.pdf"), "");
            check("autostart refusal: add carries the refusal through",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "add", command: "a\nb" }).error,
                  "unwritable-character");
            check("autostart refusal: and produces no text",
                  Model.autostartApply(AUTOSTART_TEXT, { action: "add", command: "" }).text,
                  undefined);
            check("autostart refusal: change carries it through too",
                  Model.autostartApply(AUTOSTART_TEXT,
                                       { action: "change", line: 4, command: "" }).error,
                  "empty-command");
            check("autostart refusal: a refused change leaves the editable check passed first",
                  Model.autostartApply(AUTOSTART_TEXT,
                                       { action: "change", line: 8, command: "" }).error,
                  "entry-not-editable");

            // luaQuote THROWS rather than returning something, so a call site
            // that forgot to ask autostartCommandRefusal() first cannot smuggle
            // a line break into a file that runs at login.
            checkThrows("autostart escape: luaQuote refuses a line break outright",
                        function() { Model.luaQuote("a\nb"); },
                        /not writable as a Lua string literal/);
            checkThrows("autostart escape: and a NUL",
                        function() { Model.luaQuote(String.fromCharCode(0)); },
                        /not writable as a Lua string literal/);
            check("autostart escape: but it quotes what it accepts",
                  Model.luaQuote("a\"b\\c"), "\"a\\\"b\\\\c\"");

            // --- the one-line assertion's own proof ---------------------------
            //
            // The assertion every surgery case above rests on. If it reported
            // "one line" for two edits, every one of those cases would be
            // decoration -- so it is tested against inputs that differ in two.
            check("one line difference: identical text",
                  Model.oneLineDifference(AUTOSTART_TEXT, AUTOSTART_TEXT), "same");
            check("one line difference: two changed lines is not one",
                  Model.oneLineDifference("a\nb\nc\n", "a\nB\nC\n"), "multiple");
            check("one line difference: two added lines is not one",
                  Model.oneLineDifference("a\nb\n", "a\nb\nc\nd\n"), "multiple");
            check("one line difference: two removed lines is not one",
                  Model.oneLineDifference("a\nb\nc\nd\n", "a\nb\n"), "multiple");
            check("one line difference: an insert plus a change is not one",
                  Model.oneLineDifference("a\nb\nc\n", "a\nX\nb\nC\n"), "multiple");
            check("one line difference: a line inserted in the middle",
                  Model.oneLineDifference("a\nb\nc\n", "a\nX\nb\nc\n"), "added:2");
            check("one line difference: a line removed from the middle",
                  Model.oneLineDifference("a\nb\nc\n", "a\nc\n"), "removed:2");
            check("one line difference: a line changed at the front",
                  Model.oneLineDifference("a\nb\n", "A\nb\n"), "changed:1");
            check("one line difference: a trailing newline is not a line",
                  Model.oneLineDifference("a\nb\n", "a\nb"), "same");
            check("one line difference: a swap of two lines is not one line",
                  Model.oneLineDifference("a\nb\n", "b\na\n"), "multiple");

            // --- the edges of the file itself ---------------------------------
            check("autostart edge: an empty file gains its first line",
                  Model.autostartApply("", { action: "add", command: "nimbus" }).text,
                  "o.launch_on_start(\"nimbus\")\n");
            check("autostart edge: and that is one line added",
                  Model.oneLineDifference("", Model.autostartApply(
                      "", { action: "add", command: "nimbus" }).text), "added:1");
            check("autostart edge: a file with no final newline gets one",
                  Model.autostartApply("o.launch_on_start(\"a\")",
                                       { action: "add", command: "b" }).text,
                  "o.launch_on_start(\"a\")\no.launch_on_start(\"b\")\n");
            check("autostart edge: and that is still one line added",
                  Model.oneLineDifference("o.launch_on_start(\"a\")",
                      Model.autostartApply("o.launch_on_start(\"a\")",
                                           { action: "add", command: "b" }).text),
                  "added:2");
            check("autostart edge: removing the only line leaves an empty file",
                  Model.autostartApply("o.launch_on_start(\"a\")\n",
                                       { action: "remove", line: 1 }).text, "");
            // The line cap comes from Model.js rather than being spelled again
            // here: an Array of n joined with "x\n" gives n-1 content lines.
            var atLineCap   = new Array(Model.MAX_HYPR_LINES + 1).join("x\n");
            var pastLineCap = new Array(Model.MAX_HYPR_LINES + 2).join("x\n");
            check("autostart edge: the two cap fixtures really straddle the cap",
                  Model.autostartContentLines(atLineCap).length + ","
                  + Model.autostartContentLines(pastLineCap).length,
                  Model.MAX_HYPR_LINES + "," + (Model.MAX_HYPR_LINES + 1));
            check("autostart edge: a file longer than the reader looks at is not edited",
                  Model.autostartApply(pastLineCap,
                                       { action: "add", command: "nimbus" }).error,
                  "file-too-long");
            check("autostart edge: a file exactly at the cap still is",
                  Model.autostartApply(atLineCap,
                                       { action: "add", command: "nimbus" }).ok, true);

            // --- the refusal wording ------------------------------------------
            //
            // The same two-sided guarantee hyprReasonText has: every code
            // autostartApply can return has plain wording, and the assertions
            // above are what prove the list is the set it actually returns.
            check("autostart wording: every refusal code has plain wording",
                  unwordedAmong(Model.autostartWriteReasons(),
                                Model.autostartWriteReasonText), "");
            check("autostart wording: the list it checks is not empty",
                  Model.autostartWriteReasons().length, 7);
            check("autostart wording: an absent code does not print undefined",
                  Model.autostartWriteReasonText(undefined).indexOf("undefined"), -1);
            check("autostart wording: an unknown code is named, not shown bare",
                  Model.autostartWriteReasonText("brand-new").indexOf("brand-new") >= 0, true);
            check("autostart wording: the non-editable refusal names hand editing",
                  Model.autostartWriteReasonText("entry-not-editable").indexOf("by hand") >= 0,
                  true);
            check("autostart wording: what happens after a write is the next login",
                  Model.autostartWrittenText().indexOf("next login") >= 0, true);
            check("autostart wording: and that nothing is started or reloaded",
                  Model.autostartWrittenText().indexOf("starts nothing and reloads nothing") >= 0,
                  true);


            // --- FROM A RUNNING PROGRAM TO AN AUTOSTART COMMAND --------------
            //
            // THE FIXTURES ARE HIS OWN SESSION, measured on 2026-09-02 with
            // `hyprctl -j clients`, /proc/<pid>/cmdline and
            // bin/omarchy-autostart-apps -- not invented shapes. The three
            // cases that make this a choice rather than a mapping are all in
            // here: the AppImage mount path, the three windows of one nimbus
            // process, and the .desktop file with the right command and no
            // StartupWMClass.
            var hisApps = [
                { name: "Termpane", exec: "termpane", wmclass: "Termpane", icon: "" },
                // Sorts BEFORE Webmail (Nimbus) in his real list, and that is
                // load-bearing: without the host-token ordering the Webmail
                // window offers YouTube Music first.
                { name: "YouTube Music",
                  exec: "/opt/nimbus-bin/nimbus --profile-directory=Default --app-id=cinhimbnkkaeohfgghhklpknlkffjgod",
                  wmclass: "crx_cinhimbnkkaeohfgghhklpknlkffjgod", icon: "" },
                // ~/.local/share/applications/Webmail-nimbus.desktop, verbatim:
                // the right command, and NO StartupWMClass.
                { name: "Webmail (Nimbus)",
                  exec: "nimbus --app=https://mail.example.com/mail/", wmclass: "", icon: "" },
                { name: "Nimbus", exec: "nimbus %U", wmclass: "nimbus-browser", icon: "" },
                { name: "Modelbox", exec: "modelbox %U", wmclass: "LM-Studio", icon: "" },
                { name: "Vaultkey", exec: "vaultkey %f", wmclass: "vaultkey", icon: "" },
                { name: "Chatterbox", exec: "Chatterbox -- %U", wmclass: "ChatterboxDesktop", icon: "" },
                { name: "Signal", exec: "msgbox-desktop -- %u", wmclass: "signal", icon: "" },
                { name: "Microsoft Teams for Linux",
                  exec: "notes-app --gtk-version=3 %U", wmclass: "", icon: "" },
                { name: "Chat", exec: "omarchy-launch-webapp https://chat.example.org/",
                  wmclass: "", icon: "" }
            ];

            // His ~/.config/hypr/autostart.lua, verbatim. notes-app is
            // in it and signal is not -- which is what the already-present
            // warnings are judged against.
            var hisAutostart =
                "-- Autostart. Portiert aus autostart.conf.\n"
              + "\n"
              + "-- Dienstliche Kommunikation\n"
              + "o.launch_on_start(\"notes-app\")\n"
              + "o.launch_on_start(\"nimbus --app=https://mail.example.com/mail/\")\n"
              + "\n"
              + "-- Private Kommunikation\n"
              + "o.exec_on_start(o.launch_webapp_sole(\"Chat\", \"https://chat.example.org/\"))\n"
              + "o.launch_on_start(\"Chatterbox\")\n"
              + "\n"
              + "-- Browser\n"
              + "o.launch_on_start(\"nimbus\")\n"
              + "\n"
              + "-- Schluesselverwaltung\n"
              + "o.launch_on_start(\"keyring-gui\")\n"
              + "\n"
              + "-- Modelbox (am 28.08.2026 nach dem Upgrade neu installiert).\n"
              + "o.launch_on_start(\"modelbox\")\n";
            var hisEntries = Model.parseAutostartLua(hisAutostart, "autostart.lua");

            // The command line all three nimbus windows report, verbatim from
            // /proc/1866/cmdline. It ENDS in --app=https://mail.example.com/
            // mail/, so the plain browser window reports a line that is wrong
            // for it -- which no amount of parsing can detect.
            var braveRunning =
                "/opt/nimbus-bin/nimbus --ozone-platform=wayland --ozone-platform-hint=wayland"
              + " --enable-features=TouchpadOverscrollHistoryNavigation"
              + " --load-extension=/usr/share/omarchy/default/chromium/extensions/copy-url,"
              + "/usr/share/omarchy/default/chromium/extensions/yt-dlp,"
              + "/usr/share/omarchy/default/chromium/extensions/chat-slim"
              + " --password-store=gnome-libsecret --app=https://mail.example.com/mail/";

            function forWindow(windowClass, command, program) {
                return Model.autostartCandidatesForWindow(
                    { "class": windowClass, title: "t", command: command,
                      program: program, address: "0x1", workspace: "1", monitor: "DP-4" },
                    hisApps, hisEntries);
            }
            // The whole ordered list as one comparable string: source, the
            // Name= it came from, the command, and every warning. Order is
            // part of the answer, so it is part of the assertion.
            function rendered(list) {
                var out = [];
                for (var r = 0; r < list.length; r++) {
                    out.push(list[r].source + "|" + list[r].name + "|" + list[r].command
                             + (list[r].warnings.length > 0
                                ? "|!" + list[r].warnings.join("+") : ""));
                }
                return out.join("  ,  ");
            }

            check("candidates fixture: his autostart.lua reads back six editable entries",
                  hisEntries.length + "/" + Model.hyprEditableCount(
                      [{ name: "autostart.lua", entries: hisEntries }]), "7/6");

            // --- one assertion per row of the measured table ------------------
            check("candidates row: org.example.chatterbox",
                  rendered(forWindow("org.example.chatterbox", "/usr/bin/Chatterbox", "Chatterbox")),
                  "desktop-binary|Chatterbox|Chatterbox --|!program-already-present"
                  + "  ,  running||/usr/bin/Chatterbox|!program-already-present");
            check("candidates row: org.vaultkey.Vaultkey",
                  rendered(forWindow("org.vaultkey.Vaultkey", "/usr/bin/vaultkey", "vaultkey")),
                  "desktop-binary|Vaultkey|vaultkey"
                  + "  ,  running||/usr/bin/vaultkey");
            check("candidates row: notes-app",
                  rendered(forWindow("notes-app", "/opt/notes-app/notes-app",
                                     "notes-app")),
                  "desktop-binary|Microsoft Teams for Linux|notes-app --gtk-version=3"
                  + "|!program-already-present"
                  + "  ,  running||/opt/notes-app/notes-app|!program-already-present");
            check("candidates row: signal",
                  rendered(forWindow("signal", "/usr/lib/msgbox-desktop/msgbox-desktop",
                                     "msgbox-desktop")),
                  "desktop-class|Signal|msgbox-desktop --"
                  + "  ,  running||/usr/lib/msgbox-desktop/msgbox-desktop");
            check("candidates row: Termpane",
                  rendered(forWindow("Termpane", "/usr/bin/termpane --working-directory=/home/user",
                                     "termpane")),
                  "desktop-class|Termpane|termpane"
                  + "  ,  running||/usr/bin/termpane --working-directory=/home/user");
            check("candidates row: ai.elementlabs.modelbox",
                  rendered(forWindow("ai.elementlabs.modelbox", "/tmp/.mount_lm-stuFjMMHD/modelbox",
                                     "modelbox")),
                  "desktop-binary|Modelbox|modelbox|!already-present"
                  + "  ,  running||/tmp/.mount_lm-stuFjMMHD/modelbox"
                  + "|!unstable-path+program-already-present");
            check("candidates row: nimbus-browser",
                  rendered(forWindow("nimbus-browser", braveRunning, "nimbus")),
                  "desktop-class|Nimbus|nimbus|!already-present"
                  + "  ,  desktop-binary|YouTube Music|/opt/nimbus-bin/nimbus"
                  + " --profile-directory=Default --app-id=cinhimbnkkaeohfgghhklpknlkffjgod"
                  + "|!program-already-present"
                  + "  ,  desktop-binary|Webmail (Nimbus)|nimbus"
                  + " --app=https://mail.example.com/mail/|!already-present"
                  + "  ,  running||" + braveRunning + "|!program-already-present");
            check("candidates row: nimbus-mail.example.com__mail_-Default",
                  rendered(forWindow("nimbus-mail.example.com__mail_-Default", braveRunning, "nimbus")),
                  "desktop-binary|Webmail (Nimbus)|nimbus"
                  + " --app=https://mail.example.com/mail/|!already-present"
                  + "  ,  desktop-binary|YouTube Music|/opt/nimbus-bin/nimbus"
                  + " --profile-directory=Default --app-id=cinhimbnkkaeohfgghhklpknlkffjgod"
                  + "|!program-already-present"
                  + "  ,  desktop-binary|Nimbus|nimbus|!already-present"
                  + "  ,  running||" + braveRunning + "|!program-already-present");
            check("candidates row: nimbus-chat.example.org__-Default",
                  rendered(forWindow("nimbus-chat.example.org__-Default", braveRunning, "nimbus")),
                  "desktop-binary|YouTube Music|/opt/nimbus-bin/nimbus"
                  + " --profile-directory=Default --app-id=cinhimbnkkaeohfgghhklpknlkffjgod"
                  + "|!program-already-present"
                  + "  ,  desktop-binary|Webmail (Nimbus)|nimbus"
                  + " --app=https://mail.example.com/mail/|!already-present"
                  + "  ,  desktop-binary|Nimbus|nimbus|!already-present"
                  + "  ,  running||" + braveRunning + "|!program-already-present");

            // --- THE OUTLOOK CASE, named ------------------------------------
            //
            // A .desktop file with NO StartupWMClass whose Exec starts with
            // the same program as the running window. This is the only route
            // that reaches it, and the suggestion must be that command --
            // never the /proc line, which belongs to a browser process
            // serving three windows at once.
            var webmail = forWindow("nimbus-mail.example.com__mail_-Default", braveRunning, "nimbus");
            check("webmail case: the top suggestion is the .desktop command",
                  webmail[0].command, "nimbus --app=https://mail.example.com/mail/");
            check("webmail case: and it is found by binary, not by class",
                  webmail[0].source, "desktop-binary");
            check("webmail case: it is NOT the /proc line",
                  webmail[0].command === braveRunning, false);
            check("webmail case: the Name= is carried so five nimbus entries can be told apart",
                  webmail[0].name, "Webmail (Nimbus)");
            check("webmail case: nothing at all matched by class",
                  (function() {
                      var n = 0;
                      for (var q = 0; q < webmail.length; q++) {
                          if (webmail[q].source === "desktop-class") n++;
                      }
                      return n;
                  })(), 0);
            check("webmail case: the desktop entry it comes from really has no StartupWMClass",
                  hisApps[2].name + "/" + hisApps[2].wmclass, "Webmail (Nimbus)/");
            check("webmail case: the host token out of the window class",
                  Model.classHostToken("nimbus-mail.example.com__mail_-Default"),
                  "mail.example.com");
            check("webmail case: the browser name in front of the host is not part of it",
                  Model.classHostToken("nimbus-mail.example.com__mail_-Default")
                  .indexOf("nimbus"), -1);
            check("webmail case: a class with no dotted token has none",
                  Model.classHostToken("Termpane"), "");
            check("webmail case: a host whose own label has a hyphen still yields a substring",
                  Model.classHostToken("nimbus-web-app.example.com__-Default"), "app.example.com");
            check("webmail case: the ordering signal is what puts it first",
                  Model.classHostToken("nimbus-mail.example.com__mail_-Default").length > 0
                  && "nimbus --app=https://mail.example.com/mail/".indexOf(
                         Model.classHostToken("nimbus-mail.example.com__mail_-Default")) >= 0,
                  true);
            check("webmail case: and the runner-up does NOT carry that token",
                  hisApps[1].exec.indexOf("mail.example.com"), -1);

            // --- THE LM STUDIO CASE, named ----------------------------------
            //
            // The most important warning in this task: a path that exists
            // today and not after a restart, written into a file nobody looks
            // at again until it silently stops working.
            var modelbox = forWindow("ai.elementlabs.modelbox",
                                     "/tmp/.mount_lm-stuFjMMHD/modelbox", "modelbox");
            check("lm studio case: the running line is warned about",
                  modelbox[1].warning, "unstable-path");
            check("lm studio case: it is the running command that carries it",
                  modelbox[1].source + "|" + modelbox[1].command,
                  "running|/tmp/.mount_lm-stuFjMMHD/modelbox");
            check("lm studio case: the duplicate warning is not suppressed by it",
                  modelbox[1].warnings.join("+"), "unstable-path+program-already-present");
            check("lm studio case: the .desktop suggestion above it has no path at all",
                  modelbox[0].command, "modelbox");
            check("lm studio case: /tmp is unstable",
                  Model.commandIsUnstablePath("/tmp/.mount_x/modelbox"), true);
            check("lm studio case: /run is unstable",
                  Model.commandIsUnstablePath("/run/user/1000/appimage/thing"), true);
            check("lm studio case: /proc is unstable",
                  Model.commandIsUnstablePath("/proc/self/cwd/thing"), true);
            check("lm studio case: /dev/shm is unstable",
                  Model.commandIsUnstablePath("/dev/shm/thing"), true);
            check("lm studio case: a .mount_ segment mid-path is unstable wherever it sits",
                  Model.commandIsUnstablePath("/home/user/.cache/.mount_abc123/modelbox"), true);
            check("lm studio case: a mount segment after a space is caught too",
                  Model.commandIsUnstablePath("env FOO=1 .mount_abc/modelbox"), true);
            check("lm studio case: /usr/bin is not unstable",
                  Model.commandIsUnstablePath("/usr/bin/vaultkey"), false);
            check("lm studio case: a bare program name is not unstable",
                  Model.commandIsUnstablePath("modelbox"), false);
            check("lm studio case: /tmpfoo is not /tmp -- the prefix ends at the slash",
                  Model.commandIsUnstablePath("/tmpfoo/modelbox"), false);
            check("lm studio case: a mount-like word that is not a path segment is not caught",
                  Model.commandIsUnstablePath("nimbus --mount_point=/x"), false);

            // --- already-present, against his real file ----------------------
            check("already-present: notes-app is in his autostart.lua",
                  forWindow("notes-app", "/opt/notes-app/notes-app",
                            "notes-app")[0].warning, "program-already-present");
            check("already-present: and signal is not",
                  forWindow("signal", "/usr/lib/msgbox-desktop/msgbox-desktop",
                            "msgbox-desktop")[0].warning, "");
            check("already-present: an exact match is told apart from the same program",
                  forWindow("ai.elementlabs.modelbox", "/tmp/.mount_x/modelbox",
                            "modelbox")[0].warning, "already-present");
            check("already-present: nothing is warned about with no file to compare against",
                  Model.autostartCandidatesForWindow(
                      { "class": "notes-app", command: "notes-app", program: "notes-app" },
                      hisApps, [])[0].warning, "");
            check("already-present: the nested webapp line carries no command, so it warns nothing",
                  Model.autostartCandidatesForWindow(
                      { "class": "x", command: "omarchy-launch-webapp https://chat.example.org/",
                        program: "omarchy-launch-webapp" },
                      hisApps, hisEntries)[0].warning, "");
            check("already-present: spacing does not make a command a different one",
                  Model.autostartCandidatesForWindow(
                      { "class": "x", command: "nimbus   --app=https://mail.example.com/mail/",
                        program: "nimbus" },
                      [], hisEntries)[0].warning, "already-present");

            // --- three windows, one command line ----------------------------
            //
            // Three windows of one nimbus process are THREE entries with three
            // different answers, not one. The classes differ, so the lists
            // differ -- and that is the only thing that tells the Webmail
            // window from the browser window at all.
            var braveWindows = [
                forWindow("nimbus-browser", braveRunning, "nimbus"),
                forWindow("nimbus-mail.example.com__mail_-Default", braveRunning, "nimbus"),
                forWindow("nimbus-chat.example.org__-Default", braveRunning, "nimbus")
            ];
            check("three windows: each gets its own list",
                  braveWindows.length, 3);
            check("three windows: and the three lists are not the same list",
                  (rendered(braveWindows[0]) !== rendered(braveWindows[1]))
                  && (rendered(braveWindows[1]) !== rendered(braveWindows[2]))
                  && (rendered(braveWindows[0]) !== rendered(braveWindows[2])), true);
            check("three windows: the top suggestion differs where the class does",
                  braveWindows[0][0].command + " / " + braveWindows[1][0].command,
                  "nimbus / nimbus --app=https://mail.example.com/mail/");
            check("three windows: all three report the identical running command",
                  braveWindows[0][braveWindows[0].length - 1].command
                  === braveWindows[1][braveWindows[1].length - 1].command
                  && braveWindows[1][braveWindows[1].length - 1].command === braveRunning, true);

            // --- a window with nothing to offer -----------------------------
            check("no candidates: a window with no match and no command line",
                  forWindow("some.unknown.thing", "", "").length, 0);
            check("no candidates: and it says why",
                  Model.autostartCandidateReason(
                      { "class": "some.unknown.thing", command: "", program: "" }, []),
                  "no-command-line");
            check("no candidates: a command line past the writer cap is a different reason",
                  Model.autostartCandidateReason(
                      { "class": "some.unknown.thing", command: "", program: "huge" }, []),
                  "command-too-long");
            check("no candidates: a window that HAS suggestions gives no reason",
                  Model.autostartCandidateReason(
                      { "class": "signal", command: "", program: "" },
                      forWindow("signal", "", "")), "");
            check("no candidates: an empty class still offers its running line",
                  rendered(forWindow("", "/usr/bin/odd --flag", "odd")),
                  "running||/usr/bin/odd --flag");
            check("no candidates: an empty class matches no .desktop by class",
                  Model.autostartCandidatesForWindow(
                      { "class": "", command: "", program: "" },
                      [{ name: "Odd", exec: "odd", wmclass: "" }], []).length, 0);

            // --- field codes never reach a suggestion -----------------------
            check("field codes: %U is gone from the Chatterbox suggestion",
                  forWindow("org.example.chatterbox", "/usr/bin/Chatterbox", "Chatterbox")[0].command,
                  "Chatterbox --");
            check("field codes: no suggestion for any measured window contains a percent sign",
                  (function() {
                      var all = [
                          forWindow("org.example.chatterbox", "/usr/bin/Chatterbox", "Chatterbox"),
                          forWindow("signal", "/usr/lib/msgbox-desktop/msgbox-desktop", "msgbox-desktop"),
                          forWindow("nimbus-browser", braveRunning, "nimbus"),
                          forWindow("ai.elementlabs.modelbox", "/tmp/.mount_x/modelbox", "modelbox")
                      ];
                      var hits = 0;
                      for (var a = 0; a < all.length; a++) {
                          for (var b = 0; b < all[a].length; b++) {
                              if (all[a][b].command.indexOf("%") >= 0) hits++;
                          }
                      }
                      return hits;
                  })(), 0);
            check("field codes: a %f suggestion arrives stripped",
                  forWindow("org.vaultkey.Vaultkey", "/usr/bin/vaultkey", "vaultkey")[0].command,
                  "vaultkey");

            // --- the shape of the list itself -------------------------------
            //
            // THE DEDUPLICATION HAD NO ASSERTION AT ALL, and a mutation probe
            // is how that was found: replacing the `if (seen[...]) continue`
            // guard with `if (false) continue` left this whole suite green.
            // The assertion below it -- Termpane, which matches its own
            // .desktop by class and by binary -- cannot catch it, because the
            // `continue` after the by-class push is what makes that one entry,
            // not the deduplication. So the two inputs that DO produce a
            // duplicate command are asserted by name.
            //
            // First: the running command line is exactly what a .desktop
            // declares. This is the ordinary case, not a contrived one -- a
            // program started from its launcher runs the launcher's own Exec=.
            check("candidates: a running command equal to a .desktop command is offered once",
                  forWindow("Termpane", "termpane", "termpane").length, 1);
            check("candidates: and the one kept is the higher-ranked source",
                  forWindow("Termpane", "termpane", "termpane")[0].source, "desktop-class");
            // Second: two .desktop files declaring the same command, both
            // matched by the running program. Nothing upstream of the
            // deduplication can collapse these -- they are two different
            // entries of the application list.
            check("candidates: two .desktop files with the same command are offered once",
                  Model.autostartCandidatesForWindow(
                      { "class": "zzz", command: "/opt/x/myapp --x", program: "myapp" },
                      [{ name: "One", exec: "myapp", wmclass: "aaa" },
                       { name: "Two", exec: "myapp", wmclass: "bbb" }], []).length, 2);
            check("candidates: and it is the first of the two that is kept",
                  Model.autostartCandidatesForWindow(
                      { "class": "zzz", command: "/opt/x/myapp --x", program: "myapp" },
                      [{ name: "One", exec: "myapp", wmclass: "aaa" },
                       { name: "Two", exec: "myapp", wmclass: "bbb" }], [])[0].name, "One");
            // A .desktop matched by class is not ALSO offered as a binary
            // match: the loop takes its `continue` after the by-class push.
            // Two entries here, and the second is the running line.
            check("candidates: a .desktop matching by class is not offered a second time by binary",
                  forWindow("Termpane", "/usr/bin/termpane", "termpane").length, 2);
            check("candidates: the running line is offered last",
                  forWindow("Termpane", "/usr/bin/termpane", "termpane")[1].source, "running");
            check("candidates: the list is capped",
                  (function() {
                      var many = [];
                      for (var m = 0; m < 30; m++) {
                          many.push({ name: "App " + m, exec: "nimbus --app-id=" + m, wmclass: "" });
                      }
                      return Model.autostartCandidatesForWindow(
                          { "class": "nimbus-browser", command: "nimbus", program: "nimbus" },
                          many, []).length;
                  })(), Model.MAX_CANDIDATES);
            check("candidates: and the cap is not one",
                  Model.MAX_CANDIDATES >= 6, true);
            check("candidates: an application list of junk throws nothing",
                  Model.autostartCandidatesForWindow(
                      { "class": "x", command: "x", program: "x" },
                      [null, 7, "str", {}, { exec: undefined }], []).length, 1);
            check("candidates: no window at all is an empty list, not a throw",
                  Model.autostartCandidatesForWindow(undefined, undefined, undefined).length, 0);
            check("candidates: a command of __proto__ does not read back as already seen",
                  Model.autostartCandidatesForWindow(
                      { "class": "x", command: "__proto__", program: "__proto__" },
                      [], []).length, 1);

            // --- the two derivations both halves of the match depend on -----
            check("commandProgram: the basename of the first word",
                  Model.commandProgram("/opt/nimbus-bin/nimbus --ozone-platform=wayland"), "nimbus");
            check("commandProgram: a bare name is its own basename",
                  Model.commandProgram("nimbus --app=https://x/"), "nimbus");
            check("commandProgram: leading spaces do not become the program",
                  Model.commandProgram("   /usr/bin/vaultkey %f"), "vaultkey");
            check("commandProgram: nothing gives nothing",
                  Model.commandProgram(""), "");
            check("windowProgram: the field the window helper provides wins",
                  Model.windowProgram({ program: "nimbus", command: "" }), "nimbus");
            check("windowProgram: and it falls back to the command line",
                  Model.windowProgram({ command: "/usr/bin/termpane --working-directory=/home/user" }),
                  "termpane");
            check("windowProgram: a program field that is a path is reduced too",
                  Model.windowProgram({ program: "/tmp/.mount_x/modelbox" }), "modelbox");
            check("windowProgram: no window is no program",
                  Model.windowProgram(undefined), "");

            // --- what the picker shows for a window -------------------------
            check("window label: class and title",
                  Model.autostartWindowLabel({ "class": "signal", title: "Signal (139)" }),
                  "signal -- Signal (139)");
            check("window label: a window with no title is its class",
                  Model.autostartWindowLabel({ "class": "signal", title: "" }), "signal");
            check("window label: a window with no class is its title",
                  Model.autostartWindowLabel({ "class": "", title: "Signal" }), "Signal");
            check("window label: a window with neither is named as such",
                  Model.autostartWindowLabel({}), "(a window with no class and no title)");

            // --- the wording, with the same two-sided guarantee -------------
            check("candidate wording: every source has plain wording",
                  unwordedAmong(Model.candidateSources(), Model.candidateSourceText), "");
            check("candidate wording: every warning has plain wording",
                  unwordedAmong(Model.candidateWarnings(), Model.candidateWarningText), "");
            check("candidate wording: every empty reason has plain wording",
                  unwordedAmong(Model.candidateReasons(), Model.candidateReasonText), "");
            check("candidate wording: the three lists it checks are not empty",
                  Model.candidateSources().length + "/" + Model.candidateWarnings().length
                  + "/" + Model.candidateReasons().length, "3/3/2");
            check("candidate wording: every source the model can emit is in that list",
                  (function() {
                      var all = [
                          forWindow("nimbus-browser", braveRunning, "nimbus"),
                          forWindow("org.example.chatterbox", "/usr/bin/Chatterbox", "Chatterbox")
                      ];
                      var unknown = [];
                      for (var a = 0; a < all.length; a++) {
                          for (var b = 0; b < all[a].length; b++) {
                              if (Model.candidateSources().indexOf(all[a][b].source) === -1) {
                                  unknown.push(all[a][b].source);
                              }
                          }
                      }
                      return unknown.join(",");
                  })(), "");
            check("candidate wording: every warning the model can emit is in that list",
                  (function() {
                      var all = [
                          forWindow("nimbus-browser", braveRunning, "nimbus"),
                          forWindow("ai.elementlabs.modelbox", "/tmp/.mount_x/modelbox", "modelbox"),
                          forWindow("notes-app", "/opt/notes-app/notes-app",
                                    "notes-app")
                      ];
                      var unknown = [];
                      for (var a = 0; a < all.length; a++) {
                          for (var b = 0; b < all[a].length; b++) {
                              for (var c = 0; c < all[a][b].warnings.length; c++) {
                                  if (Model.candidateWarnings().indexOf(all[a][b].warnings[c]) === -1) {
                                      unknown.push(all[a][b].warnings[c]);
                                  }
                              }
                          }
                      }
                      return unknown.join(",");
                  })(), "");
            check("candidate wording: an unknown source is named, not shown bare",
                  Model.candidateSourceText("brand-new").indexOf("brand-new") >= 0, true);
            check("candidate wording: an unknown warning is named, not shown bare",
                  Model.candidateWarningText("brand-new").indexOf("brand-new") >= 0, true);
            check("candidate wording: an absent reason says nothing at all",
                  Model.candidateReasonText(""), "");
            check("candidate wording: an absent warning does not print undefined",
                  Model.candidateWarningText(undefined).indexOf("undefined"), -1);
            check("candidate wording: the unstable-path warning says what will happen",
                  Model.candidateWarningText("unstable-path").indexOf("after a restart") >= 0, true);
            check("candidate wording: and what to do instead",
                  Model.candidateWarningText("unstable-path").indexOf("without a path") >= 0, true);
            check("candidate wording: the running source says it is measured, not packaged",
                  Model.candidateSourceText("running").indexOf("running right now") >= 0, true);
            check("candidate wording: both empty reasons tell him to type it by hand",
                  (Model.candidateReasonText("no-command-line").indexOf("by hand") >= 0)
                  && (Model.candidateReasonText("command-too-long").indexOf("by hand") >= 0), true);

            console.warn("total=" + total + " failed=" + failed);
            Qt.exit(failed === 0 ? 0 : 1);
        } catch (e) {
            var brokeWith = String((e && e.message) || e);
            console.warn("ERROR: harness broke after test '" + (currentTestName || "<none yet>")
                         + "' -- the throw came either from that test or while evaluating the "
                         + "arguments of the one after it: " + brokeWith);
            Qt.exit(3);
        }
    }
}
