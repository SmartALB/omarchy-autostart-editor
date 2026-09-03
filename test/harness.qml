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
            // --- luaBytes: every value that reaches Lua is encoded as bytes ---
            check("luaBytes encodes ascii",
                  Model.luaBytes("ab"), "string.char(97,98)");
            check("luaBytes leaves no quote in the payload",
                  Model.luaBytes('a"b').indexOf('"'), -1);
            check("luaBytes leaves no brace in the payload",
                  Model.luaBytes("a}b").indexOf("}"), -1);
            check("luaBytes payload is digits and commas only",
                  /^string\.char\([0-9,]+\)$/.test(Model.luaBytes("^(cursor)$")), true);
            check("luaBytes accepts byte 126",
                  Model.luaBytes(String.fromCharCode(126)), "string.char(126)");
            checkThrows("luaBytes refuses byte 0",
                        function() { Model.luaBytes(String.fromCharCode(0)); },
                        /byte out of range/);
            checkThrows("luaBytes refuses byte 127",
                        function() { Model.luaBytes(String.fromCharCode(127)); },
                        /byte out of range/);
            checkThrows("luaBytes refuses non-ascii",
                        function() { Model.luaBytes("café"); },
                        /byte out of range/);

            // --- validate: allowlists ------------------------------------------
            function prog(over) {
                var p = { id: "p1", name: "Cursor", enabled: true,
                          command: "cursor", class: "^(cursor)$",
                          placement: { kind: "workspace", value: "6" } };
                for (var k in over) p[k] = over[k];
                return p;
            }
            function cfg(programs, workspaces) {
                return { schemaVersion: 1,
                         programs: programs || [],
                         workspaces: workspaces || [] };
            }

            check("validate accepts a sound program",
                  Model.validate(cfg([prog({})])).programs.length, 1);

            check("validate rejects a class containing a quote",
                  (Model.validate(cfg([prog({ "class": 'a"b' })])).rejected[0] || {}).reason,
                  "class-not-allowed");
            check("validate rejects a class containing a brace",
                  Model.validate(cfg([prog({ "class": "a}b" })])).rejected.length, 1);
            check("validate rejects a class containing a semicolon",
                  Model.validate(cfg([prog({ "class": "a;b" })])).rejected.length, 1);
            check("validate rejects a class containing an equals sign",
                  Model.validate(cfg([prog({ "class": "a=b" })])).rejected.length, 1);
            check("validate rejects a non-ascii class",
                  Model.validate(cfg([prog({ "class": "café" })])).rejected.length, 1);
            check("validate accepts the regex metacharacters a class needs",
                  Model.validate(cfg([prog({ "class": "^(nimbus-web\\.chat\\.com__-Default)$" })])).programs.length, 1);
            check("validate accepts an alternation class",
                  Model.validate(cfg([prog({ "class": "LM[- ]?Studio" })])).programs.length, 1);
            check("validate rejects a class of 201 characters",
                  Model.validate(cfg([prog({ "class": new Array(202).join("a") })])).rejected.length, 1);

            check("validate rejects workspace 0",
                  (Model.validate(cfg([prog({ placement: { kind: "workspace", value: "0" } })])).rejected[0] || {}).reason,
                  "placement-invalid");
            check("validate rejects workspace 100",
                  Model.validate(cfg([prog({ placement: { kind: "workspace", value: "100" } })])).rejected.length, 1);
            check("validate accepts workspace 99",
                  Model.validate(cfg([prog({ placement: { kind: "workspace", value: "99" } })])).programs.length, 1);
            check("validate accepts placement none",
                  Model.validate(cfg([prog({ placement: { kind: "none" } })])).programs.length, 1);
            check("validate rejects an unknown placement kind",
                  Model.validate(cfg([prog({ placement: { kind: "screen", value: "DP-4" } })])).rejected.length, 1);
            check("validate rejects a placement carrying both",
                  (Model.validate(cfg([prog({ placement: { kind: "workspace", value: "6", monitor: "DP-4" } })])).rejected[0] || {}).reason,
                  "placement-invalid");
            check("validate accepts a monitor placement",
                  Model.validate(cfg([prog({ placement: { kind: "monitor", value: "HDMI-A-1" } })])).programs.length, 1);
            check("validate rejects a monitor name with a quote",
                  Model.validate(cfg([prog({ placement: { kind: "monitor", value: 'a"b' } })])).rejected.length, 1);

            check("validate rejects an empty command",
                  (Model.validate(cfg([prog({ command: "" })])).rejected[0] || {}).reason, "command-invalid");
            check("validate rejects a command of 501 characters",
                  Model.validate(cfg([prog({ command: new Array(502).join("x") })])).rejected.length, 1);

            // "&&", "||" and "|" leave a shell command incomplete -- a syntax
            // error in any context, which no wrapping in launchCommand can
            // rescue. "&" and ";" are legitimate terminators and must still
            // be accepted.
            check("validate rejects a command ending in &&",
                  (Model.validate(cfg([prog({ command: "myapp &&" })])).rejected[0] || {}).reason,
                  "command-incomplete");
            check("validate rejects a command ending in ||",
                  (Model.validate(cfg([prog({ command: "myapp ||" })])).rejected[0] || {}).reason,
                  "command-incomplete");
            check("validate rejects a command ending in a pipe",
                  (Model.validate(cfg([prog({ command: "myapp |" })])).rejected[0] || {}).reason,
                  "command-incomplete");
            check("validate accepts a command ending in &",
                  Model.validate(cfg([prog({ command: "myapp &" })])).programs.length, 1);
            check("validate accepts a command ending in a semicolon",
                  Model.validate(cfg([prog({ command: "myapp;" })])).programs.length, 1);

            check("validate rejects a bad id",
                  (Model.validate(cfg([prog({ id: "P 1!" })])).rejected[0] || {}).reason, "id-invalid");

            check("validate caps the program count at 200",
                  (function() {
                      var many = [];
                      for (var i = 0; i < 205; i++) many.push(prog({ id: "p" + i }));
                      return Model.validate(cfg(many)).programs.length;
                  })(), 200);
            check("validate names the programs it dropped for being over the cap",
                  (function() {
                      var many = [];
                      for (var i = 0; i < 205; i++) many.push(prog({ id: "p" + i }));
                      var r = Model.validate(cfg(many)).rejected;
                      return r.length === 5 && (r[0] || {}).reason === "too-many";
                  })(), true);

            check("validate accepts a workspace row",
                  Model.validate(cfg([], [{ workspace: "1", monitor: "DP-4" }])).workspaces.length, 1);
            check("validate rejects a duplicate workspace row",
                  (Model.validate(cfg([], [{ workspace: "1", monitor: "DP-4" },
                                           { workspace: "1", monitor: "DP-3" }])).rejected[0] || {}).reason,
                  "workspace-duplicate");

            check("validate blocks two programs sharing a class with different placement",
                  (Model.validate(cfg([prog({ id: "a", placement: { kind: "workspace", value: "6" } }),
                                      prog({ id: "b", placement: { kind: "workspace", value: "7" } })])).blocked[0] || {}).reason,
                  "class-conflict");
            check("validate does not block two programs sharing a class with the same placement",
                  Model.validate(cfg([prog({ id: "a" }), prog({ id: "b" })])).blocked.length, 0);
            check("validate labels both sides of a class conflict",
                  (Model.validate(cfg([prog({ id: "a", name: "A", placement: { kind: "workspace", value: "6" } }),
                                      prog({ id: "b", name: "B", placement: { kind: "monitor", value: "DP-4" } })])).blocked[0] || {}).labels.length,
                  2);

            // A plain {} used as a map turns the class string "__proto__" into
            // Object.prototype instead of undefined -- the allowlist permits
            // "_", so this is a legal class value, and the map has to survive
            // it rather than the allowlist forbid it.
            check("validate survives a class named __proto__",
                  (function() {
                      try {
                          var r = Model.validate(cfg([prog({ id: "a", "class": "__proto__" }),
                                                      prog({ id: "b", "class": "__proto__" })]));
                          return "survived, blocked=" + r.blocked.length;
                      } catch (e) {
                          return "threw: " + ((e && e.message) || e);
                      }
                  })(), "survived, blocked=0");
            check("validate blocks a class conflict named __proto__",
                  (function() {
                      try {
                          var r = Model.validate(cfg([prog({ id: "a", "class": "__proto__", placement: { kind: "workspace", value: "6" } }),
                                                      prog({ id: "b", "class": "__proto__", placement: { kind: "workspace", value: "7" } })]));
                          return "survived, blocked=" + r.blocked.length;
                      } catch (e) {
                          return "threw: " + ((e && e.message) || e);
                      }
                  })(), "survived, blocked=1");

            // ID_RE is /^[a-z0-9]{1,16}$/, which permits "constructor",
            // "tostring" and "valueof" -- JS-special names on a plain object.
            // seenIds has to be prototype-less for the same reason byClass
            // does: a sole program named "constructor" must not be reported
            // as a duplicate of itself.
            check("validate accepts a sole program whose id is a JS-special name",
                  (function() {
                      var r = Model.validate(cfg([prog({ id: "constructor" })]));
                      return r.programs.length + "/" + ((r.rejected[0] || {}).reason || "none");
                  })(), "1/none");
            check("validate still catches a real duplicate id",
                  (function() {
                      var r = Model.validate(cfg([prog({ id: "constructor" }), prog({ id: "constructor" })]));
                      return r.programs.length + "/" + ((r.rejected[0] || {}).reason || "none");
                  })(), "1/id-duplicate");

            // A string has .length and bracket indexing, so a hand-edited
            // "programs": "cursor" would otherwise be walked character by
            // character and produce one meaningless rejection per letter
            // instead of one legible one.
            check("validate rejects a programs value that is a string, once",
                  (function() {
                      var r = Model.validate(cfg("cursor"));
                      return r.rejected.length + "/" + ((r.rejected[0] || {}).reason || "none");
                  })(), "1/not-a-list");
            check("validate does not treat an absent programs key as an error",
                  (function() {
                      var r = Model.validate({ schemaVersion: 1 });
                      return r.rejected.length;
                  })(), 0);

            // --- buildRuleChunks ----------------------------------------------
            function chunksFor(programs, workspaces) {
                return Model.buildRuleChunks(Model.validate(cfg(programs, workspaces)));
            }

            check("chunks: the first one resets",
                  chunksFor([], []).length >= 1
                  && chunksFor([], [])[0].indexOf("set_enabled(false)") !== -1, true);

            check("chunks: a workspace row becomes a workspace_rule",
                  chunksFor([], [{ workspace: "6", monitor: "HDMI-A-1" }])[1]
                      .indexOf("hl.workspace_rule") !== -1, true);

            check("chunks: a workspace placement uses the workspace field",
                  /workspace = string\.char/.test(
                      chunksFor([prog({ placement: { kind: "workspace", value: "6" } })], [])[1]), true);

            check("chunks: a monitor placement uses the monitor field",
                  /monitor = string\.char/.test(
                      chunksFor([prog({ placement: { kind: "monitor", value: "DP-4" } })], [])[1]), true);

            check("chunks: placement none produces no rule at all",
                  chunksFor([prog({ placement: { kind: "none" } })], []).length, 1);

            check("chunks: no chunk contains a quote character",
                  (function() {
                      var c = chunksFor([prog({}), prog({ id: "p2", "class": "LM[- ]?Studio" })],
                                        [{ workspace: "1", monitor: "DP-4" }]);
                      for (var i = 0; i < c.length; i++) {
                          if (c[i].indexOf('"') !== -1 || c[i].indexOf("'") !== -1) return "found in chunk " + i;
                      }
                      return "clean";
                  })(), "clean");

            check("chunks: every value arrives as string.char",
                  (function() {
                      var c = chunksFor([prog({})], [])[1];
                      // class, name, key and value -- four encoded strings per window rule
                      return (c.match(/string\.char\(/g) || []).length >= 4;
                  })(), true);

            // A grep over source cannot tell whether the SPECIFIC value was encoded --
            // one luaBytes( call anywhere on the line satisfies it. This asks the only
            // question that matters: does any configured value survive into the payload
            // as readable text? Distinctive values are used so a hit cannot be
            // coincidence.
            //
            // NOT covered here: the workspace field. WORKSPACE_RE permits only bare
            // digits ("77"), so no distinctive value can be chosen for it -- any digits
            // used here would collide with incidental ones elsewhere in the payload
            // (chunk lengths, string.char counts, etc). That gap is why the stronger
            // "nothing numeric survives outside string.char()" check exists right below:
            // it covers class, monitor, address AND workspace at once, with no
            // distinctive value needed for any of them.
            check("chunks: no configured value appears literally in the payload",
                  (function() {
                      var m = Model.validate(cfg(
                          [prog({ id: "p1", "class": "^(QQQZZZ)$",
                                  placement: { kind: "monitor", value: "ZZTOPMON" } })],
                          [{ workspace: "77", monitor: "YYWORKMON" }]));
                      var all = Model.buildRuleChunks(m).join("\n");
                      var leaked = [];
                      ["QQQZZZ", "ZZTOPMON", "YYWORKMON"].forEach(function(v) {
                          if (all.indexOf(v) !== -1) leaked.push(v);
                      });
                      return leaked.length === 0 ? "clean" : "leaked: " + leaked.join(",");
                  })(), "clean");

            // Stronger than looking for distinctive values: the Lua skeleton these
            // chunks are built from contains no digit anywhere, and every configured
            // value is supposed to arrive as string.char(<digits>). So remove the
            // string.char(...) groups and NOTHING numeric may remain. This catches an
            // unencoded class, monitor, address or workspace alike -- including the
            // workspace, which cannot be given a distinctive value because
            // WORKSPACE_RE permits only digits.
            check("chunks: nothing numeric survives outside string.char()",
                  (function() {
                      var m = Model.validate(cfg(
                          [prog({ id: "p1", "class": "^(QQQZZZ)$",
                                  placement: { kind: "workspace", value: "77" } })],
                          [{ workspace: "42", monitor: "ZZTOPMON" }]));
                      var all = Model.buildRuleChunks(m).join("\n")
                                    .replace(/string\.char\([0-9,]*\)/g, "");
                      var m2 = all.match(/[0-9]/g);
                      return m2 === null ? "clean" : "digits left: " + m2.join("");
                  })(), "clean");

            check("chunks: no chunk carries more than 20 rules",
                  (function() {
                      var many = [], i;
                      for (i = 0; i < 200; i++) many.push(prog({ id: "p" + i }));
                      var c = Model.buildRuleChunks(Model.validate(cfg(many, [])));
                      for (i = 1; i < c.length; i++) {
                          // Every chunk's prelude also defines
                          // "local function put(key, rule)" -- a bare
                          // /\bput\(/ matches that definition too and
                          // overcounts by one per chunk. Match only actual
                          // calls, which always take the shape put(string.char(...
                          var n = (c[i].match(/\bput\(string\.char\(/g) || []).length;
                          if (n > 20) return "chunk " + i + " has " + n;
                      }
                      return "within";
                  })(), "within");

            check("chunks: no chunk exceeds 64 KiB",
                  (function() {
                      var many = [], i;
                      for (i = 0; i < 200; i++) many.push(prog({ id: "p" + i, "class": new Array(200).join("a") }));
                      var c = Model.buildRuleChunks(Model.validate(cfg(many, [])));
                      for (i = 0; i < c.length; i++) if (c[i].length > 65536) return "chunk " + i;
                      return "within";
                  })(), "within");

            check("chunks: 200 programs and 99 workspaces stay within 20 eval calls",
                  (function() {
                      var many = [], rows = [], i;
                      for (i = 0; i < 200; i++) many.push(prog({ id: "p" + i }));
                      for (i = 1; i <= 99; i++) rows.push({ workspace: "" + i, monitor: "DP-4" });
                      return Model.buildRuleChunks(Model.validate(cfg(many, rows))).length <= 20;
                  })(), true);

            checkThrows("chunks: a non-ascii class cannot be encoded",
                        function() {
                            Model.buildRuleChunks({ programs: [prog({ "class": "café" })], workspaces: [] });
                        }, /byte out of range/);

            // Panel.qml picks the hyprctl verb by looking at the payload's first
            // characters: a rule block goes to eval, a dispatcher expression to
            // dispatch. Nothing asserted that property, so it is pinned here.
            check("chunks: every rule block starts with do -- the panel sends these to eval",
                  (function() {
                      var c = chunksFor([prog({})], [{ workspace: "1", monitor: "DP-4" }]);
                      for (var i = 0; i < c.length; i++) {
                          if (c[i].indexOf("do") !== 0) return "chunk " + i + " starts with " + c[i].substring(0, 8);
                      }
                      return "all";
                  })(), "all");

            // --- effectiveMonitor ---------------------------------------------
            var rows = [{ workspace: "6", monitor: "HDMI-A-1" },
                        { workspace: "2", monitor: "DP-3" }];

            check("effectiveMonitor: workspace placement follows the table",
                  Model.effectiveMonitor(prog({ placement: { kind: "workspace", value: "6" } }), rows),
                  "HDMI-A-1");
            check("effectiveMonitor: an unpinned workspace has no monitor",
                  Model.effectiveMonitor(prog({ placement: { kind: "workspace", value: "7" } }), rows),
                  "");
            check("effectiveMonitor: monitor placement is its own answer",
                  Model.effectiveMonitor(prog({ placement: { kind: "monitor", value: "DP-4" } }), rows),
                  "DP-4");
            check("effectiveMonitor: no placement, no monitor",
                  Model.effectiveMonitor(prog({ placement: { kind: "none" } }), rows), "");

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

            // --- newId ---------------------------------------------------------
            check("newId: avoids an id in use",
                  Model.newId([{ id: "p1" }]) !== "p1", true);
            // NOT "ID_RE.test(newId([]))" any more. That assertion could not
            // fail: "p1" satisfies ID_RE whether or not newId checks it, so
            // removing the check left it green (measured: 0 red). What is worth
            // holding is that every id this generator hands out is one
            // validate() ACCEPTS -- an independent judge, over a run of ids
            // rather than the first one. Probed: changing the candidate to
            // "P" + i turns this red and the old assertion did not notice.
            check("newId: every id it answers with is one validate() accepts",
                  (function() {
                      var existing = [], refused = [], i;
                      for (i = 0; i < 60; i++) {
                          var fresh = Model.newId(existing);
                          if (Model.validate(cfg([prog({ id: fresh })])).programs.length !== 1)
                              refused.push(fresh);
                          existing.push({ id: fresh });
                      }
                      return refused.join(",");
                  })(), "");
            check("newId: still finds one after many",
                  (function() {
                      var many = [], i;
                      for (i = 1; i <= 250; i++) many.push({ id: "p" + i });
                      var fresh = Model.newId(many);
                      for (i = 0; i < many.length; i++) if (many[i].id === fresh) return "collides";
                      return "free";
                  })(), "free");

            // --- classLiteral --------------------------------------------------
            check("classLiteral: anchors and escapes the dots",
                  Model.classLiteral("nimbus-chat.example.org__-Default"),
                  "^(nimbus\\-web\\.chat\\.com__\\-Default)$");
            check("classLiteral: a plain class",
                  Model.classLiteral("cursor"), "^(cursor)$");
            // NOT "CLASS_RE.test(classLiteral(...))" any more: classLiteral
            // THROWS unless the allowlist passes, so that assertion was true by
            // construction and stayed green with the allowlist check removed.
            // What the pattern is FOR is identifying one window and not its
            // neighbours, so that is what is asserted -- the same property the
            // shell suite measures through the real grep -E, asserted here over
            // generated patterns instead of one hand-copied literal. RegExp is
            // used on a FIXED fixture, never on a user pattern (Panel.qml is
            // barred from it by a structural check, for the backtracking
            // hazard). Probed: unescaped -> red, unanchored -> red.
            check("classLiteral: the pattern matches the class it was built from",
                  (function() {
                      var classes = ["cursor", "LM-Studio", "nimbus-chat.example.org__-Default",
                                     "org.gnome.Nautilus", "code-url-handler", "steam_app_570",
                                     "1Password", "a b"];
                      var missed = [], i;
                      for (i = 0; i < classes.length; i++) {
                          if (!new RegExp(Model.classLiteral(classes[i])).test(classes[i]))
                              missed.push(classes[i]);
                      }
                      return missed.join(",");
                  })(), "");
            check("classLiteral: and matches neither a near miss nor a longer class",
                  (function() {
                      var cases = [["nimbus-chat.example.org__-Default",
                                    "nimbus-webXchatYcom__-Default"],
                                   ["nimbus-chat.example.org__-Default",
                                    "a-nimbus-chat.example.org__-Default-suffix"],
                                   ["cursor", "cursor2"],
                                   ["org.gnome.Nautilus", "orgXgnomeXNautilus"],
                                   ["LM-Studio", "LM-Studio-Beta"]];
                      var wrong = [], i;
                      for (i = 0; i < cases.length; i++) {
                          if (new RegExp(Model.classLiteral(cases[i][0])).test(cases[i][1]))
                              wrong.push(cases[i][0] + " matched " + cases[i][1]);
                      }
                      return wrong.join(",");
                  })(), "");
            checkThrows("classLiteral: an empty class is refused, and the refusal says what to do",
                        function() { Model.classLiteral(""); },
                        /refusing an empty window class .* type the class by hand/);
            check("classLiteral: the empty pattern it used to produce is one the allowlist accepts",
                  Model.CLASS_RE.test("^()$"), true);
            checkThrows("classLiteral: a class with a quote is refused",
                        function() { Model.classLiteral('a"b'); }, /classLiteral: refusing/);
            checkThrows("classLiteral: a non-ascii class is refused",
                        function() { Model.classLiteral("café"); }, /classLiteral: refusing/);

            // --- guessCommand --------------------------------------------------
            var apps = [{ name: "Cursor", exec: "cursor %U", wmclass: "cursor", icon: "" },
                        { name: "Modelbox", exec: "modelbox", wmclass: "LM-Studio", icon: "" },
                        { name: "Files", exec: "nautilus %U", wmclass: "", icon: "" }];

            check("guessCommand: matches StartupWMClass and strips field codes",
                  Model.guessCommand("cursor", apps), "cursor");
            check("guessCommand: matches case-insensitively",
                  Model.guessCommand("modelbox", apps), "modelbox");
            check("guessCommand: no match, no guess",
                  Model.guessCommand("firefox", apps), "");
            // The app list is built from files this plugin does not own. An
            // entry that lost its Exec= used to reach stripFieldCodes as
            // undefined and throw from inside .length, which would have taken
            // the whole import down with it rather than one entry.
            check("guessCommand: an app entry with no Exec does not throw",
                  Model.guessCommand("cursor", [{ name: "Broken", wmclass: "cursor" }]), "");

            // --- programFromApp ------------------------------------------------
            check("programFromApp: arrives disabled",
                  Model.programFromApp(apps[0], []).enabled, false);
            check("programFromApp: the field codes are gone from the command",
                  Model.programFromApp(apps[0], []).command, "cursor");
            check("programFromApp: StartupWMClass becomes a literal pattern",
                  Model.programFromApp(apps[1], [])["class"], "^(LM\\-Studio)$");
            check("programFromApp: an unusable class leaves the field empty rather than refusing the entry",
                  Model.programFromApp({ name: "Odd", exec: "odd", wmclass: "café" }, [])["class"], "");
            check("programFromApp: no StartupWMClass leaves the field empty",
                  Model.programFromApp(apps[2], [])["class"], "");
            check("programFromApp: the id avoids the ids in use",
                  Model.programFromApp(apps[0], [{ id: "p1" }, { id: "p2" }]).id, "p3");
            check("programFromApp: a very long name is cut to the schema's limit",
                  Model.programFromApp({ name: new Array(400).join("x"), exec: "a",
                                         wmclass: "a" }, []).name.length, 100);
            check("programFromApp: the entry survives its own validation",
                  (function() {
                      var checked = Model.validate(cfg([Model.programFromApp(apps[0], [])]));
                      return checked.programs.length === 1 && checked.blocked.length === 0;
                  })(), true);
            // An entry with no usable class is NOT quietly workable: the row
            // says so on screen and the omissions list names it, which is the
            // dead end [From window] exists to close.
            check("programFromApp: an entry with no class is named as left out",
                  (function() {
                      var checked = Model.validate(cfg([Model.programFromApp(apps[2], [])]));
                      return (checked.rejected[0] || {}).reason;
                  })(), "class-not-allowed");

            // --- importFromSession ---------------------------------------------
            check("import: builds one program per window",
                  Model.importFromSession(
                      [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" }],
                      [{ workspace: "6", monitor: "HDMI-A-1" }], apps).programs.length, 1);
            check("import: everything arrives disabled",
                  Model.importFromSession(
                      [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" }],
                      [], apps).programs[0].enabled, false);
            check("import: the workspace table comes from the live state",
                  Model.importFromSession([], [{ workspace: "2", monitor: "DP-3" }], apps).workspaces.length, 1);
            check("import: placement follows the window's workspace",
                  Model.importFromSession(
                      [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" }],
                      [], apps).programs[0].placement.value, "6");
            check("import: the result survives its own validation",
                  (function() {
                      var config = Model.importFromSession(
                          [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" },
                           { address: "0x2", class: "LM-Studio", title: "t", workspace: "1", monitor: "DP-4" }],
                          [{ workspace: "6", monitor: "HDMI-A-1" }], apps);
                      var checked = Model.validate(config);
                      return checked.rejected.length === 0 && checked.blocked.length === 0;
                  })(), true);
            check("import: a window whose class cannot be encoded is skipped, not fatal",
                  Model.importFromSession(
                      [{ address: "0x1", class: "café", title: "t", workspace: "1", monitor: "DP-4" },
                       { address: "0x2", class: "cursor", title: "t", workspace: "1", monitor: "DP-4" }],
                      [], apps).programs.length, 1);
            // Two windows of one class are one entry: a second Nimbus window
            // would otherwise arrive as a second program with the SAME class,
            // which validate() blocks the moment their placements differ --
            // the import would hand the user a configuration that cannot be
            // applied.
            check("import: a second window of the same class does not add a second entry",
                  Model.importFromSession(
                      [{ address: "0x1", class: "cursor", title: "a", workspace: "1", monitor: "DP-4" },
                       { address: "0x2", class: "cursor", title: "b", workspace: "2", monitor: "DP-4" }],
                      [], apps).programs.length, 1);
            // THE INJECTION PATH THAT WAS HERE. This function used to fall back
            // to the window's own class as the command when the application
            // list matched nothing -- and a class is set by the client, so a
            // window calling itself "$(reboot)" imported as an entry whose
            // COMMAND was "$(reboot)", accepted by validate() and rendered
            // verbatim by launchCommand. The class PATTERN is escaped and was
            // never the hole; the command field cannot be, because it is a
            // shell command line by design. Three assertions, because the fix
            // has three halves: nothing from the class reaches the command, the
            // entry is still imported, and it is imported VISIBLY broken.
            check("import: a class the app list does not know reaches the command field never",
                  Model.importFromSession(
                      [{ address: "0x1", class: "$(reboot)", title: "t",
                         workspace: "1", monitor: "DP-4" }],
                      [], apps).programs[0].command, "");
            check("import: an unmatched window is still imported, not dropped",
                  Model.importFromSession(
                      [{ address: "0x1", class: "somethingelse", title: "t",
                         workspace: "1", monitor: "DP-4" }],
                      [], apps).programs.length, 1);
            check("import: and it arrives visibly incomplete rather than plausibly wrong",
                  (function() {
                      var config = Model.importFromSession(
                          [{ address: "0x1", class: "somethingelse", title: "t",
                             workspace: "1", monitor: "DP-4" }], [], apps);
                      var checked = Model.validate(config);
                      return checked.programs.length + ":"
                           + (checked.rejected[0] || {}).reason;
                  })(), "0:command-invalid");
            check("import: a window with no class at all is left out, since no pattern can name it",
                  Model.importFromSession(
                      [{ address: "0x1", class: "", title: "t", workspace: "1", monitor: "DP-4" },
                       { address: "0x2", class: "cursor", title: "t", workspace: "1", monitor: "DP-4" }],
                      [], apps).programs.length, 1);
            // The unvalidated config reader permits a null entry and validate()
            // names that shape by itself, so none of these may throw on it.
            check("import: a null window entry is skipped, not fatal",
                  Model.importFromSession(
                      [null, { address: "0x2", class: "cursor", title: "t",
                               workspace: "1", monitor: "DP-4" }],
                      [null, { workspace: "2", monitor: "DP-3" }], apps).programs.length, 1);
            check("import: and the null workspace row is skipped too",
                  Model.importFromSession(
                      [], [null, { workspace: "2", monitor: "DP-3" }], apps).workspaces.length, 1);
            check("newId: a null entry in the list in use is not fatal",
                  Model.newId([null, { id: "p1" }]), "p2");
            check("programFromApp: a null entry in the list in use is not fatal",
                  Model.programFromApp(apps[0], [null, { id: "p1" }]).id, "p2");

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

            // --- isEmptyConfig -------------------------------------------------
            // The condition [Import current session] is gated on. BOTH lists,
            // because the import replaces the whole configuration: a draft with
            // workspace rows and no programs would lose them.
            check("isEmptyConfig: nothing at all",
                  Model.isEmptyConfig(cfg([], [])), true);
            check("isEmptyConfig: a program makes it non-empty",
                  Model.isEmptyConfig(cfg([prog({})], [])), false);
            check("isEmptyConfig: a workspace row alone makes it non-empty",
                  Model.isEmptyConfig(cfg([], [{ workspace: "2", monitor: "DP-3" }])), false);
            check("isEmptyConfig: an absent configuration counts as empty",
                  Model.isEmptyConfig(undefined), true);
            check("import: a workspace row the allowlist refuses is left out of the table",
                  Model.importFromSession([], [{ workspace: "0", monitor: "DP-4" },
                                               { workspace: "2", monitor: 'a"b' },
                                               { workspace: "3", monitor: "DP-4" }], apps).workspaces.length, 1);
            check("import: nothing at all is not an error",
                  Model.importFromSession([], [], apps).programs.length, 0);

            // --- launchCommand -------------------------------------------------
            check("launchCommand: goes through uwsm-app",
                  Model.launchCommand("cursor").indexOf("uwsm-app -- cursor") !== -1, true);
            check("launchCommand: detaches every standard stream",
                  Model.launchCommand("cursor"),
                  "{ uwsm-app -- cursor\n} </dev/null >/dev/null 2>&1");
            check("launchCommand: the redirection covers a compound command, not just its last part",
                  (function() {
                      // The group must close AFTER the whole command, so everything in
                      // it is inside the braces rather than trailing behind them.
                      var s = Model.launchCommand("sleep 2 && myapp");
                      return s.indexOf("{ uwsm-app -- sleep 2 && myapp\n}") === 0;
                  })(), true);
            check("launchCommand: a trailing & does not break the group",
                  // "; }" after a trailing "&" is a syntax error -- the group
                  // must be closed by a newline, not by "; ".
                  Model.launchCommand("myapp &"),
                  "{ uwsm-app -- myapp &\n} </dev/null >/dev/null 2>&1");

            // --- workspaceMoves ------------------------------------------------
            check("workspaceMoves: a workspace on the wrong monitor moves",
                  (function() {
                      var m = Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }]));
                      var moves = Model.workspaceMoves(m, [{ workspace: "2", monitor: "DP-4" }]);
                      return moves.length === 1 && moves[0].monitor === "DP-3";
                  })(), true);
            check("workspaceMoves: a workspace already right stays put",
                  Model.workspaceMoves(Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }])),
                                       [{ workspace: "2", monitor: "DP-3" }]).length, 0);
            check("workspaceMoves: a workspace that does not exist yet is not moved",
                  Model.workspaceMoves(Model.validate(cfg([], [{ workspace: "8", monitor: "DP-3" }])),
                                       [{ workspace: "2", monitor: "DP-3" }]).length, 0);

            // --- reconcile -----------------------------------------------------
            check("reconcile: a workspace move becomes a dispatcher expression",
                  (function() {
                      var m = Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }]));
                      var c = Model.buildReconcileChunks(m, [{ workspace: "2", monitor: "DP-4" }], []);
                      return c.length === 1 && c[0].indexOf("hl.dsp.workspace.move") !== -1;
                  })(), true);

            check("reconcile: a matched window is moved by address, not by class",
                  (function() {
                      var m = Model.validate(cfg([prog({ id: "p1" })], []));
                      var c = Model.buildReconcileChunks(m, [], [{ id: "p1", address: "0xdead" }]);
                      var joined = c.join("\n");
                      return joined.indexOf("0xdead") === -1     // encoded, not literal
                          && joined.indexOf("cursor") === -1     // the class never travels
                          && joined.indexOf("hl.dsp.window.move") !== -1;
                  })(), true);

            check("reconcile: no quotes in any expression",
                  (function() {
                      var m = Model.validate(cfg([prog({ id: "p1" })], [{ workspace: "2", monitor: "DP-3" }]));
                      var c = Model.buildReconcileChunks(m, [{ workspace: "2", monitor: "DP-4" }],
                                                         [{ id: "p1", address: "0xbeef" }]);
                      for (var i = 0; i < c.length; i++) if (c[i].indexOf('"') !== -1) return "chunk " + i;
                      return "clean";
                  })(), "clean");

            // Same shape as the buildRuleChunks version above, for the reconcile
            // path: a distinctive monitor (workspace move) and a distinctive
            // address (window move), neither of which may appear as readable
            // text in the payload -- both must arrive as string.char(...).
            //
            // NOT covered here either: the workspace field of the workspace move
            // (move.workspace) -- same reason as the buildRuleChunks version above,
            // WORKSPACE_RE permits only digits so no distinctive value exists. The
            // "nothing numeric survives" version right below covers it.
            check("reconcile: no configured value appears literally in the payload",
                  (function() {
                      var m = Model.validate(cfg(
                          [prog({ id: "p1", placement: { kind: "monitor", value: "ZZTOPMON" } })],
                          [{ workspace: "77", monitor: "YYWORKMON" }]));
                      var all = Model.buildReconcileChunks(m,
                          [{ workspace: "77", monitor: "XXCURRENTMON" }],
                          [{ id: "p1", address: "0xdeadbeefcafe" }]).join("\n");
                      var leaked = [];
                      ["ZZTOPMON", "YYWORKMON", "deadbeefcafe"].forEach(function(v) {
                          if (all.indexOf(v) !== -1) leaked.push(v);
                      });
                      return leaked.length === 0 ? "clean" : "leaked: " + leaked.join(",");
                  })(), "clean");

            // Same "nothing numeric survives" question as buildRuleChunks, for the
            // reconcile path. Distinctive workspace/monitor values are used for the
            // workspace ROW and window placement so the "clean" result is not an
            // accident of an unused field; workspace "77" itself is exactly the kind
            // of value this check does not need to be distinctive to catch.
            check("reconcile: nothing numeric survives outside string.char()",
                  (function() {
                      var m = Model.validate(cfg(
                          [prog({ id: "p1", placement: { kind: "monitor", value: "ZZTOPMON" } })],
                          [{ workspace: "77", monitor: "YYWORKMON" }]));
                      var all = Model.buildReconcileChunks(m,
                          [{ workspace: "77", monitor: "XXCURRENTMON" }],
                          [{ id: "p1", address: "0xdeadbeefcafe" }]).join("\n")
                                    .replace(/string\.char\([0-9,]*\)/g, "");
                      var m2 = all.match(/[0-9]/g);
                      return m2 === null ? "clean" : "digits left: " + m2.join("");
                  })(), "clean");

            // Wrapped in try/catch, not a bare call: a mutation that lets a
            // "none"-placement program reach windowMoveExpression makes
            // luaBytes(placement.value) throw on undefined, and check()
            // evaluates its "got" argument before it is entered -- an
            // unguarded call here would abort the whole harness (status 3)
            // instead of producing this assertion's own red line. Same fix
            // as task 8.
            check("reconcile: a program without placement is not moved",
                  (function() {
                      try {
                          return Model.buildReconcileChunks(
                              Model.validate(cfg([prog({ placement: { kind: "none" } })], [])),
                              [], [{ id: "p1", address: "0xbeef" }]).length;
                      } catch (e) {
                          return "threw: " + ((e && e.message) || e);
                      }
                  })(), 0);

            // --- verbFor: the three measured shapes ----------------------------
            //
            // Task 1 measured that the two move kinds need DIFFERENT hyprctl
            // verbs. verbFor is the only place that decides, so it is the only
            // place that has to be right -- and Panel.qml calls it rather than
            // repeating the rule.
            check("verbFor: a rule block goes to eval",
                  Model.verbFor(Model.buildRuleChunks(Model.validate(cfg([], []))) [0]), "eval");
            check("verbFor: a window move goes to eval (it is a block, not a bare dispatcher expression)",
                  Model.verbFor(Model.buildReconcileChunks(
                      Model.validate(cfg([prog({ id: "p1" })], [])),
                      [], [{ id: "p1", address: "0xbeef" }])[0]), "eval");
            check("verbFor: a workspace move goes to dispatch (bare dispatcher)",
                  Model.verbFor(Model.buildReconcileChunks(
                      Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }])),
                      [{ workspace: "2", monitor: "DP-4" }], [])[0]), "dispatch");

            // The window move resolves the address first and moves only if the
            // window still exists. Without this guard a vanished window makes the
            // move land on an unrelated one -- measured, not theorised: during
            // task 1 an unguarded move relocated two of the user's own windows.
            check("reconcile: the window move never passes the address as a selector",
                  Model.buildReconcileChunks(Model.validate(cfg([prog({ id: "p1" })], [])),
                                             [], [{ id: "p1", address: "0xbeef" }])[0]
                      .indexOf("hl.get_window(") === -1, true);
            check("reconcile: the window move enumerates and compares on the object",
                  /for _, w in ipairs\(hl\.get_windows\(\{\}\)\) do if w\.address == string\.char\(/.test(
                      Model.buildReconcileChunks(Model.validate(cfg([prog({ id: "p1" })], [])),
                                                 [], [{ id: "p1", address: "0xbeef" }])[0]), true);
            check("reconcile: the window move never uses the bare dispatch route",
                  Model.verbFor(Model.buildReconcileChunks(
                      Model.validate(cfg([prog({ id: "p1" })], [])),
                      [], [{ id: "p1", address: "0xbeef" }])[0]), "eval");

            checkThrows("reconcile: a malformed address is refused",
                        function() {
                            Model.buildReconcileChunks(Model.validate(cfg([prog({ id: "p1" })], [])),
                                                       [], [{ id: "p1", address: "0x1; evil()" }]);
                        }, /refusing address/);

            // --- missingIds ----------------------------------------------------
            check("missingIds: an enabled program with no window is missing",
                  Model.missingIds(Model.validate(cfg([prog({ id: "p1" })], [])), []).length, 1);
            check("missingIds: an enabled program with a window is not missing",
                  Model.missingIds(Model.validate(cfg([prog({ id: "p1" })], [])),
                                   [{ id: "p1", address: "0x1" }]).length, 0);
            check("missingIds: a disabled program is never missing",
                  Model.missingIds(Model.validate(cfg([prog({ id: "p1", enabled: false })], [])), []).length, 0);

            // --- firstFreeWorkspace --------------------------------------------
            check("firstFreeWorkspace: an empty table starts at 1",
                  Model.firstFreeWorkspace([]), "1");
            check("firstFreeWorkspace: takes the lowest number not in use",
                  Model.firstFreeWorkspace([{ workspace: "1" }, { workspace: "2" },
                                            { workspace: "4" }]), "3");
            // The edge case: with every legal number taken it returns the last
            // one rather than nothing, so the panel adds a visible duplicate
            // the user can change instead of a button that does nothing.
            check("firstFreeWorkspace: with 1 to 99 all taken it returns 99, not nothing",
                  (function() {
                      var full = [];
                      for (var i = 1; i <= 99; i++) full.push({ workspace: String(i) });
                      return Model.firstFreeWorkspace(full);
                  })(), "99");
            check("firstFreeWorkspace: a malformed row blocks no legal number",
                  Model.firstFreeWorkspace([{ workspace: null }, {}, { workspace: 1 }]), "2");
            check("firstFreeWorkspace: no rows at all is not a crash",
                  Model.firstFreeWorkspace(undefined), "1");

            // "Has wording" has to mean MORE than "is not the bare code", and a
            // mutation probe is how that was learned: deleting the
            // write-failed branch left this assertion GREEN, because the
            // fallback is a polite sentence naming the code rather than the
            // bare code itself. So the fallback's own shape is asked for with
            // a sentinel and then rendered for each real code -- derived from
            // the function under test, not copied from it, so it keeps working
            // if the fallback wording changes. reasonText below gets the same
            // treatment; its fallback happens to be the bare code today, which
            // is why the plain equality test still caught things there.
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

            // --- reasonText ----------------------------------------------------
            //
            // Provoked from real configurations rather than from a hand-copied
            // list of codes: a new reason added to validate() with no wording
            // turns the first of these red, which a list mirroring the
            // validator could never do.
            //
            // BOTH CHANNELS, and that is the whole point of the shape. The
            // first version of this walked `rejected` only, and `class-conflict`
            // -- the sole `blocked` reason -- went unnoticed without wording
            // for a whole round. The two channels are not interchangeable:
            // `rejected` is a named visible omission with everything else
            // applied, `blocked` stops the save outright. A completeness claim
            // that covers one of them is not a completeness claim, so the
            // channel is carried alongside the code and asserted per channel
            // below -- otherwise a future channel that nothing provokes would
            // let its reasons through exactly the same way.
            function provokedReasons() {
                var many = [], i;
                for (i = 0; i < 205; i++) many.push(prog({ id: "p" + i }));
                var manyWs = [];
                for (i = 1; i <= 99; i++) manyWs.push({ workspace: String(i), monitor: "DP-4" });
                manyWs.push({ workspace: "5", monitor: "DP-4" });

                var configs = [
                    { schemaVersion: 1, programs: "cursor", workspaces: [] },
                    { schemaVersion: 1, programs: [], workspaces: "DP-4" },
                    cfg([null]),
                    cfg([prog({ id: "P 1!" })]),
                    cfg([prog({ name: "" })]),
                    cfg([prog({ enabled: "yes" })]),
                    cfg([prog({ command: "" })]),
                    cfg([prog({ command: "myapp &&" })]),
                    cfg([prog({ "class": 'a"b' })]),
                    cfg([prog({ placement: { kind: "screen", value: "DP-4" } })]),
                    cfg([prog({ id: "a" }), prog({ id: "a" })]),
                    cfg(many),
                    cfg([], [{ workspace: "0", monitor: "DP-4" }]),
                    cfg([], [{ workspace: "1", monitor: "DP-4" },
                             { workspace: "1", monitor: "DP-3" }]),
                    cfg([], manyWs),
                    // The blocked channel: one window class, two placements.
                    // The natural mistake the either-or placement rule invites,
                    // and the reason this list has to cover both channels.
                    cfg([prog({ id: "a", name: "Nimbus A", placement: { kind: "workspace", value: "6" } }),
                         prog({ id: "b", name: "Nimbus B", placement: { kind: "workspace", value: "7" } })])
                ];
                var seen = Object.create(null), out = [];
                function collect(entries, channel) {
                    for (var k = 0; k < entries.length; k++) {
                        var key = channel + ":" + String(entries[k].reason);
                        if (seen[key] === undefined) {
                            seen[key] = true;
                            out.push({ channel: channel, code: String(entries[k].reason) });
                        }
                    }
                }
                for (i = 0; i < configs.length; i++) {
                    var verdict = Model.validate(configs[i]);
                    collect(verdict.rejected, "rejected");
                    collect(verdict.blocked, "blocked");
                }
                return out;
            }

            function reasonsInChannel(channel) {
                var all = provokedReasons(), n = 0;
                for (var i = 0; i < all.length; i++) if (all[i].channel === channel) n++;
                return n;
            }

            // "Has wording" means BOTH: not the bare code back, and long
            // enough to be a sentence rather than a decorated identifier.
            // The floor is 12 characters -- far below any real sentence here,
            // far above "class-conflict!" -- so a one-character escape from
            // the equality test does not count as wording.
            check("reasonText: every reason validate emits through EITHER channel has plain wording",
                  (function() {
                      var all = provokedReasons(), codes = [], labelOf = {};
                      for (var i = 0; i < all.length; i++) {
                          codes.push(all[i].code);
                          labelOf[all[i].code] = all[i].channel + ":" + all[i].code;
                      }
                      // Same fallback-aware rule as envelopeText above: a
                      // fallback that politely names the code would otherwise
                      // read as wording. Re-labelled with the channel so a
                      // failure still says which one it came from.
                      var bare = unwordedAmong(codes, Model.reasonText);
                      if (bare === "") return "";
                      var parts = bare.split(","), out = [];
                      for (var j = 0; j < parts.length; j++) out.push(labelOf[parts[j]] || parts[j]);
                      return out.join(",");
                  })(), "");
            // These two bind the one above: without them, a channel nothing
            // provokes would pass it vacuously -- which is exactly how the
            // blocked channel slipped through. Confirmed by blanking the
            // configuration list and watching only these go red.
            check("reasonText: the configurations provoke all 13 rejected reasons",
                  reasonsInChannel("rejected"), 13);
            check("reasonText: the configurations provoke all 1 blocked reasons",
                  reasonsInChannel("blocked"), 1);
            check("reasonText: an unknown code is passed through, not guessed at",
                  Model.reasonText("something-new"), "something-new");

            // --- envelopeText --------------------------------------------------
            //
            // The class claim is split across two files on purpose (see
            // Model.envelopeCodes): this half proves every listed code has
            // wording, and test/run-tests.sh proves the list is the script's.
            // Same rule as reasonText: not the bare code back, and long enough
            // to be a sentence rather than a decorated identifier.
            check("envelopeText: every code the config helper can emit has plain wording",
                  unwordedAmong(Model.envelopeCodes(),
                                function(c) { return Model.envelopeText(c, ""); }), "");
            check("envelopeText: the list it checks is not empty",
                  Model.envelopeCodes().length, 9);

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
                  "The configuration helper gave no answer at all.");
            check("envelopeText: an unknown code is named, not shown bare",
                  Model.envelopeText("brand-new", ""),
                  "The configuration helper reported an unknown problem: brand-new.");
            check("envelopeText: the detail is appended when there is one",
                  Model.envelopeText("too-large", "300000 bytes"),
                  "The configuration file is too large to handle. 300000 bytes");
            check("envelopeText: no trailing space when there is no detail",
                  Model.envelopeText("too-large", ""),
                  "The configuration file is too large to handle.");

            // --- bounds reachable through the JS namespace ---------------------
            // Panel.qml's workspaceOptions() derives its upper bound from
            // Model.MAX_WORKSPACES rather than restating 99. That only works
            // if a top-level `var` in this file is reachable as a property of
            // the import namespace -- asserted here, in the same engine that
            // runs the plugin, so the claim is measured rather than assumed.
            check("MAX_WORKSPACES is reachable through the import namespace",
                  Model.MAX_WORKSPACES, 99);

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
            // THE FIXTURES ARE THE USER'S OWN THREE FILES, VERBATIM, byte for
            // byte as they stood on 2026-09-03 -- generated from
            // ~/.config/hypr/*.lua rather than retyped, because a fixture that
            // is merely LIKE the real forms proves the parser handles the
            // fixture. German section comments, the factual notes, the blank
            // lines and the trailing newline are all part of them: the line
            // numbers this reader reports are only correct if every one of
            // those lines is counted.
            //
            // Each is an array of LINES joined with "\n", so the round-trip
            // assertion below can compare `raw` against the very array element
            // the line number indexes into.
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
            var WINDOWRULES_LINES = [
                    "-- Fenster -> Workspace / Layout. Portiert aus workspaces.conf.",
                    "-- Lua-Syntax: o.window(\"<class-regex>\", { workspace = \"N\", ... })",
                    "",
                    "-- Workspace 1 \u2013 Playwright E2E Testing",
                    "o.window(\"^(Playwright-E2E-Test)$\", { workspace = \"1\", float = true, maximize = true })",
                    "",
                    "-- Workspace 2 \u2013 Dienstliche Kommunikation",
                    "o.window(\"(nimbus-mail.example.com__mail_-Default)\", { workspace = \"2\" })",
                    "o.window(\"(notes-app)\", { workspace = \"2\" })",
                    "",
                    "-- Workspace 6 \u2013 Entwicklung",
                    "o.window(\"(cursor)\", { workspace = \"6\", maximize = true })",
                    "",
                    "-- Workspace 7 \u2013 Passwoerter / Schluessel",
                    "o.window(\"(org.gnome.keyring-gui.Application)\", { workspace = \"7\" })",
                    "o.window(\"(org.vaultkey.Vaultkey)\", { workspace = \"7\" })",
                    "",
                    "-- Workspace 8 \u2013 KI-Anwendungen",
                    "-- Klasse ist \"LM-Studio\" (Bindestrich), nicht \"Modelbox\" -- beides abgedeckt.",
                    "o.window(\"LM[- ]?Studio\", { workspace = \"8\" })",
                    "o.window(\"(nimbus-chatgpt\\\\.com__-Default)\", { workspace = \"8\" })",
                    "",
                    "-- Workspace 9 \u2013 Private Kommunikation",
                    "o.window(\"(signal)\", { workspace = \"9\" })",
                    "o.window(\"(Chat)\", { workspace = \"9\" })",
                    "o.window(\"^(nimbus-web\\\\.chat\\\\.com__-Default)$\", { workspace = \"9\" })",
                    "o.window(\"^(chrome-web\\\\.chat\\\\.com__-Default)$\", { workspace = \"9\" })",
                    "o.window(\"^(chrome-chat\\\\.com__-Default)$\", { workspace = \"9\" })",
                    "",
                    "-- Chatterbox Desktop -- deckt alle moeglichen Class-Namen ab.",
                    "o.window(\"ChatterboxDesktop|chatterbox-desktop|org\\\\.chatterbox\\\\.desktop\", { workspace = \"9\" })",
                    ""
            ];
            var WORKSPACES_LINES = [
                    "-- Workspace -> Monitor.",
                    "-- Portiert aus dem unteren Teil von monitors.conf.",
                    "-- Hyprland-Lua-Syntax: hl.workspace_rule({ workspace = \"1\", monitor = \"DP-4\" })",
                    "",
                    "hl.workspace_rule({ workspace = \"1\", monitor = \"DP-4\" })",
                    "hl.workspace_rule({ workspace = \"2\", monitor = \"DP-3\" })",
                    "hl.workspace_rule({ workspace = \"3\", monitor = \"HDMI-A-1\" })",
                    "hl.workspace_rule({ workspace = \"4\", monitor = \"DP-4\" })",
                    "hl.workspace_rule({ workspace = \"5\", monitor = \"DP-4\" })",
                    "hl.workspace_rule({ workspace = \"6\", monitor = \"HDMI-A-1\" })",
                    "hl.workspace_rule({ workspace = \"7\", monitor = \"DP-3\" })",
                    "hl.workspace_rule({ workspace = \"8\", monitor = \"HDMI-A-1\" })",
                    "hl.workspace_rule({ workspace = \"9\", monitor = \"DP-3\" })",
                    ""
            ];
            var AUTOSTART_TEXT   = AUTOSTART_LINES.join("\n");
            var WINDOWRULES_TEXT = WINDOWRULES_LINES.join("\n");
            var WORKSPACES_TEXT  = WORKSPACES_LINES.join("\n");

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

            var autostartEntries   = Model.parseAutostartLua(AUTOSTART_TEXT, "autostart.lua");
            var windowEntries      = Model.parseWindowRulesLua(WINDOWRULES_TEXT, "windowrules.lua");
            var workspaceEntries   = Model.parseWorkspacesLua(WORKSPACES_TEXT, "workspaces.lua");

            // FAIL-CLOSED FIRST: a round-trip proof over zero entries proves
            // nothing at all, which is this project's own blind-test shape. So
            // the counts are asserted before the proof is trusted.
            check("hypr: the real autostart.lua yields entries to prove anything about",
                  autostartEntries.length, 7);
            check("hypr: the real windowrules.lua yields entries",
                  windowEntries.length, 14);
            check("hypr: the real workspaces.lua yields entries",
                  workspaceEntries.length, 9);

            check("hypr ROUND TRIP: every autostart.lua entry's raw is the line at its number",
                  roundTripBreaks(AUTOSTART_LINES, autostartEntries), "");
            check("hypr ROUND TRIP: every windowrules.lua entry's raw is the line at its number",
                  roundTripBreaks(WINDOWRULES_LINES, windowEntries), "");
            check("hypr ROUND TRIP: every workspaces.lua entry's raw is the line at its number",
                  roundTripBreaks(WORKSPACES_LINES, workspaceEntries), "");

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
            check("hypr: windowrules.lua line numbers count comments and blanks",
                  lineNumbersOf(windowEntries), "5,8,9,12,15,16,20,21,24,25,26,27,28,31");
            check("hypr: workspaces.lua line numbers count comments and blanks",
                  lineNumbersOf(workspaceEntries), "5,6,7,8,9,10,11,12,13");

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

            // --- windowrules.lua: the recognised forms ------------------------
            check("hypr window: the class is the decoded regex",
                  windowEntries[0]["class"], "^(Playwright-E2E-Test)$");
            check("hypr window: the workspace is a string",
                  windowEntries[0].workspace, "1");
            check("hypr window: float is carried",
                  windowEntries[0].flags.float, true);
            check("hypr window: maximize is carried",
                  windowEntries[0].flags.maximize, true);
            check("hypr window: a rule with only a workspace has no flags set",
                  Object.keys(windowEntries[2].flags).length, 0);
            check("hypr window: an alternation class is editable",
                  windowEntries[6].editable, true);
            check("hypr window: an alternation class is kept verbatim",
                  windowEntries[6]["class"], "LM[- ]?Studio");
            // The escape. In the file this is written "(nimbus-chatgpt\\.com__-Default)";
            // what Hyprland sees, and what the panel must show, has ONE backslash.
            check("hypr window: a Lua backslash escape is decoded, not copied",
                  windowEntries[7]["class"], "(nimbus-chatgpt\\.com__-Default)");
            check("hypr window: the raw line still has the doubled backslash",
                  windowEntries[7].raw.indexOf("\\\\.") >= 0, true);
            check("hypr window: the last rule's three-way alternation is whole",
                  windowEntries[13]["class"],
                  "ChatterboxDesktop|chatterbox-desktop|org\\.chatterbox\\.desktop");

            // --- windowrules.lua: the forms deliberately refused --------------
            check("hypr window: a table match is not editable",
                  Model.parseWindowRulesLua(
                      "o.window({ class = \"a\", title = \"b\" }, { workspace = \"2\" })")[0].editable,
                  false);
            check("hypr window: a table match says why",
                  Model.parseWindowRulesLua(
                      "o.window({ class = \"a\", title = \"b\" }, { workspace = \"2\" })")[0].reason,
                  "table-match");
            check("hypr window: an option this reader cannot represent is refused",
                  Model.parseWindowRulesLua(
                      "o.window(\".*\", { tag = \"+default-opacity\" })")[0].reason,
                  "unsupported-option");
            check("hypr window: a nested table value is refused",
                  Model.parseWindowRulesLua(
                      "o.window(\"steam\", { size = { 875, 600 } })")[0].reason,
                  "unsupported-option");
            check("hypr window: a rule with no workspace at all is refused",
                  Model.parseWindowRulesLua("o.window(\"steam\", { float = true })")[0].reason,
                  "missing-option");
            check("hypr window: a workspace Hyprland accepts but this panel does not is refused",
                  Model.parseWindowRulesLua(
                      "o.window(\"x\", { workspace = \"special silent\" })")[0].reason,
                  "value-out-of-range");
            check("hypr window: but it still carries its raw line",
                  Model.parseWindowRulesLua(
                      "o.window(\"x\", { workspace = \"special silent\" })")[0].raw,
                  "o.window(\"x\", { workspace = \"special silent\" })");
            check("hypr window: a call that does not end on its line is refused",
                  Model.parseWindowRulesLua("o.window(")[0].reason, "incomplete-call");
            check("hypr window: a multi-line call's opening line still carries its raw",
                  Model.parseWindowRulesLua("o.window(")[0].raw, "o.window(");
            check("hypr window: a trailing comment after the code is refused, not eaten",
                  Model.parseWindowRulesLua(
                      "o.window(\"x\", { workspace = \"2\" }) -- keep this note")[0].editable,
                  false);

            // --- workspaces.lua ------------------------------------------------
            check("hypr workspace: the workspace number",
                  workspaceEntries[0].workspace, "1");
            check("hypr workspace: the monitor name",
                  workspaceEntries[0].monitor, "DP-4");
            check("hypr workspace: a two-part monitor name survives",
                  workspaceEntries[2].monitor, "HDMI-A-1");
            check("hypr workspace: a rule missing the monitor is refused",
                  Model.parseWorkspacesLua("hl.workspace_rule({ workspace = \"1\" })")[0].reason,
                  "missing-option");
            check("hypr workspace: an unknown key is refused",
                  Model.parseWorkspacesLua(
                      "hl.workspace_rule({ workspace = \"1\", monitor = \"DP-4\", default_name = \"x\" })")[0].reason,
                  "unsupported-option");
            check("hypr workspace: a monitor name with a quote in it is refused",
                  Model.parseWorkspacesLua(
                      "hl.workspace_rule({ workspace = \"1\", monitor = \"a b\" })")[0].reason,
                  "value-out-of-range");

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
                  Model.parseWorkspacesLua("\n\n\n").length, 0);
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

            // --- parseHyprFiles: the three sections -----------------------------
            //
            // Always three, always in file order, and a file the reader did not
            // find is a section that SAYS so. A missing windowrules.lua that
            // simply vanished from the list would read as a plugin fault.
            var envelope = [
                { name: "autostart.lua",   path: "/h/autostart.lua",   present: true,
                  mtime: 11, truncated: false, content: AUTOSTART_TEXT },
                { name: "windowrules.lua", path: "/h/windowrules.lua", present: false,
                  mtime: 0,  truncated: false, content: "" },
                { name: "workspaces.lua",  path: "/h/workspaces.lua",  present: true,
                  mtime: 13, truncated: true,  content: WORKSPACES_TEXT }
            ];
            var sections = Model.parseHyprFiles(envelope);
            check("hypr sections: always three", sections.length, 3);
            check("hypr sections: in file order",
                  sections[0].name + "," + sections[1].name + "," + sections[2].name,
                  "autostart.lua,windowrules.lua,workspaces.lua");
            check("hypr sections: a missing file is present:false",
                  sections[1].present, false);
            check("hypr sections: a missing file has no entries",
                  sections[1].entries.length, 0);
            check("hypr sections: a missing file still names its path",
                  sections[1].path, "/h/windowrules.lua");
            check("hypr sections: the truncation flag is carried through",
                  sections[2].truncated, true);
            check("hypr sections: the mtime is carried through",
                  sections[0].mtime, 11);
            check("hypr sections: an entirely absent envelope still gives three sections",
                  Model.parseHyprFiles(undefined).length, 3);
            check("hypr sections: and none of them claims to be present",
                  Model.parseHyprFiles(undefined)[0].present, false);
            check("hypr sections: an unknown file name in the envelope is ignored",
                  Model.parseHyprFiles([{ name: "bindings.lua", present: true,
                                          content: "o.launch_on_start(\"x\")" }]).length, 3);
            check("hypr sections: the total across sections",
                  Model.hyprEntryCount(sections), 16);
            check("hypr sections: and how many of those are editable",
                  Model.hyprEditableCount(sections), 15);

            // --- the wording ----------------------------------------------------
            //
            // The same two-sided guarantee reasonText and envelopeText have:
            // this half proves every code the parsers can set has plain
            // wording, and the parser assertions above are what prove the list
            // is the set they actually set.
            check("hypr wording: every refusal code has plain wording",
                  unwordedAmong(Model.hyprReasons(), Model.hyprReasonText), "");
            check("hypr wording: the list it checks is not empty",
                  Model.hyprReasons().length, 7);
            check("hypr wording: an absent code does not print undefined",
                  Model.hyprReasonText(undefined).indexOf("undefined"), -1);
            check("hypr wording: an unknown code is named, not shown bare",
                  Model.hyprReasonText("brand-new").indexOf("brand-new") >= 0, true);

            check("hypr header: it says which file can be edited",
                  Model.hyprHeaderText(sections).indexOf("autostart.lua can be edited here") >= 0,
                  true);
            check("hypr header: and that the other two are not",
                  Model.hyprHeaderText(sections).indexOf("read only") >= 0, true);
            check("hypr header: it names the files it read",
                  Model.hyprHeaderText(sections).indexOf("autostart.lua (7)") >= 0, true);
            check("hypr header: it names the file it did not find",
                  Model.hyprHeaderText(sections).indexOf("Not found: windowrules.lua") >= 0, true);
            check("hypr header: with nothing read at all it says so",
                  Model.hyprHeaderText(Model.parseHyprFiles(undefined))
                       .indexOf("No file was read") >= 0, true);

            check("hypr entry text: the line number comes first",
                  Model.hyprEntryText(autostartEntries[0]), "4: notes-app");
            check("hypr entry text: a window rule reads as class to workspace",
                  Model.hyprEntryText(windowEntries[2]),
                  "9: (notes-app)  \u2192  workspace 2");
            check("hypr entry text: flags are named",
                  Model.hyprEntryText(windowEntries[0]).indexOf("[float, maximize]") >= 0, true);
            check("hypr entry text: a workspace rule reads as workspace to monitor",
                  Model.hyprEntryText(workspaceEntries[0]),
                  "5: workspace 1  \u2192  DP-3".replace("DP-3", "DP-4"));
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
            // One derivation, two callers: programFromApp (the old half) and the
            // autostart picker, which fills the add field with it rather than
            // writing it, because Exec= is a guess.
            check("commandFromApp: the field codes are stripped",
                  Model.commandFromApp({ exec: "nimbus %U" }), "nimbus");
            check("commandFromApp: an escaped percent survives",
                  Model.commandFromApp({ exec: "printf 100%% %f" }), "printf 100%");
            check("commandFromApp: no exec at all gives an empty command",
                  Model.commandFromApp({ name: "x" }), "");
            check("commandFromApp: nothing at all gives an empty command",
                  Model.commandFromApp(undefined), "");
            check("commandFromApp: programFromApp gives the same command",
                  Model.programFromApp({ exec: "nimbus %U", name: "Nimbus" }, []).command,
                  Model.commandFromApp({ exec: "nimbus %U" }));
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
                  sections[1].content, "");
            check("hypr sections: the entries agree with the content it carries",
                  Model.parseAutostartLua(sections[0].content, "autostart.lua")[0].raw,
                  sections[0].entries[0].raw);

            // --- which section may be written ----------------------------------
            check("hypr writable: autostart.lua is the one",
                  Model.hyprSectionIsWritable(sections[0]), true);
            // ALL THREE PRESENT AND NONE TRUNCATED, and that is the whole point
            // of this second envelope. Against `sections` above, windowrules.lua
            // is present:false and workspaces.lua is truncated:true -- so both
            // are unwritable for a reason that is NOT their name, and a mutation
            // probe proved it: disarming the name check left the suite green
            // (probe "autostart: only autostart.lua is writable"). These two
            // fixtures differ from autostart.lua in nothing but the name.
            var allPresent = Model.parseHyprFiles([
                { name: "autostart.lua",   path: "/h/autostart.lua",   present: true,
                  mtime: 21, truncated: false, content: AUTOSTART_TEXT },
                { name: "windowrules.lua", path: "/h/windowrules.lua", present: true,
                  mtime: 22, truncated: false, content: WINDOWRULES_TEXT },
                { name: "workspaces.lua",  path: "/h/workspaces.lua",  present: true,
                  mtime: 23, truncated: false, content: WORKSPACES_TEXT }
            ]);
            check("hypr writable: the second envelope really has all three present",
                  String(allPresent[0].present) + "," + String(allPresent[1].present)
                  + "," + String(allPresent[2].present), "true,true,true");
            check("hypr writable: and none of them truncated",
                  String(allPresent[0].truncated) + "," + String(allPresent[1].truncated)
                  + "," + String(allPresent[2].truncated), "false,false,false");
            check("hypr writable: windowrules.lua is not writable, and only its NAME says so",
                  Model.hyprSectionIsWritable(allPresent[1]), false);
            check("hypr writable: workspaces.lua is not writable, and only its NAME says so",
                  Model.hyprSectionIsWritable(allPresent[2]), false);
            check("hypr writable: while autostart.lua in that same envelope is",
                  Model.hyprSectionIsWritable(allPresent[0]), true);
            check("hypr writable: windowrules.lua is not (absent in the first envelope)",
                  Model.hyprSectionIsWritable(sections[1]), false);
            check("hypr writable: workspaces.lua is not (truncated in the first envelope)",
                  Model.hyprSectionIsWritable(sections[2]), false);
            check("hypr writable: an absent autostart.lua is not",
                  Model.hyprSectionIsWritable({ name: "autostart.lua", present: false }), false);
            check("hypr writable: a truncated autostart.lua is not",
                  Model.hyprSectionIsWritable({ name: "autostart.lua", present: true,
                                                truncated: true }), false);
            check("hypr writable: nothing at all is not",
                  Model.hyprSectionIsWritable(undefined), false);

            // --- the counting the panel used to do itself ---------------------
            //
            // Finding 1 of the task 18 review: the bar widget's two numbers were
            // derived in Panel.qml by comparing section names, where nothing can
            // execute them. They are derived here now, and these are the
            // assertions that were impossible before.
            check("hypr counts: the programs are the autostart entries",
                  Model.hyprProgramCount(sections), 7);
            check("hypr counts: the placements are everything else",
                  Model.hyprPlacementCount(sections), 9);
            check("hypr counts: the two halves add up to the total",
                  Model.hyprProgramCount(sections) + Model.hyprPlacementCount(sections),
                  Model.hyprEntryCount(sections));
            check("hypr counts: a section that is not there counts as none",
                  Model.hyprProgramCount(Model.parseHyprFiles(undefined)), 0);
            check("hypr counts: the section is found by name, not by position",
                  Model.hyprSectionNamed(sections, "workspaces.lua").name, "workspaces.lua");
            check("hypr counts: a name no section carries gives null",
                  Model.hyprSectionNamed(sections, "bindings.lua"), null);

            // --- the three section notes ---------------------------------------
            //
            // Finding 2 of the task 18 review: these three sentences were inline
            // in Panel.qml. The empty string is the fourth case and the one that
            // decides whether the note is shown at all.
            check("hypr note: an absent file names its path",
                  Model.hyprSectionNoteText(sections[1]), "Not found: /h/windowrules.lua");
            check("hypr note: a truncated file says what is shown",
                  Model.hyprSectionNoteText(sections[2]).indexOf("larger than this panel reads") >= 0,
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
            check("hypr bracket: window rules get the same treatment",
                  Model.parseWindowRulesLua(
                      "--[[\no.window(\"x\", { workspace = \"2\" })\n]]\n").length, 0);
            check("hypr bracket: and so do workspace rules",
                  Model.parseWorkspacesLua(
                      "--[[\nhl.workspace_rule({ workspace = \"1\", monitor = \"DP-4\" })\n]]\n").length,
                  0);
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

            // --- the cutover, asserted rather than assumed -------------------------
            //
            // Panel.qml and Service.qml both read this and nothing here can
            // execute either of them, so the one thing a test CAN say is that
            // the switch exists in the namespace and is off. That it is
            // actually consulted, and where, is test/qml-structure.sh check 27.
            check("cutover: the write path is off",
                  Model.WRITE_PATH_ENABLED, false);

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
