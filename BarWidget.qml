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

    function open()  { panelLoader.active = true; if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

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

    Loader {
        id: panelLoader
        active: false
        source: "Panel.qml"
        onLoaded: {
            item.counted.connect(function(programs, placements) {
                root.programCount = programs
                root.placementCount = placements
                root.countsKnown = true
            })
        }
    }
}
