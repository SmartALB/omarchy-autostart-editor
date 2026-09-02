import QtQml
import "../Model.js" as Model

QtObject {
    Component.onCompleted: {
        var failed = 0, total = 0;
        var currentTestName = "";

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
            total++;
            currentTestName = name;
            try {
                fn();
                failed++;
                console.warn("FAIL " + name + " -- expected a throw, got none");
            } catch (e) {
                var message = String((e && e.message) || e);
                if (expectedPattern && !expectedPattern.test(message)) {
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

            console.warn("total=" + total + " failed=" + failed);
            Qt.exit(failed === 0 ? 0 : 1);
        } catch (e) {
            var message = String((e && e.message) || e);
            console.warn("ERROR: harness broke in test '" + currentTestName + "': " + message);
            Qt.exit(3);
        }
    }
}
