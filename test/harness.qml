import QtQml
import "../Model.js" as Model

QtObject {
    Component.onCompleted: {
        var failed = 0, total = 0;

        function check(name, got, want) {
            total++;
            if (got !== want) {
                failed++;
                console.warn("FAIL " + name + "\n       got  " + got + "\n       want " + want);
            } else {
                console.warn("ok   " + name);
            }
        }

        function checkThrows(name, fn) {
            total++;
            try {
                fn();
                failed++;
                console.warn("FAIL " + name + " -- expected a throw, got none");
            } catch (e) {
                console.warn("ok   " + name);
            }
        }

        // --- luaBytes: every value that reaches Lua is encoded as bytes ---
        check("luaBytes encodes ascii",
              Model.luaBytes("ab"), "string.char(97,98)");
        check("luaBytes leaves no quote in the payload",
              Model.luaBytes('a"b').indexOf('"'), -1);
        check("luaBytes leaves no brace in the payload",
              Model.luaBytes("a}b").indexOf("}"), -1);
        check("luaBytes payload is digits and commas only",
              /^string\.char\([0-9,]+\)$/.test(Model.luaBytes("^(cursor)$")), true);
        checkThrows("luaBytes refuses non-ascii",
                    function() { Model.luaBytes("café"); });

        console.warn("total=" + total + " failed=" + failed);
        Qt.exit(failed === 0 ? 0 : 1);
    }
}
