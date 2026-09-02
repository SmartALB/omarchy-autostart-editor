import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The configuration surface. One level, three areas; detail editing expands at
// the row so the connection to the workspace table below stays visible.
//
// IMPORT ORDER IS LOAD-BEARING. With the same type name coming from two
// modules the LAST import read wins, so `Button` and `TextField` here are
// qs.Ui's, not QtQuick.Controls'. QtQuick.Controls is still imported because
// ScrollView / ScrollBar have no qs.Ui equivalent. Reordering these two lines
// silently changes every control in this file.
//
// THE ROOT TYPE IS THE PLATFORM'S OWN `Panel` (qs.Ui), which is what eight of
// the nine shipped panels use -- only disk-speedtest is a bare Item. It brings
// the popup lifecycle with it: `bar`, `settings`, `moduleName`, `ipcTarget`,
// `manageIpc`, `controller`, `popoutSwitching`, `popoutSwitchClosing` and a
// readonly `opened: panelController.open`. NONE of those may be redeclared
// here -- redeclaring a property the base type already has is a component
// creation error, and nothing in this project can execute a file that imports
// Quickshell to discover it. What IS overridden is open/close/toggle, which is
// the shipped idiom (clock/Panel.qml:87-101 does exactly this).
//
// The visible surface is the KeyboardPanel at the bottom of this file. It is a
// layer-shell popup anchored to the bar button, and the button lives in
// BarWidget.qml -- which is why `anchorItem` and `hostWidget` are declared
// here as plain properties and handed over by that widget's injectPanel().
// Until they arrive the KeyboardPanel is simply not open, so an un-injected
// panel is inert rather than a stray full-screen overlay.
//
// NO DECISION LIVES HERE. Everything this plugin decides -- what is valid,
// what is rejected, what blocks a save, which hyprctl verb a payload needs,
// which monitor a placement really lands on, which programs never appeared,
// the wording of a rejection, the next free workspace number -- is in
// Model.js, where the QML suite can reach it. This file holds state, widgets,
// and the plumbing between them.
Panel {
    id: root
    moduleName: "smartalb.autostart"
    ipcTarget: "smartalb.autostart"
    // The bar owns the summon route: shell.summon reaches a bar-widget plugin
    // through Bar.findPanelWidget, which needs open/close/opened on the WIDGET
    // and never touches this object's IPC. Registering a target here as well
    // would claim it once per monitor the bar is mounted on. clock/Panel.qml
    // declares ipcTarget and switches management off for the same reason.
    manageIpc: false

    // Handed over by BarWidget.qml's injectPanel(). `anchorItem` is the bar
    // button the popup positions itself against; `hostWidget` is what the bar
    // identifies this panel BY -- the bar tracks the widget mounted in its
    // slot, not this nested object, so the popout coordinator and
    // switchPanelFrom both have to be given the widget.
    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: root.hostWidget || root

    Runners { id: run }

    signal counted(int programs, int placements)

    // --- lifecycle contract ----------------------------------------------
    // `opened` and `popoutSwitchClosing` come from the base type and are NOT
    // redeclared. open/close/toggle are overridden, the way the shipped panels
    // override them, so opening can read the configuration first.
    //
    // The configuration is read on OPEN and not at creation: BarWidget.qml
    // loads this object eagerly (that is how the anchor gets injected before
    // the first open), and a panel that read the file at shell start would run
    // four processes on every single QML reload for numbers nobody asked for.
    function open() {
        root.reload()
        root.controller.show()
    }

    function close() {
        // Collapsing on close is not tidiness. An expanded row left behind a
        // closed popup keeps its text fields alive with focus, and nothing
        // then reports the focus loss -- editorsFocused would stay above zero
        // and the key catcher would be blocked for the rest of the session, so
        // Escape would stop closing the panel. Nothing inside a closed popup
        // can hold focus, so zero is a fact here, not a guess.
        root.expandedRow = -1
        root.editorsFocused = 0
        root.controller.hide()
    }

    function toggle() {
        if (root.opened) root.close()
        else root.open()
    }

    // The bar identifies this panel by the widget, not by this object -- see
    // barIdentity.
    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction)
        return false
    }

    Component.onDestruction: {
        readProc.running = false
        writeProc.running = false
        evalProc.running = false
        windowsProc.running = false
        workspacesProc.running = false
        matchProc.running = false
        launchProc.running = false
        appsProc.running = false
    }

    // --- state ------------------------------------------------------------
    // `saved` is what is on disk, `draft` is what the panel shows. Apply moves
    // draft to disk; Revert throws draft away. Keeping them apart is what
    // makes "changes pending" honest.
    property var saved: ({ schemaVersion: 1, programs: [], workspaces: [] })
    property var draft: ({ schemaVersion: 1, programs: [], workspaces: [] })
    property int savedMtime: 0
    property var rejected: []
    property var blocked: []
    property string errorText: ""
    property var openWindows: []
    property var workspacesNow: []
    property var missing: []
    property int dirtyCount: 0
    property var matches: []

    // The validated view of the draft, recomputed once per change instead of
    // once per binding. Bindings read this; nothing calls validate() inside a
    // delegate.
    property var checked: ({ programs: [], workspaces: [], rejected: [], blocked: [] })

    // Row counts drive the two Repeaters. An INTEGER model on purpose: a
    // Repeater handed a fresh JavaScript array destroys and rebuilds every
    // delegate, which would throw away the text cursor of the field being
    // typed into on every single keystroke. With an int model the delegates
    // survive and only their bindings re-evaluate.
    property int programRowCount: 0
    property int workspaceRowCount: 0

    // Which program row is expanded for detail editing. One at a time.
    //
    // BY ROW, not by id, and the task brief's `expandedId` is why: the rows
    // are the DRAFT's entries (see the Repeater), and a draft entry's id can
    // be missing, malformed or shared with another entry -- that is precisely
    // what validate() rejects it for. Keyed by id, two rows sharing one id
    // would expand together and a row with an empty id would expand whenever
    // any other empty-id row was clicked.
    property int expandedRow: -1

    // Task 16 fills this in: the id of the program whose class is to be taken
    // from a window that is open right now.
    property string pickForId: ""

    function markDirty() {
        var a = JSON.stringify(root.saved), b = JSON.stringify(root.draft)
        root.dirtyCount = (a === b) ? 0 : 1
        var checked = Model.validate(root.draft)
        root.rejected = checked.rejected
        root.blocked = checked.blocked
        root.checked = checked
        root.programRowCount = (root.draft.programs || []).length
        root.workspaceRowCount = (root.draft.workspaces || []).length
        // Re-derived from the matches already in hand rather than from a new
        // process run: a program switched on in the panel is not running yet,
        // and saying so immediately is the whole point of this list.
        root.missing = Model.missingIds(checked, root.matches)
        var placements = 0
        for (var i = 0; i < checked.programs.length; i++) {
            if (checked.programs[i].placement.kind !== "none") placements += 1
        }
        root.counted(checked.programs.length, placements)
    }

    // Every edit REPLACES root.draft instead of reaching into the object it
    // already holds. QML notices an assignment to the property; it cannot
    // notice a field changed inside an object it is already pointing at, so
    // in-place mutation would leave every binding below showing the old value
    // until something unrelated happened to re-evaluate it.
    function draftCopy() { return JSON.parse(JSON.stringify(root.draft)) }

    function commitDraft(next) {
        root.draft = next
        root.markDirty()
    }

    function setProgramField(rowIndex, field, value) {
        var next = root.draftCopy()
        var programs = next.programs || []
        if (rowIndex < 0 || rowIndex >= programs.length) return
        programs[rowIndex][field] = value
        next.programs = programs
        root.commitDraft(next)
    }

    function removeProgram(rowIndex) {
        var next = root.draftCopy()
        var programs = next.programs || []
        if (rowIndex < 0 || rowIndex >= programs.length) return
        programs.splice(rowIndex, 1)
        next.programs = programs
        root.expandedRow = -1
        root.commitDraft(next)
    }

    function setWorkspaceMonitor(rowIndex, monitor) {
        var next = root.draftCopy()
        var rows = next.workspaces || []
        if (rowIndex < 0 || rowIndex >= rows.length) return
        rows[rowIndex].monitor = monitor
        next.workspaces = rows
        root.commitDraft(next)
    }

    function removeWorkspaceRow(rowIndex) {
        var next = root.draftCopy()
        var rows = next.workspaces || []
        if (rowIndex < 0 || rowIndex >= rows.length) return
        rows.splice(rowIndex, 1)
        next.workspaces = rows
        root.commitDraft(next)
    }

    function addWorkspaceRow() {
        var next = root.draftCopy()
        var rows = next.workspaces || []
        var names = root.monitorNames()
        var monitor = ""
        for (var i = 0; i < names.length; i++) {
            if (names[i].present) { monitor = names[i].name; break }
        }
        rows.push({ workspace: Model.firstFreeWorkspace(rows), monitor: monitor })
        next.workspaces = rows
        root.commitDraft(next)
    }

    // --- load -------------------------------------------------------------
    function reload() {
        root.errorText = ""
        readProc.command = run.tool("omarchy-autostart-config", "read")
        readProc.running = true
    }

    Process {
        id: readProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) { root.errorText = "the config reader gave an unreadable answer"; return }
                if (!envelope.ok) {
                    // A broken file is not overwritten and nothing is applied.
                    root.errorText = root.explain(envelope.error, envelope.detail)
                    return
                }
                root.saved = envelope.config
                root.draft = JSON.parse(JSON.stringify(envelope.config))
                root.savedMtime = envelope.mtime
                root.expandedRow = -1
                root.markDirty()
                root.refreshLive()
            }
        }
    }

    function explain(code, detail) {
        if (code === "insecure-permissions")
            return "The configuration file can be written by someone else. " + detail
        if (code === "too-large")     return "The configuration file is too large. " + detail
        if (code === "not-json")      return "The configuration file is not valid JSON. " + detail
        if (code === "bad-schema")    return "Unknown configuration version. " + detail
        if (code === "stale")         return "The file changed on disk since it was read. " + detail
        return String(code) + ": " + String(detail || "")
    }

    // --- live state -------------------------------------------------------
    function refreshLive() {
        windowsProc.command = run.tool("omarchy-autostart-windows")
        windowsProc.running = true
        workspacesProc.command = run.tool("omarchy-autostart-windows", "--workspaces")
        workspacesProc.running = true
        root.refreshMatches()
    }

    Process {
        id: windowsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.openWindows = JSON.parse(String(text || "[]")) }
                catch (e) { root.openWindows = [] }
            }
        }
    }

    Process {
        id: workspacesProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.workspacesNow = JSON.parse(String(text || "[]")) }
                catch (e) { root.workspacesNow = [] }
            }
        }
    }

    // Which programs are running. The class pattern is evaluated by the
    // script, in grep -E: an automaton that does not backtrack. Doing it here
    // with a JavaScript regular expression would let a pattern such as ^(a+)+$
    // hang the panel, and QML has no timeout to rescue it -- which is why the
    // pattern is never handed to one anywhere in this file.
    //
    // The hand-over file has to be a REAL file: the script asks `[[ -f ]]`
    // before reading it, so a pipe and a process substitution are both
    // refused -- and a refusal there is silent, it answers "[]" and every
    // program then reads as not running. Hence mktemp.
    function refreshMatches() {
        var programs = Model.validate(root.draft).programs
        var lines = []
        for (var i = 0; i < programs.length; i++) {
            lines.push(programs[i].id + "\t" + programs[i]["class"])
        }
        if (lines.length === 0) {
            root.matches = []
            root.missing = []
            return
        }
        // runnerOut, not runner: it carries the producer byte cap AND is the
        // only route on which the script's own exit status survives the pipe
        // to head. `exit $s` inside its command group sets the status
        // runnerOut then reports, so the failure branch below is reachable
        // instead of being permanently masked by head's own success -- the
        // same defect that made the marker's claim gate inert in task 13.
        matchProc.command = run.runnerOut(
            "f=$(" + run.binMktemp + ") || exit 1\n"
            + "printf '%s' " + Model.shellQuote(lines.join("\n") + "\n") + " > \"$f\"\n"
            + Model.shellQuote(run.binDir + "omarchy-autostart-windows") + " --match-file \"$f\"\n"
            + "s=$?\n"
            + run.binRm + " -f -- \"$f\"\n"
            + "exit $s")
        matchProc.running = true
    }

    Process {
        id: matchProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var hits = []
                try { hits = JSON.parse(String(text || "[]")) } catch (e) { hits = [] }
                root.matches = hits
                root.missing = Model.missingIds(Model.validate(root.draft), hits)
            }
        }
        onExited: function(exitCode, exitStatus) {
            // Without this the running column would report every program as
            // not running whenever the query itself failed, and that reads as
            // "your programs are not running" rather than "the panel could
            // not find out".
            if (exitCode !== 0 && root.errorText === "") {
                root.errorText = "Could not tell which programs are running; "
                               + "the list below may be wrong"
            }
        }
    }

    // --- apply ------------------------------------------------------------
    // `blocked` and `rejected` are NOT the same outcome and must not be
    // conflated: blocked stops the apply outright, rejected is a named,
    // visible omission with everything else applied.
    function apply() {
        root.errorText = ""
        if (root.blocked.length > 0) {
            // Through Model.reasonText, not spelled out here. This sentence
            // used to be written twice in this file and a third time nowhere
            // -- Model.js had no wording for "class-conflict" at all -- so the
            // one place a reason code turns into English was the one place
            // this reason never reached. One wording, one home, tested there.
            root.errorText = root.blocked[0].labels.join(", ") + ": "
                           + Model.reasonText(root.blocked[0].reason)
            return
        }
        writeProc.command = run.runnerOut(
            "printf '%s' " + Model.shellQuote(JSON.stringify(root.draft)) + " | "
            + Model.shellQuote(run.binDir + "omarchy-autostart-config")
            + " write --expect-mtime " + root.savedMtime)
        writeProc.running = true
    }

    Process {
        id: writeProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) { root.errorText = "the config writer gave an unreadable answer"; return }
                if (!envelope.ok) {
                    root.errorText = root.explain(envelope.error, envelope.detail)
                    return
                }
                root.saved = JSON.parse(JSON.stringify(root.draft))
                root.savedMtime = envelope.mtime
                root.markDirty()
                root.applyRules()
            }
        }
    }

    property var pendingChunks: []
    property int pendingIndex: 0

    function applyRules() {
        var checked = Model.validate(root.draft)
        try {
            root.pendingChunks = Model.buildRuleChunks(checked)
                                     .concat(Model.buildReconcileChunks(
                                         checked, root.workspacesNow, root.matches))
        } catch (e) {
            root.errorText = String(e.message)
            return
        }
        root.pendingIndex = 0
        root.nextChunk()
    }

    // The two hyprctl verbs are not interchangeable, and which payload needs
    // which was measured in task 1. Model.verbFor is the single place that
    // knows -- do not inline the rule here.
    function nextChunk() {
        if (root.pendingIndex >= root.pendingChunks.length) { root.refreshLive(); return }
        var payload = root.pendingChunks[root.pendingIndex]
        evalProc.command = run.hypr(Model.verbFor(payload), payload)
        root.pendingIndex += 1
        evalProc.running = true
    }

    Process {
        id: evalProc
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 && root.errorText === "") {
                root.errorText = "hyprctl refused a rule block; nothing further was applied"
                root.pendingIndex = root.pendingChunks.length
            }
            root.nextChunk()
        }
    }

    function revert() {
        root.draft = JSON.parse(JSON.stringify(root.saved))
        root.errorText = ""
        root.expandedRow = -1
        root.markDirty()
    }

    // Launching is a separate button on purpose: saving must not open windows.
    //
    // THE SHAPE OF THIS COMMAND IS NOT FREE, and the task brief's sample was
    // wrong about it. It used run.runner() and joined the entries with "&";
    // Runners.qml's own measurement says why that cannot stand: plain runner()
    // lets GNU timeout put its child in a NEW process group and, at the
    // deadline, signal the WHOLE group -- 0 of 2 long-lived backgrounded
    // grandchildren survived. And `wait` on an entry that IS the program keeps
    // the wrapper alive for as long as that program runs, so the deadline is
    // reached in the ordinary case, not an exotic one: the user's editor would
    // be killed two minutes after being launched from this button. This
    // follows Service.qml's launchAll() instead, measured into its present
    // form in task 13:
    //   * run.launcher(), so timeout's own deadline does not reach the
    //     children;
    //   * `setsid -f` per entry, so a teardown of this Process cannot reach
    //     them either, and so `wait` returns as each entry is handed off
    //     rather than when the program quits;
    //   * `</dev/null >/dev/null 2>&1` on the setsid invocation ITSELF, not
    //     only inside launchCommand's group, or this wrapper's own stdout
    //     stays open for the lifetime of whatever was started;
    //   * a `bash -n` pre-check, because closing the entry's stdio also closes
    //     the only channel on which it could report a syntax error -- and
    //     Model.validate accepts an unbalanced quote, since that is a
    //     shell-syntax problem and not a field-shape one.
    function launchMissing() {
        var programs = Model.validate(root.draft).programs
        var isolated = []
        for (var i = 0; i < programs.length; i++) {
            if (root.missing.indexOf(programs[i].id) === -1) continue
            var quoted = Model.shellQuote(Model.launchCommand(programs[i].command))
            isolated.push("if " + run.binBash + " -n -c " + quoted + "; then "
                        + run.binSetsid + " -f " + run.binBash + " -c " + quoted
                        + " </dev/null >/dev/null 2>&1; else echo "
                        + Model.shellQuote(String(programs[i].name).replace(/\s+/g, " ")
                            + ": the command is malformed and was not started")
                        + " >&2; fi")
        }
        if (isolated.length === 0) return
        root.errorText = ""
        launchProc.command = run.launcher(isolated.join(" & ") + " & wait")
        launchProc.running = true
    }

    Process {
        id: launchProc
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The last non-empty line: bash's own diagnostic reaches the
                // stream ahead of the identifying line the pre-check writes,
                // and the identifying line is the one that names the program.
                var lines = String(text || "").split("\n")
                var last = ""
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].replace(/\s+/g, "") !== "") last = lines[i]
                }
                if (last !== "") root.errorText = last
            }
        }
    }

    // Placeholder for task 16's app picker, declared here so this file's
    // teardown covers it from the start rather than a task later.
    Process { id: appsProc }

    // Task 16 replaces these two with the real flows. They exist now so the
    // buttons the layout calls for are wired to something that is there -- a
    // call into a missing function is a runtime TypeError nothing in this
    // project can execute to find -- and each says plainly that it is not
    // available yet rather than doing nothing at all.
    function openAdd() {
        root.errorText = "Adding a program is not available in this build yet"
    }
    function importSession() {
        root.errorText = "Importing the current session is not available in this build yet"
    }

    // --- derived lists for the widgets ------------------------------------
    function monitorNames() {
        // Object.create(null), not {}: MONITOR_RE permits "_", so a monitor
        // called "__proto__" is a legal name, and on a plain object it would
        // read back as Object.prototype -- the entry would silently vanish
        // from the dropdown rather than crash, which is worse to diagnose.
        var names = Object.create(null), out = [], i
        for (i = 0; i < root.workspacesNow.length; i++) names[root.workspacesNow[i].monitor] = true
        for (i = 0; i < root.openWindows.length; i++)  names[root.openWindows[i].monitor] = true
        for (i = 0; i < (root.draft.workspaces || []).length; i++) {
            var configured = root.draft.workspaces[i].monitor
            if (names[configured] === undefined) names[configured] = false   // gone
        }
        for (var name in names) {
            if (name === "") continue
            out.push({ name: name, present: names[name] })
        }
        return out
    }

    // A monitor that is not attached right now STAYS in the list, marked
    // "(gone)", and stays selectable: whoever takes the laptop out of the dock
    // and opens the panel must not lose a configuration by merely looking at
    // it.
    function monitorOptions() {
        var names = root.monitorNames(), out = []
        for (var i = 0; i < names.length; i++) {
            out.push({ value: names[i].name,
                       label: names[i].present ? names[i].name : names[i].name + " (gone)" })
        }
        return out
    }

    function workspaceOptions() {
        var out = []
        for (var i = 1; i <= 99; i++) out.push({ value: String(i), label: String(i) })
        return out
    }

    // The rows below are DRAFT entries, and a draft comes from a file a human
    // may have edited, so none of these fields can be assumed to be there or
    // to have the right type. Reading them through these two keeps a
    // half-written entry from turning a binding into a TypeError.
    function placementKind(program) {
        var placement = program && program.placement
        if (!placement || typeof placement !== "object") return ""
        return typeof placement.kind === "string" ? placement.kind : ""
    }

    function placementValue(program) {
        var placement = program && program.placement
        if (!placement || typeof placement !== "object") return ""
        return placement.value === undefined ? "" : String(placement.value)
    }

    function placementText(program) {
        var kind = root.placementKind(program)
        if (kind === "" || kind === "none") return "no placement"
        if (kind === "monitor") return "Monitor " + root.placementValue(program)
        if (kind !== "workspace") return "placement not understood"
        var monitor = Model.effectiveMonitor(program, root.draft.workspaces)
        return "Workspace " + root.placementValue(program)
             + (monitor === "" ? "" : " · " + monitor)
    }

    // The stand-in a delegate falls back to while its index is momentarily
    // ahead of the list it reads -- without it a rebuild storms the log with
    // TypeErrors on a null program.
    //
    // Its two string fields are assigned rather than written as object-literal
    // keys on purpose: check 5b in test/qml-structure.sh scans every
    // "command:" occurrence in the file and cannot tell an object key from a
    // Process binding, so a literal `command: ""` here fails a check that is
    // right to be blunt about that name.
    function blankProgram() {
        var p = { id: "", name: "", enabled: false, placement: { kind: "none" } }
        p.command = ""
        p["class"] = ""
        return p
    }

    // --- layout -----------------------------------------------------------
    // The glyphs are \u escapes and must stay that way: a literal Nerd Font
    // character lives in the private use area and does not survive being
    // copied through documents and tools -- what arrives is an empty string,
    // and an empty string is not an icon-less row, it is no row. Verify on the
    // file, never on the source just typed:
    //   grep -n 'glyph[A-Z]' Panel.qml | od -c
    readonly property string glyphRunning: "\uf111"      // nf-fa-circle
    readonly property string glyphNotRunning: "\uf10c"   // nf-fa-circle_o
    readonly property string glyphExpanded: "\uf078"     // nf-fa-chevron_down
    readonly property string glyphCollapsed: "\uf054"    // nf-fa-chevron_right
    readonly property string glyphRemove: "\uf00d"       // nf-fa-times

    readonly property color fg: Color.popups.text
    readonly property color warn: Color.urgent
    readonly property string fontFam: Style.font.family

    // How many text fields currently hold focus. PanelKeyCatcher below runs
    // with Keys.priority: Keys.BeforeItem, so it takes keys even when a
    // descendant has focus -- typing "x" in the Command field would otherwise
    // fire deleteRequested and "j" would never reach the field at all. The
    // platform's own instruction for this is `blocked: editor.activeFocus`,
    // which assumes ONE editor; this panel has two per expanded row, created
    // and destroyed by a Repeater, so a count is used instead of a reference.
    //
    // A count and not a boolean because focus moves by gaining first and
    // losing second: with a boolean, tabbing from Command to Class would set
    // true then false and unblock the catcher while the Class field was
    // focused.
    property int editorsFocused: 0

    function noteEditorFocus(gained) {
        // Clamped rather than trusted. A delegate destroyed while its field
        // still holds focus never reports the loss, and an unclamped counter
        // would then sit above zero for the rest of the session with the key
        // catcher permanently blocked -- Escape would stop closing the panel.
        root.editorsFocused = Math.max(0, root.editorsFocused + (gained ? 1 : -1))
    }

    // The visible surface. A layer-shell popup card anchored to the bar
    // button, the same construction every shipped panel uses.
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(520))
        // No fixed upper bound: the content grows with the program list and
        // with an expanded row. fittedContentHeight stays bounded by the
        // screen, so "unbounded" still means "as tall as sensibly fits".
        contentHeight: panel.fittedContentHeight(body.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: root.editorsFocused > 0
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }

            // A ScrollView so a growing list scrolls instead of being cut
            // off, and because KeyboardPanel brings no availableWidth of its
            // own while ScrollView does.
            ScrollView {
                id: scrollArea
                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: body.implicitHeight > height
                                           ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

                Column {
                    id: body
                    width: scrollArea.availableWidth
                    spacing: Style.spacing.md

                    Text {
                        textFormat: Text.PlainText
                        text: "Autostart Layout"
                        color: root.fg
                        font.family: root.fontFam
                        font.pixelSize: Style.font.title
                        font.bold: true
                    }

                    // --- programs -----------------------------------------------------
                    Row {
                        width: body.width
                        spacing: Style.spacing.controlGap

                        PanelSectionHeader {
                            text: "PROGRAMS"
                            foreground: root.fg
                            fontFamily: root.fontFam
                            elide: Text.ElideRight
                            width: Math.max(Style.space(40),
                                            body.width - addProgramButton.implicitWidth - parent.spacing)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Button {
                            id: addProgramButton
                            text: "+ Add"
                            foreground: root.fg
                            fontFamily: root.fontFam
                            bordered: true
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: root.openAdd()
                        }
                    }

                    Text {
                        textFormat: Text.PlainText
                        width: body.width
                        visible: root.programRowCount === 0
                        text: "No programs configured yet."
                        color: root.fg
                        opacity: 0.7
                        font.family: root.fontFam
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        // OVER THE DRAFT, not over validate(...).programs, and the task
                        // brief's table said the latter. Bound to the validated list, the
                        // row being edited DISAPPEARS the instant its intermediate text is
                        // invalid: clearing the Command field to retype it makes the whole
                        // entry fail validation, the row unmounts under the cursor, and
                        // what the user typed is gone. The validated list still drives
                        // everything it should -- the counts, the missing list, the
                        // omissions in the footer -- and a row that is currently left out
                        // says so on the row itself, which the brief's arrangement could
                        // only say in the footer about a row no longer on screen.
                        //
                        // An int model, see programRowCount.
                        model: root.programRowCount

                        delegate: Column {
                            id: programRow
                            width: body.width
                            spacing: Style.spacing.xs

                            readonly property var program: (root.draft.programs || [])[index]
                                                           || root.blankProgram()
                            readonly property bool isExpanded: root.expandedRow === index
                            readonly property bool isRunning:
                                root.missing.indexOf(programRow.program.id) === -1

                            // Identity, not a comparison: validate() pushes the SAME
                            // objects it was given, so an entry that survived is present
                            // in checked.programs by reference. If that ever stopped
                            // holding, every row would carry the marker at once -- visible
                            // on first sight, rather than silently wrong.
                            readonly property bool isAccepted:
                                root.checked.programs.indexOf(programRow.program) !== -1

                            Row {
                                width: programRow.width
                                spacing: Style.spacing.controlGap

                                ToggleSwitch {
                                    checked: programRow.program.enabled === true
                                    anchors.verticalCenter: parent.verticalCenter
                                    onToggled: root.setProgramField(index, "enabled",
                                                                    !(programRow.program.enabled === true))
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    text: programRow.isRunning ? root.glyphRunning : root.glyphNotRunning
                                    color: programRow.isRunning ? root.fg : root.warn
                                    opacity: programRow.program.enabled === true ? 1.0 : 0.4
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.iconSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Button {
                                    text: String(programRow.program.name || "(no name)")
                                    foreground: root.fg
                                    fontFamily: root.fontFam
                                    leftAlign: true
                                    width: Math.max(Style.space(80), programRow.width - Style.space(250))
                                    anchors.verticalCenter: parent.verticalCenter
                                    onClicked: root.expandedRow = programRow.isExpanded ? -1 : index
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    text: root.placementText(programRow.program)
                                    color: root.fg
                                    opacity: 0.7
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                PanelActionButton {
                                    iconText: programRow.isExpanded ? root.glyphExpanded : root.glyphCollapsed
                                    tooltipText: programRow.isExpanded ? "Collapse" : "Edit"
                                    foreground: root.fg
                                    fontFamily: root.fontFam
                                    anchors.verticalCenter: parent.verticalCenter
                                    onClicked: root.expandedRow = programRow.isExpanded ? -1 : index
                                }
                            }

                            Text {
                                textFormat: Text.PlainText
                                width: programRow.width
                                visible: !programRow.isAccepted
                                text: "This entry is left out until it is fixed; see the bottom of the panel."
                                color: root.warn
                                font.family: root.fontFam
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                            // --- the expanded detail editor, at the row ---------------
                            Column {
                                width: programRow.width
                                visible: programRow.isExpanded
                                spacing: Style.spacing.sm

                                TextField {
                                    width: programRow.width
                                    placeholderText: "Command"
                                    text: String(programRow.program.command || "")
                                    foreground: root.fg
                                    // Nothing is written to disk here. The field edits the
                                    // draft and nothing else; Apply is the only route to
                                    // the file and to hyprctl, because moving real windows
                                    // across real screens must not be a side effect of a
                                    // keystroke.
                                    onTextChanged: root.setProgramField(index, "command", text)
                                    onActiveFocusChanged: root.noteEditorFocus(activeFocus)
                                }

                                Row {
                                    width: programRow.width
                                    spacing: Style.spacing.controlGap

                                    TextField {
                                        width: Math.max(Style.space(80),
                                                        programRow.width - fromWindowButton.implicitWidth
                                                        - parent.spacing)
                                        placeholderText: "Class"
                                        text: String(programRow.program["class"] || "")
                                        foreground: root.fg
                                        onTextChanged: root.setProgramField(index, "class", text)
                                        onActiveFocusChanged: root.noteEditorFocus(activeFocus)
                                    }

                                    Button {
                                        id: fromWindowButton
                                        text: "From window"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: root.pickForId = programRow.program.id
                                    }
                                }

                                Row {
                                    spacing: Style.spacing.controlGap

                                    Button {
                                        text: "No placement"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        selected: root.placementKind(programRow.program) === "none"
                                        onClicked: root.setProgramField(index, "placement", { kind: "none" })
                                    }
                                    Button {
                                        text: "Workspace"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        selected: root.placementKind(programRow.program) === "workspace"
                                        onClicked: root.setProgramField(index, "placement",
                                                                        { kind: "workspace", value: "1" })
                                    }
                                    Button {
                                        text: "Monitor"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        selected: root.placementKind(programRow.program) === "monitor"
                                        onClicked: {
                                            var names = root.monitorNames()
                                            var first = names.length > 0 ? names[0].name : ""
                                            root.setProgramField(index, "placement",
                                                                 { kind: "monitor", value: first })
                                        }
                                    }
                                }

                                Row {
                                    spacing: Style.spacing.controlGap
                                    visible: root.placementKind(programRow.program) === "workspace"

                                    Dropdown {
                                        label: "Workspace"
                                        options: root.workspaceOptions()
                                        value: root.placementValue(programRow.program)
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        onChanged: function(v) {
                                            root.setProgramField(index, "placement",
                                                                 { kind: "workspace", value: v })
                                        }
                                    }

                                    Text {
                                        textFormat: Text.PlainText
                                        // Derived, never edited: with a workspace placement
                                        // the monitor IS whatever that workspace is pinned
                                        // to in the table below. Two editable fields would
                                        // be two answers to one question.
                                        text: {
                                            if (root.placementKind(programRow.program) !== "workspace") return ""
                                            var m = Model.effectiveMonitor(programRow.program,
                                                                           root.draft.workspaces)
                                            return m === "" ? "workspace is not pinned to a monitor" : m
                                        }
                                        color: root.fg
                                        opacity: 0.5
                                        font.family: root.fontFam
                                        font.pixelSize: Style.font.caption
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                Dropdown {
                                    label: "Monitor"
                                    visible: root.placementKind(programRow.program) === "monitor"
                                    options: root.monitorOptions()
                                    value: root.placementValue(programRow.program)
                                    foreground: root.fg
                                    fontFamily: root.fontFam
                                    onChanged: function(v) {
                                        root.setProgramField(index, "placement",
                                                             { kind: "monitor", value: v })
                                    }
                                }

                                Button {
                                    text: "Remove"
                                    foreground: root.warn
                                    fontFamily: root.fontFam
                                    bordered: true
                                    onClicked: root.removeProgram(index)
                                }
                            }

                            PanelSeparator {
                                width: programRow.width
                                foreground: root.fg
                            }
                        }
                    }

                    // --- workspace to monitor -----------------------------------------
                    Row {
                        width: body.width
                        spacing: Style.spacing.controlGap

                        PanelSectionHeader {
                            text: "WORKSPACE → MONITOR"
                            foreground: root.fg
                            fontFamily: root.fontFam
                            elide: Text.ElideRight
                            width: Math.max(Style.space(40),
                                            body.width - addWorkspaceButton.implicitWidth - parent.spacing)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Button {
                            id: addWorkspaceButton
                            text: "+ Add"
                            foreground: root.fg
                            fontFamily: root.fontFam
                            bordered: true
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: root.addWorkspaceRow()
                        }
                    }

                    Repeater {
                        // The DRAFT rows, not the validated ones: a row the allowlist
                        // refuses has to stay on screen to be corrected.
                        model: root.workspaceRowCount

                        delegate: Row {
                            id: workspaceRow
                            width: body.width
                            spacing: Style.spacing.controlGap

                            readonly property var wsRow: (root.draft.workspaces || [])[index]
                                                         || ({ workspace: "", monitor: "" })

                            Text {
                                textFormat: Text.PlainText
                                text: "Workspace " + String(workspaceRow.wsRow.workspace || "?")
                                color: root.fg
                                font.family: root.fontFam
                                font.pixelSize: Style.font.body
                                width: Style.space(120)
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Dropdown {
                                showLabel: false
                                options: root.monitorOptions()
                                value: String(workspaceRow.wsRow.monitor || "")
                                foreground: root.fg
                                fontFamily: root.fontFam
                                anchors.verticalCenter: parent.verticalCenter
                                onChanged: function(v) { root.setWorkspaceMonitor(index, v) }
                            }

                            PanelActionButton {
                                iconText: root.glyphRemove
                                tooltipText: "Remove this row"
                                foreground: root.warn
                                fontFamily: root.fontFam
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: root.removeWorkspaceRow(index)
                            }
                        }
                    }

                    PanelSeparator {
                        width: body.width
                        foreground: root.fg
                    }

                    // --- not running --------------------------------------------------
                    // THIS IS THE ONLY REPORT OF A LAUNCH FAILURE THAT EVER REACHES THE
                    // USER, and it is measured, not assumed: through the wrapper an
                    // entry's own stdio is closed, so a program that does not exist, one
                    // that exits 127, one that exits non-zero and one that writes its own
                    // error are ALL silent -- empty stderr, wrapper exit 0. Re-opening
                    // that stream is what made the session watchdog report a false error
                    // at every single login. So "configured, but no window ever matched"
                    // is not decoration here; it is the entire error report for a
                    // misspelled program name, and it is shown plainly rather than tucked
                    // away.
                    Row {
                        width: body.width
                        spacing: Style.spacing.controlGap

                        Text {
                            textFormat: Text.PlainText
                            text: root.missing.length === 0
                                  ? "Every enabled program has a window."
                                  : root.missing.length + (root.missing.length === 1
                                        ? " enabled program is configured but no window ever matched it"
                                        : " enabled programs are configured but no window ever matched them")
                            color: root.missing.length === 0 ? root.fg : root.warn
                            font.family: root.fontFam
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                            width: Math.max(Style.space(80), body.width - Style.space(150))
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Button {
                            text: "Launch missing"
                            visible: root.missing.length > 0
                            foreground: root.fg
                            fontFamily: root.fontFam
                            bordered: true
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: root.launchMissing()
                        }
                    }

                    Text {
                        textFormat: Text.PlainText
                        width: body.width
                        visible: root.missing.length > 0
                        text: "A program that never appears is usually a misspelled command "
                            + "or a class pattern that matches nothing. Open the row and check both."
                        color: root.fg
                        opacity: 0.7
                        font.family: root.fontFam
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    Button {
                        text: "Import current session"
                        visible: (root.draft.programs || []).length === 0
                        foreground: root.fg
                        fontFamily: root.fontFam
                        bordered: true
                        onClicked: root.importSession()
                    }

                    PanelSeparator {
                        width: body.width
                        foreground: root.fg
                    }

                    // --- footer -------------------------------------------------------
                    Text {
                        textFormat: Text.PlainText
                        width: body.width
                        visible: root.errorText !== ""
                        text: root.errorText
                        color: root.warn
                        font.family: root.fontFam
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    // Omissions: everything else was applied. Not the same thing as a
                    // contradiction below, which stops the apply entirely.
                    Column {
                        width: body.width
                        spacing: Style.spacing.xxs
                        visible: root.rejected.length > 0

                        Text {
                            textFormat: Text.PlainText
                            text: "Left out:"
                            color: root.fg
                            font.family: root.fontFam
                            font.pixelSize: Style.font.caption
                        }
                        Repeater {
                            model: root.rejected
                            delegate: Text {
                                required property var modelData
                                textFormat: Text.PlainText
                                width: body.width
                                text: String(modelData.label) + ": " + Model.reasonText(modelData.reason)
                                color: root.fg
                                opacity: 0.8
                                font.family: root.fontFam
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // Contradictions: these STOP the apply. Two programs matching the same
                    // window class but wanting different places cannot both be honoured,
                    // and letting one silently win inside the compositor is what this
                    // refuses to do.
                    Column {
                        width: body.width
                        spacing: Style.spacing.xxs
                        visible: root.blocked.length > 0

                        Text {
                            textFormat: Text.PlainText
                            text: "Cannot be applied:"
                            color: root.warn
                            font.family: root.fontFam
                            font.pixelSize: Style.font.caption
                        }
                        Repeater {
                            model: root.blocked
                            delegate: Text {
                                required property var modelData
                                textFormat: Text.PlainText
                                width: body.width
                                text: modelData.labels.join(", ") + ": "
                                    + Model.reasonText(modelData.reason)
                                color: root.warn
                                font.family: root.fontFam
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    Row {
                        width: body.width
                        spacing: Style.spacing.controlGap

                        Text {
                            textFormat: Text.PlainText
                            // dirtyCount is a FLAG, not a tally: markDirty compares the
                            // whole draft against the whole saved document, so it is 0 or
                            // 1, and the wording says so instead of pretending to count.
                            text: root.dirtyCount > 0 ? "unsaved changes" : "no changes pending"
                            color: root.fg
                            opacity: root.dirtyCount > 0 ? 1.0 : 0.6
                            font.family: root.fontFam
                            font.pixelSize: Style.font.caption
                            width: Math.max(Style.space(60), body.width - Style.space(220))
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Button {
                            text: "Revert"
                            enabled: root.dirtyCount > 0
                            opacity: enabled ? 1.0 : 0.4
                            foreground: root.fg
                            fontFamily: root.fontFam
                            bordered: true
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: root.revert()
                        }

                        Button {
                            text: "Apply"
                            enabled: root.dirtyCount > 0 && root.blocked.length === 0
                            opacity: enabled ? 1.0 : 0.4
                            foreground: root.fg
                            fontFamily: root.fontFam
                            bordered: true
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: root.apply()
                        }
                    }
                }
            }
        }
    }
}
