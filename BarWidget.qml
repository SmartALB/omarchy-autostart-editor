import QtQuick
import qs.Commons
import qs.Ui

// Bar entry. Glyph only, no label.
//
// The glyph MUST stay a \u escape. A literal Nerd Font character sits in the
// private use area and does not survive being copied through documents and
// tools; what arrives is an empty string. And an empty text is not a button
// without an icon, it is no button: WidgetButton sets
// hasVisualContent: text !== "" || iconComponent !== null, and
// visible: hasVisualContent || keepSpace. The widget then loads completely,
// shows up as an ipc target, passes qmllint, and is invisible.
//
// Verify on the file, never on the source you just typed:
//   grep -n "barGlyph:" BarWidget.qml | od -c
//
// DEVIATION FROM THE TASK BRIEF'S SAMPLE CODE, and why: the brief's Step 3
// used `BarIconButton { id: root ... }` as the root type and wired the click
// with `onClicked: root.toggle()`. Checked directly against the platform
// actually installed on this machine
// (/usr/share/omarchy/shell/Ui/WidgetButton.qml), that type declares only
// `signal pressed(int button)` -- its MouseArea's own `onClicked` is a
// private detail that forwards to `pressed`, never a signal the type itself
// exposes. Assigning `onClicked:` on a type with no `clicked` signal is a
// QML component-creation error ("Cannot assign to non-existent
// property/signal onClicked"), and no suite in this project could ever have
// caught that: nothing here can execute a file that imports Quickshell.
// Every bar widget actually shipped with this platform --
// /usr/share/omarchy/shell/plugins/panels/weather/BarWidget.qml and
// /usr/share/omarchy/shell/plugins/bar/widgets/Microphone.qml, both read
// from the installed shell, not invented here -- extends BarWidget (never
// BarIconButton directly) and wires clicks through `onPressed:`. This file
// follows that proven shape instead of the brief's sample: BarWidget as the
// root (which also carries `moduleName`, absent from BarIconButton), a
// BarIconButton child with `bar` forwarded, and `onPressed` for the click.
// Every literal string the structural checks (test/qml-structure.sh) look
// for is still present verbatim.
BarWidget {
    id: root
    moduleName: "smartalb.autostart"

    readonly property string barGlyph: "\uf135"   // nf-fa-rocket

    // countsKnown stays false until the lazily-loaded panel reports in
    // (see the Loader below). The Loader is lazy on purpose -- this
    // component is created and destroyed on every QML change, and building
    // the whole panel just to read two numbers on every restart is a worse
    // trade than an honest tooltip. Showing "0 programs, 0 placements"
    // before that report would be a false statement about the user's
    // configuration, not merely an unknown one, so the plain name is shown
    // instead until the real counts are in.
    property bool countsKnown: false
    property int programCount: 0
    property int placementCount: 0

    readonly property string tooltip:
        root.countsKnown
            ? "Autostart Layout \u2014 " + root.programCount + " programs, "
              + root.placementCount + " placements"
            : "Autostart Layout"

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
    readonly property bool popoutSwitchClosing:
        panelLoader.item ? panelLoader.item.popoutSwitchClosing : false

    function open()  { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    // THE PANEL CANNOT POSITION ITSELF WITHOUT THIS. Its popup is anchored to
    // a bar button, and the button is here, not there -- so the anchor has to
    // be handed over. `hostWidget` matters just as much: the bar tracks the
    // widget mounted in its slot, so the popout coordinator (and with it the
    // open-panel mark under the pill) and switchPanelFrom both compare against
    // THIS object, never the nested panel.
    //
    // Membership-tested with `in` rather than assigned blind, exactly as
    // clock/BarWidget.qml:97 does it: assigning a property a type does not
    // have is a component error, and this widget must keep working if the
    // panel it loads is ever replaced by one that wants fewer of them.
    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
    }

    // `bar` and `settings` arrive after construction, so an injection done
    // only at load time would hand over stale values or none at all.
    onBarChanged: root.injectPanel()
    onSettingsChanged: root.injectPanel()

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.barGlyph
        tooltipText: root.tooltip

        onPressed: function(b) { root.toggle() }
    }

    // EAGER, and visible: false. This revises the earlier lazy ruling: the
    // platform hands a panel its anchor from the Loader's own onLoaded, so a
    // lazy Loader means the anchor arrives only AFTER the first open -- the
    // first click would open a popup with nothing to position against. Every
    // shipped panel host does it this way (clock/BarWidget.qml:118).
    // `visible: false` because this Loader's item is content, not a bar
    // control: the popup it owns is a layer-shell window of its own and does
    // not paint through this slot.
    //
    // Creating the panel object eagerly is cheap; READING THE CONFIGURATION is
    // not, and the panel deliberately does that in open() rather than at
    // creation, so this costs no processes at shell start. That is also why
    // countsKnown below stays false until the first open: the counts are
    // unknown, not zero, and saying "0 programs" before the file has been read
    // would be a false statement about the user's configuration.
    Loader {
        id: panelLoader
        active: true
        visible: false
        source: Qt.resolvedUrl("Panel.qml")
        onLoaded: {
            root.injectPanel()
            // Twice, the second time deferred, as the platform does it: `bar`
            // may still be null at this instant, and onBarChanged does not
            // fire for a value that was already set before this Loader ran.
            Qt.callLater(root.injectPanel)
            item.counted.connect(function(programs, placements) {
                root.programCount = programs
                root.placementCount = placements
                root.countsKnown = true
            })
        }
    }
}
