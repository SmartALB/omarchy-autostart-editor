import QtQml
import "../Model.js" as Model

// Prints the generated Lua chunks separated by a marker line, so the shell
// suite can hand each one to a real Lua compiler. String matching cannot tell
// a well-formed chunk from a broken one; luac can.
QtObject {
    Component.onCompleted: {
        var raw = Qt.application.arguments.length > 1
                ? Qt.application.arguments[Qt.application.arguments.length - 1]
                : "{}";
        var chunks = Model.buildRuleChunks(Model.validate(JSON.parse(raw)));
        for (var i = 0; i < chunks.length; i++) {
            console.warn("----8<----");
            console.warn(chunks[i]);
        }
        Qt.exit(0);
    }
}
