import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The editing surface for ~/.config/hypr/autostart.lua, and nothing else.
// One list: the entries of that file, each with its line number, each
// editable one with a change and a remove control, and one add field fed
// either from the installed applications or from a program that is running
// right now.
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
// NO DECISION LIVES HERE. Everything this plugin decides -- what an entry of
// autostart.lua means, whether a command may be written, what the new file
// content is, which suggestions an open window has and in what order, and the
// wording of every refusal -- is in Model.js, where the QML suite can reach
// it. This file holds state, widgets, and the plumbing between them.
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

    // ONE number, because there is one thing to count: the entries of
    // autostart.lua. The second number counted the placements of the removed
    // half, and a bar tooltip still saying "0 placements" would be a
    // statement about a feature that no longer exists.
    signal counted(int programs)

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
        // The change editor is closed through its own setter, which hands
        // focus back to the key catcher BEFORE the field is hidden -- a
        // TextField hidden by a `visible:` binding clears no focus and fires
        // no activeFocusChanged, and this project has measured what that
        // costs: the counter sticks and Escape is swallowed for the rest of
        // the open session. The explicit zero stays as a belt, for a counter
        // stranded by some future path that forgets the setter.
        root.autostartCloseEditor()
        root.editorsFocused = 0
        // A closed panel offers nothing: neither picker comes back open on the
        // next click with a stale list behind it.
        root.autostartAddOpen = false
        root.autostartFromWindowOpen = false
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

    // Every Process in this file, disarmed. Four now, and the list is the
    // whole list: a Process still running past the destruction of its owner is
    // what this line exists to prevent.
    Component.onDestruction: {
        windowsProc.running = false
        appsProc.running = false
        hyprProc.running = false
        autostartWriteProc.running = false
    }

    // THE CUTOVER, and this panel's ONE named place for it. The switch is

    // --- state ------------------------------------------------------------
    //
    // There is no draft and no saved copy here any more, and that is a
    // different design rather than a smaller one: a change to autostart.lua is
    // ONE line of ONE file, written the moment it is confirmed, so there is
    // nothing to hold pending and nothing to revert.
    property string errorText: ""
    property var openWindows: []



    // The installed applications. Read for the add field's own picker and for
    // the .desktop half of a running window's suggestions -- which is why the
    // running-programs list asks for them too. Empty until something does.
    property var apps: []
    property bool appsPending: false

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
                // The bar tooltip's two numbers, DERIVED IN Model.js. This
                // loop used to classify the sections here by comparing
                // section.name, which finding 1 of the task 18 review named
                // for what it was: a derivation in the one file no suite can
                // execute, beside two counters in Model.js that already did
                // the job and were unused.
                root.counted(Model.hyprProgramCount(root.hyprSections))
            }
        }
    }

    // --- WRITING autostart.lua --------------------------------------------
    //
    // THE ONE FILE THIS PLUGIN WRITES, and it runs at every login. The new
    // content is NOT built here: Model.autostartApply() is a pure function
    // (old text plus one operation gives new text) and every surgery case is
    // a byte-exact assertion in test/harness.qml. This block only carries the
    // operation to it and the result to bin/omarchy-autostart-hypr-write,
    // which owns the freshness check, the backup, the luac5.1 gate and the
    // atomic rename.
    //
    // Nothing is started, nothing is reloaded, no `hyprctl` of any kind. The
    // sentence that says so is Model.autostartWrittenText().
    property string autostartMessage: ""
    property string autostartError: ""
    property bool autostartBusy: false

    // The add field, and the row currently open for a change. -1 is none.
    property string autostartNewCommand: ""
    property int autostartEditLine: -1
    property string autostartEditCommand: ""
    property bool autostartAddOpen: false

    // "Add from a running program": the window list, and which window's
    // suggestions are unfolded. BY ROW rather than by class, and here that is
    // not a precaution but a measurement: his three nimbus windows are three
    // windows with three different classes but one command line, and two
    // Termpane windows share a class outright. Keyed by class, unfolding one
    // would unfold the other.
    // THE ONE READ of the running-programs flag. Everything that shows or
    // reaches that feature goes through this property, so bringing it back is
    // one edit in Model.js and nothing here.
    readonly property bool offersRunningPrograms: Model.RUNNING_PROGRAMS_ENABLED

    property bool autostartFromWindowOpen: false
    property int autostartWindowRow: -1

    readonly property var autostartSection:
        Model.hyprSectionNamed(root.hyprSections, "autostart.lua")
    readonly property bool autostartWritable:
        Model.hyprSectionIsWritable(root.autostartSection)

    // The entries autostart.lua holds right now, as the reader returned them.
    // They are what the already-present warnings are compared against, so
    // this must be the CURRENT read and not a remembered list.
    readonly property var autostartEntriesNow:
        (root.autostartSection && root.autostartSection.entries) || []

    function autostartWrite(op) {
        root.autostartMessage = ""
        root.autostartError = ""
        if (root.autostartBusy) return
        var section = root.autostartSection
        if (!Model.hyprSectionIsWritable(section)) {
            root.autostartError = Model.hyprSectionNoteText(section)
                                  || "autostart.lua cannot be edited right now."
            return
        }
        // The pure function decides. A refusal here never reaches the disk and
        // never produces a candidate -- see the assertions on refusal.text.
        var result = Model.autostartApply(section.content, op)
        if (!result.ok) {
            root.autostartError = Model.autostartWriteReasonText(result.error)
            return
        }
        root.autostartBusy = true
        // The same route the configuration writer uses: the content goes in on
        // stdin, shell-quoted once, so no length of it can be mistaken for an
        // argument. `printf '%s'` and not `echo`, because the content ends in
        // a newline that is part of the file.
        autostartWriteProc.command = run.runnerOut(
            "printf '%s' " + Model.shellQuote(result.text) + " | "
            + Model.shellQuote(run.binDir + "omarchy-autostart-hypr-write")
            + " write --expect-mtime " + Number(section.mtime))
        autostartWriteProc.running = true
    }

    // The operation object handed to Model.autostartApply.
    //
    // ITS COMMAND FIELD IS ASSIGNED BY SUBSCRIPT, not written as a key, and
    // that is not a style choice: test/qml-structure.sh check 5b requires
    // every `command:` occurrence in a qml file to be a call on this file's
    // own Runners instance -- which is what keeps a hand-built argv out of a
    // Process -- and an object literal with a `command:` key here would have
    // to loosen it. The rule it follows: rename or reshape the local, never
    // widen a structural check to fit it. (This cited a local in Model.js's
    // hyprEntryText as the precedent; that local went with the line-number
    // prefix, and a citation of code that no longer exists is worse than no
    // citation.)
    function autostartOperation(action, line, commandLine) {
        var op = { action: action }
        if (line !== undefined) op.line = line
        if (commandLine !== undefined) op["command"] = commandLine
        return op
    }

    function autostartAdd() {
        root.autostartWrite(
            root.autostartOperation("add", undefined, root.autostartNewCommand))
    }

    // --- add from a running program ----------------------------------------
    //
    // Opening the list needs BOTH reads: the open windows, because a program
    // started since the panel opened must be offerable, and the installed
    // applications, because the .desktop-by-binary route is the one that turns
    // his Webmail window into `nimbus --app=https://mail.example.com/mail/`
    // instead of a browser command line that is wrong for it. Without the
    // second read every window would offer nothing but its /proc line -- which
    // is exactly the automatic mapping this task exists not to be.
    function autostartFromWindowToggle() {
        // THE ROUTE, CLOSED FIRST. Hiding the button is not enough on its own
        // -- a hidden control is not a closed route, and this plugin has
        // already shipped a gate that read as armed and was inert. The guard
        // is before every read below, so nothing is spawned for a feature
        // nobody can see: refreshWindows() is this function's own call and has
        // no other caller.
        if (!root.offersRunningPrograms) return
        root.autostartMessage = ""
        root.autostartError = ""
        root.autostartFromWindowOpen = !root.autostartFromWindowOpen
        root.autostartWindowRow = -1
        if (!root.autostartFromWindowOpen) return
        root.autostartAddOpen = false
        root.refreshWindows()
        root.startAppsRead()
    }

    // The suggestions for one window. A pure Model call: the panel decides
    // nothing about which command a window means, it only shows what the
    // model ranked and hands back whatever the user picks.
    function autostartCandidatesFor(window) {
        return Model.autostartCandidatesForWindow(window, root.apps,
                                                  root.autostartEntriesNow)
    }

    // Is this window's suggestion list unfolded, and the toggle for it.
    //
    // FUNCTIONS RATHER THAN AN INLINE COMPARISON, and the reason is the
    // nested-Repeater trap this project has already measured: inside the
    // suggestions delegate `index` is the SUGGESTION's index and shadows the
    // window's. Written inline the comparison spans two lines at that
    // indentation, and a line-based check cannot see the row name and the
    // bare `index` together. Here both sit on one line, where a check can.
    function autostartWindowUnfolded(windowIndex) {
        return root.autostartWindowRow === windowIndex
    }

    function autostartWindowUnfold(windowIndex) {
        root.autostartWindowRow = (root.autostartWindowRow === windowIndex) ? -1 : windowIndex
    }

    // Picking a suggestion FILLS THE FIELD. It does not write: the line that
    // goes into a file which runs at every login is one the user has read
    // first, and that is also the answer to a command line that might carry a
    // secret -- he decides whether it is written, not the plugin.
    function autostartUseCandidate(command) {
        root.autostartNewCommand = String(command || "")
        root.autostartFromWindowOpen = false
        root.autostartWindowRow = -1
    }

    function autostartRemove(line) {
        root.autostartWrite(root.autostartOperation("remove", line, undefined))
    }

    function autostartChange() {
        root.autostartWrite(root.autostartOperation("change", root.autostartEditLine,
                                                    root.autostartEditCommand))
    }

    // Open the inline change editor on one row, closing whichever was open.
    // The command it starts from is the one the reader took OUT of the line,
    // not the raw line: what the user edits is what he sees.
    // FOCUS FIRST, THEN HIDE, and this is not bookkeeping bolted on beside the
    // real thing -- it is what the real thing was waiting for.
    //
    // The change editor is shown by a `visible:` binding on
    // root.autostartEditLine. Setting that back to -1 with the field focused
    // hides the field WITHOUT clearing focus and WITHOUT firing
    // activeFocusChanged, so root.editorsFocused sticks at 1: Escape is
    // swallowed for the rest of the open session and the now-invisible field
    // stays the window's activeFocusItem. Measured in this project already,
    // offscreen, on a stub of exactly this shape:
    //   hidden as it was  -> editorsFocused=1 blocked=true  activeFocusItem=field
    //   hidden via setter -> editorsFocused=0 blocked=false activeFocusItem=keyCatcher
    // The remedy is to move focus while the field still EXISTS.
    //
    // Every route that closes the editor goes through this, which is why there
    // is no bare `autostartEditLine = -1` anywhere else in this file.
    function autostartCloseEditor() {
        if (keyCatcher) keyCatcher.forceActiveFocus()
        root.autostartEditLine = -1
        root.autostartEditCommand = ""
    }

    function autostartEdit(entry) {
        root.autostartMessage = ""
        root.autostartError = ""
        if (root.autostartEditLine === entry.line) {
            root.autostartCloseEditor()
            return
        }
        root.autostartEditLine = entry.line
        root.autostartEditCommand = String(entry.command || "")
    }

    Process {
        id: autostartWriteProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.autostartBusy = false
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) {
                    root.autostartError = "the autostart writer gave an unreadable answer"
                    return
                }
                if (!envelope.ok) {
                    root.autostartError = Model.envelopeText(envelope.error, envelope.detail)
                    return
                }
                root.autostartMessage = Model.autostartWrittenText()
                root.autostartNewCommand = ""
                root.autostartAddOpen = false
                root.autostartCloseEditor()
                // Read the file again rather than patching the list in place:
                // the mtime moved, and every later operation's freshness check
                // is against the one on disk now.
                root.readHypr()
            }
        }
    }

    // --- load -------------------------------------------------------------
    function reload() {
        root.errorText = ""
        // The editor is keyed by LINE NUMBER, and a re-read can put a different
        // editable entry on that line. autostartApply re-parses and would refuse
        // a line that no longer holds an editable entry, but it cannot refuse a
        // line that now holds someone else's -- so the editor closes here rather
        // than being carried across a read.
        root.autostartCloseEditor()
        root.readHypr()
    }


    // --- the windows that are open right now -------------------------------
    // Re-read every time the running-programs list is opened, and not once at
    // panel open: a program started since then must be offerable, or the one
    // route that gets a webapp's command right is closed for it.
    function refreshWindows() {
        windowsProc.command = run.tool("omarchy-autostart-windows")
        windowsProc.running = true
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

    // --- the installed applications ----------------------------------------
    //
    // Two callers, one question: the add field's application picker, and the
    // running-programs list, whose .desktop suggestions cannot be derived
    // without this answer.
    function startAppsRead() {
        root.errorText = ""
        root.appsPending = true
        root.appsTruncated = false
        root.appsUnparseable = false
        root.appsProblemText = ""
        appsProc.command = run.tool("omarchy-autostart-apps")
        appsProc.running = true
    }

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
            // that fails to START emits no stream signal at all -- Qt sends
            // no finished() for that case. Whichever of the two arrives
            // first, the panel stops claiming it is still reading.
            root.appsPending = false
            // Live for the first time: through run.tool the script's own status
            // now survives the pipe (see Runners.qml), and 141 -- output past
            // the cap -- is already turned into 0 there, so a non-zero status
            // here is a real failure of the script.
            if (exitCode !== 0) {
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

    // --- layout -----------------------------------------------------------
    readonly property color fg: Color.popups.text
    readonly property color warn: Color.urgent
    readonly property string fontFam: Style.font.family

    // How many text fields currently hold focus. PanelKeyCatcher below runs
    // with Keys.priority: Keys.BeforeItem, so it takes keys even when a
    // descendant has focus -- typing "x" in the Command field would otherwise
    // fire deleteRequested and "j" would never reach the field at all. The
    // platform's own instruction for this is `blocked: editor.activeFocus`,
    // which assumes ONE editor; this panel has the add field and one change
    // field per entry row, created and destroyed by a Repeater, so a count is
    // used instead of a reference.
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
                        text: "Autostart Editor"
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

                    // THE OTHER ERROR LINE, and it is here because removing
                    // the old half nearly took it with it: root.errorText was
                    // shown only in a footer gated on the cutover flag, so the
                    // application-list wording (Model.appsProblem, reached
                    // through reportAppsProblem) would have had nowhere on
                    // screen to appear -- an empty picker with no explanation,
                    // which is exactly the dead end that wording exists for.
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

                            // The note under the header. THE SENTENCES ARE IN
                            // Model.hyprSectionNoteText -- finding 2 of the task 18
                            // review found all three of them written inline right
                            // here, sixty lines under the comment forbidding it, and
                            // therefore unreachable by the harness. The empty string
                            // is what decides whether the row appears at all.
                            Text {
                                id: hyprSectionNote
                                textFormat: Text.PlainText
                                width: body.width
                                text: Model.hyprSectionNoteText(hyprSection.section)
                                visible: hyprSectionNote.text !== ""
                                color: hyprSection.section.truncated ? root.warn : root.fg
                                opacity: 0.8
                                font.family: root.fontFam
                                font.pixelSize: Style.font.caption
                                wrapMode: Text.WordWrap
                            }

                            // How many of this section's entries can be edited, and
                            // -- when any cannot -- that they are left alone. Only
                            // autostart.lua has anything to say here; the other two
                            // sections get "" and the row does not appear.
                            Text {
                                id: hyprSectionEditableNote
                                textFormat: Text.PlainText
                                width: body.width
                                text: Model.hyprSectionIsWritable(hyprSection.section)
                                      ? Model.hyprAutostartNoteText(root.hyprSections) : ""
                                visible: hyprSectionEditableNote.text !== ""
                                color: root.fg
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

                                    // The entry line, and -- only for an editable
                                    // entry of the ONE writable section -- its two
                                    // controls. A non-editable entry gets no button
                                    // at all: the plugin does not offer an operation
                                    // it refuses to perform, and the refusal is said
                                    // in words below rather than discovered by a
                                    // click that does nothing.
                                    Row {
                                        width: body.width
                                        spacing: Style.spacing.controlGap

                                        readonly property bool controlled:
                                            root.autostartWritable
                                            && hyprEntryRow.entry.editable === true
                                            && hyprEntryRow.entry.kind === "autostart"

                                        Text {
                                            textFormat: Text.PlainText
                                            width: parent.controlled
                                                   ? Math.max(Style.space(60),
                                                              body.width
                                                              - changeEntryButton.implicitWidth
                                                              - removeEntryButton.implicitWidth
                                                              - 2 * parent.spacing)
                                                   : body.width
                                            text: Model.hyprEntryText(hyprEntryRow.entry)
                                            color: root.fg
                                            opacity: hyprEntryRow.entry.editable ? 1.0 : 0.75
                                            font.family: root.fontFam
                                            font.pixelSize: Style.font.body
                                            wrapMode: Text.WrapAnywhere
                                        }

                                        Button {
                                            id: changeEntryButton
                                            visible: parent.controlled
                                            text: root.autostartEditLine === hyprEntryRow.entry.line
                                                  ? "Cancel" : "Change"
                                            foreground: root.fg
                                            fontFamily: root.fontFam
                                            bordered: true
                                            enabled: !root.autostartBusy
                                            anchors.verticalCenter: parent.verticalCenter
                                            onClicked: root.autostartEdit(hyprEntryRow.entry)
                                        }

                                        Button {
                                            id: removeEntryButton
                                            visible: parent.controlled
                                            text: "Remove"
                                            foreground: root.fg
                                            fontFamily: root.fontFam
                                            bordered: true
                                            enabled: !root.autostartBusy
                                            anchors.verticalCenter: parent.verticalCenter
                                            onClicked: root.autostartRemove(hyprEntryRow.entry.line)
                                        }
                                    }

                                    // The inline change editor, at the row. One at a
                                    // time, and the field starts from the command the
                                    // reader took out of the line.
                                    Row {
                                        width: body.width
                                        spacing: Style.spacing.controlGap
                                        visible: root.autostartWritable
                                                 && root.autostartEditLine === hyprEntryRow.entry.line

                                        TextField {
                                            width: Math.max(Style.space(80),
                                                            body.width
                                                            - saveEntryButton.implicitWidth
                                                            - parent.spacing)
                                            placeholderText: "Command"
                                            text: root.autostartEditCommand
                                            foreground: root.fg
                                            // onTextEdited, not onTextChanged: `text` is
                                            // bound to the property the handler writes
                                            // back into, and onTextChanged would close
                                            // that loop on itself. The same measurement
                                            // as the program rows below.
                                            onTextEdited: root.autostartEditCommand = text
                                            onActiveFocusChanged: root.noteEditorFocus(activeFocus)
                                        }

                                        Button {
                                            id: saveEntryButton
                                            text: "Save"
                                            foreground: root.fg
                                            fontFamily: root.fontFam
                                            bordered: true
                                            enabled: !root.autostartBusy
                                            anchors.verticalCenter: parent.verticalCenter
                                            onClicked: root.autostartChange()
                                        }
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

                            // --- ADD, and it is the whole write surface for this
                            // --- section besides the two buttons on each row -----
                            //
                            // Only for the ONE writable section, only while the read
                            // that produced it is current. A new line goes to the END
                            // of the file in the style the file already uses; nothing
                            // is sorted into one of the user's German comment
                            // sections, because guessing which one a program belongs
                            // under is exactly the surprise this design avoids.
                            Column {
                                id: autostartAdd
                                width: body.width
                                spacing: Style.spacing.xs
                                visible: Model.hyprSectionIsWritable(hyprSection.section)

                                Row {
                                    width: autostartAdd.width
                                    spacing: Style.spacing.controlGap

                                    TextField {
                                        // The running-programs button's width
                                        // and its gap come off only while it
                                        // is SHOWN: a Row lays out no
                                        // invisible child, but implicitWidth
                                        // still reports one, so subtracting it
                                        // unconditionally would leave the
                                        // field needlessly narrow with the
                                        // feature off -- and bringing the
                                        // feature back needs no edit here.
                                        width: Math.max(Style.space(80),
                                                        autostartAdd.width
                                                        - autostartAddButton.implicitWidth
                                                        - autostartPickButton.implicitWidth
                                                        - (autostartWindowButton.visible
                                                           ? autostartWindowButton.implicitWidth
                                                             + parent.spacing : 0)
                                                        - 2 * parent.spacing)
                                        placeholderText: "Command to add"
                                        text: root.autostartNewCommand
                                        foreground: root.fg
                                        onTextEdited: root.autostartNewCommand = text
                                        onActiveFocusChanged: root.noteEditorFocus(activeFocus)
                                    }

                                    Button {
                                        id: autostartPickButton
                                        text: root.autostartAddOpen ? "Close list" : "Applications"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: {
                                            root.autostartAddOpen = !root.autostartAddOpen
                                            if (root.autostartAddOpen) {
                                                // The two lists share the field and the
                                                // application read; only one is open.
                                                root.autostartFromWindowOpen = false
                                                root.startAppsRead()
                                            }
                                        }
                                    }

                                    Button {
                                        id: autostartWindowButton
                                        visible: root.offersRunningPrograms
                                        text: root.autostartFromWindowOpen
                                              ? "Close windows" : "Running programs"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: root.autostartFromWindowToggle()
                                    }

                                    Button {
                                        id: autostartAddButton
                                        text: "Add"
                                        foreground: root.fg
                                        fontFamily: root.fontFam
                                        bordered: true
                                        enabled: !root.autostartBusy
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: root.autostartAdd()
                                    }
                                }

                                // The installed applications, the same list and the
                                // same Process the old half's picker used. Picking one
                                // FILLS THE FIELD rather than writing: the command it
                                // derives from Exec= is a guess worth showing to the
                                // user before it lands in a file that runs at login.
                                Text {
                                    textFormat: Text.PlainText
                                    width: autostartAdd.width
                                    visible: root.autostartAddOpen
                                    text: root.appsPending
                                          ? "Reading the installed applications..."
                                          : "Pick one to fill the field, then press Add"
                                    color: root.fg
                                    opacity: 0.7
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    width: autostartAdd.width
                                    visible: root.autostartAddOpen && !root.appsPending
                                             && root.apps.length === 0
                                    text: "No installed applications were found."
                                    color: root.fg
                                    opacity: 0.7
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                }

                                Repeater {
                                    model: root.autostartAddOpen ? root.apps : []

                                    delegate: Row {
                                        id: autostartAppEntry
                                        required property var modelData
                                        width: autostartAdd.width
                                        spacing: Style.spacing.controlGap

                                        Button {
                                            text: String(autostartAppEntry.modelData.name
                                                         || "(no name)")
                                            foreground: root.fg
                                            fontFamily: root.fontFam
                                            leftAlign: true
                                            width: Math.max(Style.space(80),
                                                            autostartAdd.width - Style.space(180))
                                            anchors.verticalCenter: parent.verticalCenter
                                            onClicked: {
                                                root.autostartNewCommand =
                                                    Model.commandFromApp(autostartAppEntry.modelData)
                                                root.autostartAddOpen = false
                                            }
                                        }

                                        Text {
                                            textFormat: Text.PlainText
                                            text: Model.commandFromApp(autostartAppEntry.modelData)
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

                                // --- ADD FROM A RUNNING PROGRAM --------------
                                //
                                // The open windows, and per window the ranked
                                // suggestions with the SOURCE named on every
                                // one of them. A window has a class, not a
                                // command, so this is a choice and not a
                                // mapping: three of his windows are three
                                // windows of one nimbus process, and one of
                                // them reports a mount path that will not
                                // exist after a restart. Picking fills the
                                // field; the write is still the [Add] button.
                                Column {
                                    id: autostartWindowPicker
                                    width: autostartAdd.width
                                    visible: root.autostartFromWindowOpen
                                    spacing: Style.spacing.xs

                                    Text {
                                        textFormat: Text.PlainText
                                        width: autostartWindowPicker.width
                                        text: root.appsPending
                                              ? "Reading the installed applications..."
                                              : "Pick a window, then a suggestion. "
                                                + "Nothing is written until you press Add."
                                        color: root.fg
                                        opacity: 0.7
                                        font.family: root.fontFam
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }

                                    Text {
                                        textFormat: Text.PlainText
                                        width: autostartWindowPicker.width
                                        visible: root.openWindows.length === 0
                                        text: "No open windows were found."
                                        color: root.fg
                                        opacity: 0.7
                                        font.family: root.fontFam
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                    }

                                    Repeater {
                                        model: root.autostartFromWindowOpen
                                               ? root.openWindows : []

                                        delegate: Column {
                                            id: autostartWindowEntry
                                            required property var modelData
                                            // The outer index under a name of its
                                            // own: the suggestions Repeater below
                                            // has an `index` that shadows this one,
                                            // and this project has already measured
                                            // what that costs -- 4 of 6 delegates
                                            // reading the wrong row.
                                            readonly property int windowIndex: index
                                            readonly property var candidates:
                                                root.autostartCandidatesFor(autostartWindowEntry.modelData)
                                            readonly property string emptyReason:
                                                Model.candidateReasonText(
                                                    Model.autostartCandidateReason(
                                                        autostartWindowEntry.modelData,
                                                        autostartWindowEntry.candidates))
                                            width: autostartWindowPicker.width
                                            spacing: Style.spacing.xs

                                            Button {
                                                // The fold marker as escapes, on
                                                // bytes: a Nerd-Font glyph pasted in
                                                // literally is what this project
                                                // learned to stop doing.
                                                text: (root.autostartWindowUnfolded(autostartWindowEntry.windowIndex)
                                                       ? "\u25BE  " : "\u25B8  ")
                                                      + Model.autostartWindowLabel(
                                                            autostartWindowEntry.modelData)
                                                foreground: root.fg
                                                fontFamily: root.fontFam
                                                leftAlign: true
                                                width: autostartWindowPicker.width
                                                onClicked: root.autostartWindowUnfold(autostartWindowEntry.windowIndex)
                                            }

                                            // A window with nothing to offer says so
                                            // HERE, unfolded or not, and stays in the
                                            // list. A window that quietly disappeared
                                            // would be one the user cannot even ask
                                            // about.
                                            Text {
                                                textFormat: Text.PlainText
                                                width: autostartWindowPicker.width
                                                visible: autostartWindowEntry.emptyReason !== ""
                                                text: autostartWindowEntry.emptyReason
                                                color: root.warn
                                                font.family: root.fontFam
                                                font.pixelSize: Style.font.caption
                                                wrapMode: Text.WordWrap
                                            }

                                            Repeater {
                                                model: root.autostartWindowUnfolded(autostartWindowEntry.windowIndex)
                                                       ? autostartWindowEntry.candidates : []

                                                delegate: Column {
                                                    id: autostartCandidate
                                                    required property var modelData
                                                    width: autostartWindowPicker.width
                                                    spacing: 0

                                                    Button {
                                                        text: String(autostartCandidate.modelData.command)
                                                        foreground: root.fg
                                                        fontFamily: root.fontFam
                                                        leftAlign: true
                                                        width: autostartWindowPicker.width
                                                        onClicked: root.autostartUseCandidate(
                                                            autostartCandidate.modelData.command)
                                                    }

                                                    // WHERE IT CAME FROM, on every
                                                    // row. The user is choosing
                                                    // between a packaged command and
                                                    // a measured one, and that
                                                    // difference is the whole basis
                                                    // for choosing.
                                                    Text {
                                                        textFormat: Text.PlainText
                                                        width: autostartWindowPicker.width
                                                        text: Model.candidateSourceText(
                                                                  autostartCandidate.modelData.source)
                                                              + (String(autostartCandidate.modelData.name) !== ""
                                                                 ? " -- " + String(autostartCandidate.modelData.name)
                                                                 : "")
                                                        color: root.fg
                                                        opacity: 0.6
                                                        font.family: root.fontFam
                                                        font.pixelSize: Style.font.caption
                                                        wrapMode: Text.WordWrap
                                                    }

                                                    // EVERY warning, never only the
                                                    // first: one is about the next
                                                    // boot and the other about a
                                                    // duplicate, and neither stands
                                                    // in for the other.
                                                    Repeater {
                                                        model: autostartCandidate.modelData.warnings || []

                                                        delegate: Text {
                                                            required property var modelData
                                                            textFormat: Text.PlainText
                                                            width: autostartWindowPicker.width
                                                            text: Model.candidateWarningText(modelData)
                                                            color: root.warn
                                                            font.family: root.fontFam
                                                            font.pixelSize: Style.font.caption
                                                            wrapMode: Text.WordWrap
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    width: autostartAdd.width
                                    visible: root.autostartError !== ""
                                    text: root.autostartError
                                    color: root.warn
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    width: autostartAdd.width
                                    visible: root.autostartMessage !== ""
                                    text: root.autostartMessage
                                    color: root.fg
                                    font.family: root.fontFam
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }

                    // THE BUILD, bottom right, quiet. A user testing this on a
                    // second machine needs to see at a glance which build is in
                    // front of them, and that is the only thing this line is for.
                    //
                    // THE NUMBER IS NOT SPELLED HERE. It comes from
                    // Model.versionText(), and a structural check forbids a
                    // version-shaped literal anywhere in this file: a number
                    // written here would be a second source of truth, and the
                    // one thing this indicator must not do is name a build it
                    // is not. A shell assertion binds Model.VERSION to
                    // manifest.json's `version` in both directions.
                    //
                    // The LAST child of `body` and full-width with the text
                    // pushed right, rather than a positioned overlay: it adds
                    // one caption line below the list and moves nothing beside
                    // it. `visible` follows the text, so an empty version
                    // occupies no space at all instead of leaving a stray "v".
                    Text {
                        textFormat: Text.PlainText
                        width: body.width
                        horizontalAlignment: Text.AlignRight
                        visible: text !== ""
                        text: Model.versionText()
                        color: root.fg
                        opacity: 0.5
                        font.family: root.fontFam
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }
    }
}
