import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Searchable, virtualized application picker. SearchableDropdown uses a
// ListView internally, so a machine with thousands of desktop entries creates
// only the visible rows instead of one delegate per application.
SearchableDropdown {
    id: root

    property var applications: []
    property bool pending: false

    signal opening()
    signal commandPicked(string command)

    showLabel: false
    triggerLabel: pending ? "Reading applications..." : "Applications"
    placeholderText: "Search applications..."
    emptyText: pending ? "Reading applications..." : "No matching applications"

    options: Model.applicationPickerOptions(root.applications)

    onPopupOpenChanged: {
        if (popupOpen) root.opening()
    }

    onChanged: function(command) {
        root.commandPicked(command)
        root.value = ""
    }
}
