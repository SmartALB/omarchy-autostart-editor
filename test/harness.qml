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
