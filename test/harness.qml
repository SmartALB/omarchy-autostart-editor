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
