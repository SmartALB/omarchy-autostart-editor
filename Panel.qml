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
        // setExpandedRow already moves focus off any field, so the counter
        // comes down on its own. The explicit zero stays as a belt: nothing
        // inside a closed popup can hold focus, so it is a fact here rather
        // than a guess, and it also recovers a counter stranded by some future
        // path that forgets the setter.
        root.setExpandedRow(-1)
        root.editorsFocused = 0
        // A closed panel offers nothing: the picker does not come back open on
        // the next click with a stale application list behind it, and a pending
        // import is cancelled rather than landing in a draft nobody is looking
        // at (reload() would replace it on the next open anyway).
        root.addOpen = false
        root.importPending = false
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
        hyprProc.running = false
    }

    // THE CUTOVER, and this panel's ONE named place for it. The switch is
    // Model.WRITE_PATH_ENABLED; the reasoning is the block comment above it in
    // Model.js. While it is off, this panel OFFERS nothing from the old half:
    // the program list, the [+ Add] picker, the workspace table, the import,
    // the "launch missing" route, Revert and Apply are all hidden, and apply()
    // itself refuses. What it shows instead is the read of the user's own
    // Hyprland files, below.
    //
    // A single property read from every one of those places, rather than
    // Model.WRITE_PATH_ENABLED repeated at each: one place to look, and one
    // place a structural check can point at.
    readonly property bool offersEditing: Model.WRITE_PATH_ENABLED

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

    // Every change of the expanded row goes through setExpandedRow(), which
    // hands focus back to the key catcher FIRST.
    //
    // MEASURED, offscreen qml on a stub of this exact shape (a Repeater of
    // rows, a TextField per expanded row reporting focus into the counter, and
    // a collapse by visible:false):
    //   collapsed as it was  -> editorsFocused=1 blocked=true  activeFocusItem=field1 fieldVisible=false
    //   collapsed via setter -> editorsFocused=0 blocked=false activeFocusItem=keyCatcher
    // Collapsing clears no focus and fires no activeFocusChanged, so the
    // counter stuck at 1: Escape was swallowed for the rest of the open
    // session, and the now-invisible field stayed the window's activeFocusItem
    // -- keystrokes went on editing the draft with Apply ready to save them.
    // Moving focus while the field still EXISTS is what makes its own signal
    // arrive, so this is not a second bookkeeping path bolted on beside the
    // first; it is what the first one was waiting for.
    function setExpandedRow(next) {
        if (keyCatcher) keyCatcher.forceActiveFocus()
        // Any window pick in progress ends here too. pickForRow is an INDEX,
        // and every caller of this setter -- collapse, remove, reload, revert,
        // close -- can make that index mean a different row than the one the
        // user opened the picker on.
        root.pickForRow = -1
        root.expandedRow = next
    }

    // Which program row is expanded for detail editing. One at a time.
    //
    // BY ROW, not by id, and the task brief's `expandedId` is why: the rows
    // are the DRAFT's entries (see the Repeater), and a draft entry's id can
    // be missing, malformed or shared with another entry -- that is precisely
    // what validate() rejects it for. Keyed by id, two rows sharing one id
    // would expand together and a row with an empty id would expand whenever
    // any other empty-id row was clicked.
    property int expandedRow: -1

    // The installed applications, as read for the [+ Add] picker and for the
    // first-run import. Empty until one of the two asks for them.
    property var apps: []
    property bool addOpen: false
    property bool appsPending: false
    property bool importPending: false

    // The two things that can go wrong with the application list, tracked
    // apart because the user can act on one of them and not on the other.
    // appsTruncated comes from runnerOut's own marker on stderr -- which this
    // panel used to throw away, and that is the whole reason the previous
    // round could only say "broken" for a list that was merely too long. At
    // roughly 137 bytes per entry the script's 2000-file bound reaches 230-270
    // KB against runnerOut's 256 KiB cap, so this is a reachable state, not a
    // theoretical one.
    property bool appsTruncated: false
    property bool appsUnparseable: false
    property string appsProblemText: ""

    // Which program row is currently taking its class from a window that is
    // open right now.
    //
    // BY ROW, not by id, for the same reason expandedRow is (see there): the
    // rows are the DRAFT's entries, and a draft entry's id can be missing,
    // malformed or shared with another entry -- that is precisely what
    // validate() rejects it for. Keyed by id, picking a class would write it
    // into EVERY row sharing that id, placing a program the user never picked
    // for, and a row with an empty id would pick whenever any other empty-id
    // row did.
    property int pickForRow: -1

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
        root.setExpandedRow(-1)
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

    // --- the read of the user's own Hyprland files ------------------------
    //
    // The three sections the panel shows, in file order, always all three.
    // Empty until the first read answers; Model.parseHyprFiles is what turns
    // the envelope into them, and every entry in them carries its 1-based line
    // number and the original line text -- the two fields the later line
    // surgery rests on.
    property var hyprSections: []
    property string hyprError: ""

    function readHypr() {
        root.hyprError = ""
        hyprProc.command = run.tool("omarchy-autostart-hypr", "read")
        hyprProc.running = true
    }

    Process {
        id: hyprProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) {
                    root.hyprError = "the Hyprland file reader gave an unreadable answer"
                    return
                }
                if (!envelope.ok) {
                    // Worded, never the bare code -- the same rule the
                    // configuration envelope follows.
                    root.hyprError = Model.envelopeText(envelope.error, envelope.detail)
                    return
                }
                root.hyprSections = Model.parseHyprFiles(envelope.files)
                // The bar tooltip's two numbers, now taken from the source of
                // truth the panel actually reads: autostart entries are the
                // programs, window and workspace rules are the placements.
                // Leaving this unemitted would make the widget report nothing
                // at all while the panel showed thirty entries.
                var programs = 0, placements = 0
                for (var i = 0; i < root.hyprSections.length; i++) {
                    var section = root.hyprSections[i]
                    var count = (section.entries || []).length
                    if (section.name === "autostart.lua") programs += count
                    else placements += count
                }
                root.counted(programs, placements)
            }
        }
    }

    // --- load -------------------------------------------------------------
    function reload() {
        root.errorText = ""
        root.readHypr()
        // The old half's read too, but only while it is connected. See
        // root.offersEditing.
        if (!root.offersEditing) return
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
                    root.errorText = Model.envelopeText(envelope.error, envelope.detail)
                    return
                }
                root.saved = envelope.config
                root.draft = JSON.parse(JSON.stringify(envelope.config))
                root.savedMtime = envelope.mtime
                root.setExpandedRow(-1)
                root.markDirty()
                root.refreshLive()
            }
        }
    }

    // --- live state -------------------------------------------------------
    // Split out of refreshLive: [From window] needs the window list to be
    // current -- a program started since the panel opened must be pickable --
    // and it has no business re-running the match query to get it.
    function refreshWindows() {
        windowsProc.command = run.tool("omarchy-autostart-windows")
        windowsProc.running = true
    }

    function refreshLive() {
        root.refreshWindows()
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
        // The gate, not merely the hidden button. See root.offersEditing: with
        // the old half disconnected there is no route by which this may write
        // a file or reach the compositor, and a hidden control is not a route
        // that has been closed -- an IPC call, a future keybinding or a
        // half-finished refactor could all still find this function.
        if (!root.offersEditing) return
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
                    root.errorText = Model.envelopeText(envelope.error, envelope.detail)
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
        // The gate, for the same reason apply() carries one: see
        // root.offersEditing. Nothing reaches the compositor while the old
        // half is disconnected.
        if (!root.offersEditing) return
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
        // SAME PAYLOAD, SAME HELPER, SAME CHECK AS Service.qml:361-386. This
        // used to read only exitCode, which made the interactive path -- the
        // one where the user is watching and pressed Apply -- the weaker of
        // the two appliers. `hyprctl eval` answers "ok" when the Lua chunk
        // parsed and ran without a Lua error; anything else means the chunk
        // did NOT run.
        //
        // What "ok" does NOT mean, and the reason CHECKLIST.md C9 stays open:
        // this project's own probe recorded hyprctl answering "ok" for a
        // dispatch with no visible effect at all. So "ok" confirms the chunk
        // was accepted, never that a rule inside it applies.
        //
        // Both handlers guard on `errorText === ""` and both fast-forward
        // pendingIndex, so whichever of onStreamFinished and onExited
        // Quickshell emits first, the outcome is the same and the message is
        // the first one recorded. Chunks already sent are not rolled back:
        // this bounds how much further gets out of sync, it is not an
        // all-or-nothing guarantee.
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (String(text || "").trim() !== "ok" && root.errorText === "") {
                    root.errorText = "hyprctl refused a rule block; nothing further was applied"
                    root.pendingIndex = root.pendingChunks.length
                }
            }
        }
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
        root.setExpandedRow(-1)
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
        // The gate, third of three. See root.offersEditing -- and note that
        // launching from here while ~/.config/hypr/autostart.lua already
        // starts these programs is exactly the doubled session this plugin's
        // start marker exists to prevent.
        if (!root.offersEditing) return
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

    // --- the three ways a program gets into the list ----------------------
    //
    // All three change root.draft and nothing else. Saving happens on [Apply]
    // and nowhere near here: adding a program must not write the file, and it
    // must certainly not move windows across screens.
    //
    // NOTHING ARRIVES SWITCHED ON. A list the user has only just been handed
    // must not open programs by itself at the next login, so every route
    // creates disabled entries and the user turns on what they meant.
    //
    // The decisions all sit in Model.js -- the free id, the pattern, the
    // command, the whole imported configuration -- because a decision in this
    // file is a decision no suite in this project can execute.

    // Both flows read the same list through the same Process, so each entry
    // point disarms the other's flag: pressing [+ Add] while an import was
    // waiting for that answer must not import. The alternative -- a requester
    // id on the Process -- buys nothing here, because the two requests want
    // the identical answer and only differ in what is done with it.
    function startAppsRead() {
        root.errorText = ""
        root.appsPending = true
        root.appsTruncated = false
        root.appsUnparseable = false
        root.appsProblemText = ""
        appsProc.command = run.tool("omarchy-autostart-apps")
        appsProc.running = true
    }

    // [+ Add] -- pick from the installed .desktop entries.
    function openAdd() {
        root.importPending = false
        root.addOpen = true
        root.startAppsRead()
    }

    function closeAdd() {
        root.addOpen = false
    }

    function addFromApp(app) {
        var next = root.draftCopy()
        var programs = next.programs || []
        programs.push(Model.programFromApp(app, programs))
        next.programs = programs
        root.addOpen = false
        root.commitDraft(next)
    }

    // One Process for both flows that need the application list: they ask the
    // same question of the same script, and the answer serves whichever asked.
    Process {
        id: appsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.appsPending = false
                try {
                    root.apps = JSON.parse(String(text || "[]"))
                    root.appsUnparseable = false
                }
                catch (e) {
                    // NOT silent, and no longer guessing which of the two
                    // things happened: the stderr collector below carries
                    // runnerOut's truncation marker, and reportAppsProblem
                    // words the two cases differently. An empty picker with no
                    // explanation is the dead end this exists to prevent.
                    root.apps = []
                    root.appsUnparseable = true
                }
                root.reportAppsProblem()
                // The import waits for THIS, not for onExited: it needs
                // root.apps, and this is where root.apps arrives. Which of the
                // two signals Quickshell emits first is not something any file
                // in this project can be executed to find out, so the import
                // is not built on an ordering nobody measured.
                if (root.importPending) {
                    root.importPending = false
                    root.finishImport()
                }
            }
        }
        // runnerOut announces a truncated answer HERE and nowhere else -- it
        // catches the producer's SIGPIPE (141) and turns it into a success,
        // precisely because output past the cap is truncation and not failure.
        // Without this collector that announcement went to nobody, and a list
        // that was merely too long was reported as broken.
        //
        // Matched with indexOf on a fixed substring, not a regular expression:
        // the text is Runners.qml's own and this is a stream of bytes from a
        // process, so there is nothing to be gained by handing it to a regex
        // engine.
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (String(text || "").indexOf("producer output exceeded the cap") !== -1) {
                    root.appsTruncated = true
                }
                root.reportAppsProblem()
            }
        }
        onExited: function(exitCode, exitStatus) {
            // Cleared here as well as in onStreamFinished, because a process
            // that fails to START emits no stream signal at all -- Qt sends no
            // finished() for that case, which is the same gap Service.qml
            // needs its watchdog for. Whichever of the two arrives first, the
            // panel stops claiming it is still reading.
            root.appsPending = false
            // Live for the first time: through run.tool the script's own status
            // now survives the pipe (see Runners.qml), and 141 -- output past
            // the cap -- is already turned into 0 there, so a non-zero status
            // here is a real failure of the script.
            if (exitCode !== 0) {
                // The import is abandoned rather than left armed: a flag still
                // set would fire on whatever the NEXT reader of this Process
                // collects, which is the [+ Add] picker.
                root.importPending = false
                // A script that failed produced no usable list, which is the
                // unparseable case -- routed through the same one function so
                // the three sentences live in one place.
                root.appsUnparseable = true
                root.reportAppsProblem()
            }
        }
    }

    // The verdict on an application read, derived from both facts rather than
    // decided by whichever handler runs first: two StdioCollectors on one
    // Process emit in an order this project cannot execute a file to discover,
    // so neither handler is allowed to conclude alone. Called from both, it
    // reaches the same wording whichever arrives last.
    //
    // It only ever replaces its OWN earlier sentence (appsProblemText), never
    // an error some other flow put on screen.
    function reportAppsProblem() {
        // The wording, and the choice between the three cases, is
        // Model.appsProblem's -- the same rule as reasonText and envelopeText.
        var message = Model.appsProblem(root.appsUnparseable, root.appsTruncated)
        if (message === "") return
        if (root.errorText === "" || root.errorText === root.appsProblemText) {
            root.errorText = message
        }
        root.appsProblemText = message
    }

    // [From window] -- fill a program's class from a window that is open right
    // now. This is the route on which webapps and LM-Studio come out right
    // without the user having to know how either of them names itself.
    function pickClass(rowIndex, windowClass) {
        var next = root.draftCopy()
        var programs = next.programs || []
        if (rowIndex < 0 || rowIndex >= programs.length) return
        var pattern
        // A class picked from a window is not more trustworthy than one typed
        // in: it goes through Model.classLiteral, which escapes every
        // metacharacter and then puts the result through the same allowlist.
        // A refusal is shown rather than swallowed -- and it costs nothing,
        // because next is a copy and nothing has been written to the draft yet.
        try { pattern = Model.classLiteral(windowClass) }
        catch (e) {
            root.errorText = "That window class cannot be used: " + String(e.message)
            return
        }
        programs[rowIndex]["class"] = pattern
        next.programs = programs
        root.pickForRow = -1
        root.errorText = ""
        root.commitDraft(next)
    }

    // [Import current session] -- the answer to an empty panel on first run.
    // The condition is Model.isEmptyConfig, not a comparison written here: it
    // is the guard on a destructive action (the import replaces the whole
    // configuration, workspace table included), and a guard in QML is a guard
    // no suite in this project can execute.
    function importSession() {
        if (!Model.isEmptyConfig(root.draft)) return
        root.importPending = true
        root.startAppsRead()
    }

    // Reached from appsProc once the application list is in. Nothing is
    // written: the button offers a list to review, not a finished
    // configuration, so this ends in the draft with [Apply] still to press.
    // The guard is repeated because the draft can have changed while the
    // script ran.
    function finishImport() {
        if (!Model.isEmptyConfig(root.draft)) return
        var next = Model.importFromSession(root.openWindows, root.workspacesNow, root.apps)
        root.setExpandedRow(-1)
        root.commitDraft(next)
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

    // The bound comes from Model, never from a literal here: this file's own
    // header says every derivation lives in Model.js, and a second copy of
    // MAX_WORKSPACES is exactly the kind that drifts silently -- the picker
    // would offer a number validate() then rejects, or stop offering one it
    // accepts. Reachability of a top-level `var` through the JS namespace is
    // asserted in test/harness.qml, in the same engine that runs this file.
    function workspaceOptions() {
        var out = []
        for (var i = 1; i <= Model.MAX_WORKSPACES; i++)
            out.push({ value: String(i), label: String(i) })
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
    readonly property string glyphDisabled: "\uf068"     // nf-fa-minus

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

            // The shipped idiom (audio/Panel.qml:694, monitor/Panel.qml:516):
            // a ScrollView's inner Flickable stays interactive even when the
            // content fits, so a drag or a wheel over a list that does not
            // scroll still grabs the gesture instead of leaving it to the
            // content. Bound rather than assigned because contentItem is
            // created by the ScrollView, not by this file.
            Binding {
                target: scrollArea.contentItem
                property: "interactive"
                value: body.implicitHeight > scrollArea.height
            }

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

                    // --- what was READ from the user's Hyprland files -----------------
                    //
                    // Three sections in the order of the files, every entry with its
                    // 1-based line number, and a non-editable entry visibly marked as
                    // one. Nothing here is a control: this half writes nothing, and the
                    // line at the top says so in words rather than leaving the user to
                    // discover it by clicking.
                    //
                    // NO WORDING AND NO DERIVATION IN THIS FILE. The header sentence is
                    // Model.hyprHeaderText, each entry's line is Model.hyprEntryText, and
                    // each refusal is Model.hyprReasonText -- all three in the file the
                    // QML suite can execute, for the same reason reasonText and
                    // envelopeText live there.
                    Text {
                        textFormat: Text.PlainText
                        width: body.width
                        text: Model.hyprHeaderText(root.hyprSections)
                        color: root.fg
                        opacity: 0.85
                        font.family: root.fontFam
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        textFormat: Text.PlainText
                        width: body.width
                        visible: root.hyprError !== ""
                        text: root.hyprError
                        color: root.warn
                        font.family: root.fontFam
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        // An int model, the same rule the two editable lists follow: an
                        // array model makes a Repeater destroy and rebuild every delegate
                        // on each assignment. Nothing in these rows holds a text cursor
                        // to lose, but the rule is cheap and the next change to this
                        // section might.
                        model: root.hyprSections.length

                        delegate: Column {
                            id: hyprSection
                            width: body.width
                            spacing: Style.spacing.xxs

                            readonly property var section:
                                root.hyprSections[index]
                                || ({ name: "", path: "", present: false,
                                      truncated: false, entries: [] })

                            PanelSectionHeader {
                                text: String(hyprSection.section.name).toUpperCase()
                                foreground: root.fg
                                fontFamily: root.fontFam
                                elide: Text.ElideRight
                                width: body.width
                            }

                            Text {
                                textFormat: Text.PlainText
                                width: body.width
                                visible: !hyprSection.section.present
                                         || hyprSection.section.truncated
                                         || (hyprSection.section.entries || []).length === 0
                                text: !hyprSection.section.present
                                      ? "Not found: " + String(hyprSection.section.path)
                                      : hyprSection.section.truncated
                                        ? "This file is larger than this panel reads; "
                                          + "what is shown is the beginning of it."
                                        : "No line in this file is one this panel recognises."
                                color: hyprSection.section.truncated ? root.warn : root.fg
                                opacity: 0.8
                                font.family: root.fontFam
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                            Repeater {
                                model: (hyprSection.section.entries || []).length

                                delegate: Column {
                                    id: hyprEntryRow
                                    width: body.width
                                    spacing: 0

                                    readonly property var entry:
                                        (hyprSection.section.entries || [])[index]
                                        || ({ line: 0, raw: "", editable: false, reason: "" })

                                    Text {
                                        textFormat: Text.PlainText
                                        width: body.width
                                        text: Model.hyprEntryText(hyprEntryRow.entry)
                                        color: root.fg
                                        opacity: hyprEntryRow.entry.editable ? 1.0 : 0.75
                                        font.family: root.fontFam
                                        font.pixelSize: Style.font.body
                                        wrapMode: Text.WrapAnywhere
                                    }

                                    // The mark, and the reason in English. A code is
                                    // never shown raw -- Model.hyprReasonText is the one
                                    // place these become sentences, and the harness
                                    // proves every code in Model.hyprReasons() has one.
                                    Text {
                                        textFormat: Text.PlainText
                                        width: body.width
                                        visible: !hyprEntryRow.entry.editable
                                        text: "not editable \u2014 "
                                              + Model.hyprReasonText(hyprEntryRow.entry.reason)
                                        color: root.warn
                                        font.family: root.fontFam
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }
                        }
                    }

                    PanelSeparator {
                        width: body.width
                        foreground: root.fg
                    }

                    // --- programs -----------------------------------------------------
                    // Everything from here to the footer is the OLD half, hidden while
                    // root.offersEditing is false. Hidden, not deleted -- see the
                    // cutover comment in Model.js.
                    Row {
                        width: body.width
                        visible: root.offersEditing
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

                    // --- the [+ Add] picker -------------------------------------------
                    // A plain list. Filtering it would be one more derivation,
                    // and a derivation belongs in Model.js where a suite can
                    // reach it; the list is bounded by the script (2000 files)
                    // and scrolls with the rest of the panel.
                    Column {
                        id: appPicker
                        width: body.width
                        visible: root.offersEditing && root.addOpen
                        spacing: Style.spacing.xs

                        Row {
                            width: appPicker.width
                            spacing: Style.spacing.controlGap

                            Text {
                                textFormat: Text.PlainText
                                text: root.appsPending ? "Reading the installed applications..."
                                                       : "Pick an installed application"
                                color: root.fg
                                font.family: root.fontFam
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                                width: Math.max(Style.space(60),
                                                appPicker.width - cancelAddButton.implicitWidth
                                                - parent.spacing)
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Button {
                                id: cancelAddButton
                                text: "Cancel"
                                foreground: root.fg
                                fontFamily: root.fontFam
                                bordered: true
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: root.closeAdd()
                            }
                        }

                        // Only once the answer is actually in: "no applications"
                        // and "not read yet" are different things, and the first
                        // one is a claim this panel should not make while a
                        // process is still running.
                        Text {
                            textFormat: Text.PlainText
                            width: appPicker.width
                            visible: !root.appsPending && root.apps.length === 0
                            text: "No installed applications were found."
                            color: root.fg
                            opacity: 0.7
                            font.family: root.fontFam
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            // A JavaScript array model here, unlike the program
                            // rows: these delegates hold no text cursor, so the
                            // rebuild on every change costs nothing at all.
                            model: root.apps

                            delegate: Row {
                                id: appEntry
                                required property var modelData
                                width: appPicker.width
                                spacing: Style.spacing.controlGap

                                Button {
                                    text: String(appEntry.modelData.name || "(no name)")
                                    foreground: root.fg
                                    fontFamily: root.fontFam
                                    leftAlign: true
                                    width: Math.max(Style.space(80),
                                                    appPicker.width - Style.space(180))
                                    anchors.verticalCenter: parent.verticalCenter
                                    onClicked: root.addFromApp(appEntry.modelData)
                                }

                                // What the entry declares as its window class,
                                // shown because it is what decides whether the
                                // new row can be placed at all: an application
                                // without one arrives with an empty class and
                                // has to be finished with [From window].
                                Text {
                                    textFormat: Text.PlainText
                                    text: String(appEntry.modelData.wmclass || "no window class")
                                    color: root.fg
                                    opacity: 0.6
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                    width: Style.space(170)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        PanelSeparator {
                            width: appPicker.width
                            foreground: root.fg
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
                        // An int model, see programRowCount. Zero rows while the old
                        // half is disconnected: a Repeater's own `visible` does not
                        // reach its delegates -- they are parented to the Repeater's
                        // PARENT -- so hiding this list means building none of it.
                        model: root.offersEditing ? root.programRowCount : 0

                        delegate: Column {
                            id: programRow
                            width: body.width
                            spacing: Style.spacing.xs

                            // The outer index, captured under a name of its own:
                            // a nested Repeater's delegate has an `index` of its
                            // own that shadows this one (see the window picker
                            // below).
                            readonly property int rowIndex: index

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

                                // THREE states, not two dimmed into each other.
                                // Reading left to right:
                                //   disabled          a dash, muted -- this entry
                                //                     will not be started, so
                                //                     whether a window matches it
                                //                     is not a claim being made
                                //   enabled, matched  a filled circle in the
                                //                     foreground colour
                                //   enabled, no match a hollow circle in the
                                //                     warning colour -- the only
                                //                     report a mistyped command
                                //                     ever gets
                                // Dimming the RUNNING glyph for a disabled entry
                                // (which is what this did) made a program that is
                                // switched off look like one that is up, only
                                // fainter.
                                Text {
                                    textFormat: Text.PlainText
                                    readonly property bool isOn: programRow.program.enabled === true
                                    text: !isOn ? root.glyphDisabled
                                          : (programRow.isRunning ? root.glyphRunning
                                                                  : root.glyphNotRunning)
                                    color: !isOn ? root.fg
                                           : (programRow.isRunning ? root.fg : root.warn)
                                    opacity: isOn ? 1.0 : 0.45
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
                                    onClicked: root.setExpandedRow(programRow.isExpanded ? -1 : index)
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
                                    onClicked: root.setExpandedRow(programRow.isExpanded ? -1 : index)
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
                                    // onTextEdited, NOT onTextChanged. Measured, offscreen
                                    // qml, three collapsed rows and NO user action:
                                    //   onTextChanged -> 3 write-backs, 3 markDirty,
                                    //                    3 Qt binding-loop warnings,
                                    //                    dirtyCount=1
                                    //   onTextEdited  -> 0, 0, 0, dirtyCount=0
                                    // `text:` is bound to a value inside the draft and the
                                    // handler writes back into it, so onTextChanged closes
                                    // the loop on itself: a stored value that is not a
                                    // string round-trips through String() to a different
                                    // one, and a user who opens the panel and touches
                                    // nothing is told they have unsaved changes.
                                    // onTextEdited fires only on real user input and is
                                    // identical while typing.
                                    onTextEdited: root.setProgramField(index, "command", text)
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
                                        onTextEdited: root.setProgramField(index, "class", text)
                                        onActiveFocusChanged: root.noteEditorFocus(activeFocus)
                                    }

                                    Button {
                                        id: fromWindowButton
                                        text: "From window"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: {
                                            root.pickForRow = (root.pickForRow === programRow.rowIndex)
                                                              ? -1 : programRow.rowIndex
                                            // The list has to be current: a program
                                            // started since the panel opened must be
                                            // pickable, or the one route that gets a
                                            // webapp's class right is closed for it.
                                            root.refreshWindows()
                                        }
                                    }
                                }

                                // --- [From window]'s own list -------------
                                // The windows that are open right now, class
                                // first because the class is what is being
                                // picked; the title is there to tell two
                                // windows of one application apart.
                                Column {
                                    id: windowPicker
                                    width: programRow.width
                                    visible: root.pickForRow === programRow.rowIndex
                                    spacing: Style.spacing.xs

                                    Text {
                                        textFormat: Text.PlainText
                                        width: windowPicker.width
                                        text: root.openWindows.length === 0
                                              ? "No open windows were found."
                                              : "Pick the window this program opens"
                                        color: root.fg
                                        opacity: 0.7
                                        font.family: root.fontFam
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }

                                    Repeater {
                                        model: root.openWindows

                                        delegate: Row {
                                            id: windowEntry
                                            required property var modelData
                                            width: windowPicker.width
                                            spacing: Style.spacing.controlGap

                                            Button {
                                                text: String(windowEntry.modelData["class"]
                                                             || "(no window class)")
                                                // A window with no class cannot be
                                                // picked: the pattern for it would be
                                                // "^()$", which identifies no window in
                                                // particular. Model.classLiteral refuses
                                                // it at the source; this stops the user
                                                // walking into that refusal by making
                                                // the row visibly unavailable instead.
                                                enabled: String(windowEntry.modelData["class"]
                                                                || "") !== ""
                                                opacity: enabled ? 1.0 : 0.4
                                                foreground: root.fg
                                                fontFamily: root.fontFam
                                                leftAlign: true
                                                width: Math.max(Style.space(80),
                                                                windowPicker.width - Style.space(180))
                                                anchors.verticalCenter: parent.verticalCenter
                                                // programRow.rowIndex, NEVER `index`.
                                                // Inside this delegate `index` is THIS
                                                // Repeater's index over the window list
                                                // and shadows the program row's own --
                                                // measured offscreen on a nested
                                                // Repeater of exactly this shape:
                                                //   outer/inner 2/0 -> index reads 0
                                                //   it differs from the row index in
                                                //   4 of 6 delegates
                                                // Written as `index` it looks right and
                                                // silently picks the class for whichever
                                                // row happens to sit at that position.
                                                onClicked: root.pickClass(programRow.rowIndex,
                                                                          windowEntry.modelData["class"])
                                            }

                                            Text {
                                                textFormat: Text.PlainText
                                                text: String(windowEntry.modelData.title || "")
                                                color: root.fg
                                                opacity: 0.6
                                                font.family: root.fontFam
                                                font.pixelSize: Style.font.caption
                                                elide: Text.ElideRight
                                                width: Style.space(170)
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
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
                        visible: root.offersEditing
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
                        // refuses has to stay on screen to be corrected. Zero of them
                        // while the old half is disconnected, for the same reason as the
                        // program list above.
                        model: root.offersEditing ? root.workspaceRowCount : 0

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
                        visible: root.offersEditing
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
                        visible: root.offersEditing
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
                        visible: root.offersEditing && root.missing.length > 0
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
                        visible: root.offersEditing && Model.isEmptyConfig(root.draft)
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
                        visible: root.offersEditing && root.errorText !== ""
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
                        visible: root.offersEditing && root.rejected.length > 0

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
                        visible: root.offersEditing && root.blocked.length > 0

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
                        visible: root.offersEditing
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
