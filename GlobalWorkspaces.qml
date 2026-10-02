import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Desktop indicators for Global Workspaces. A desktop is one workspace per
// monitor (id = desktop * 10 + monitor), so the bar shows desktops rather
// than raw workspace ids, and clicking one switches every monitor at once.
BarWidget {
  id: root
  moduleName: "gg.arkship.global-workspaces"

  // Keyboard order: SUPER+1 .. SUPER+9, then SUPER+0.
  readonly property var desktopOrder: [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

  function desktopOf(id) {
    if (id < 1 || id > 99 || id % 10 === 0) return -1
    return Math.floor(id / 10)
  }

  readonly property int focusedDesktop: Hyprland.focusedWorkspace !== null
    ? desktopOf(Hyprland.focusedWorkspace.id) : -1

  function isOccupied(desktop) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (desktopOf(values[i].id) === desktop && values[i].toplevels.values.length > 0) return true
    }

    return false
  }

  // Desktops 1-5 always show. Past that the row grows one empty desktop
  // beyond the last one with windows (windows on 5 reveal 6, on 6 reveal 7),
  // and always reaches the focused desktop.
  function desktops() {
    var count = 5
    for (var i = 0; i < desktopOrder.length; i++) {
      if (isOccupied(desktopOrder[i])) count = Math.max(count, i + 2)
      if (desktopOrder[i] === focusedDesktop) count = Math.max(count, i + 1)
    }

    return desktopOrder.slice(0, Math.min(count, desktopOrder.length))
  }

  function switchDesktop(desktop) {
    if (!root.bar) return
    // Falls back to a plain workspace switch if the Hyprland half of the
    // plugin is not loaded (see `setup install`).
    var fallback = desktop === 0 ? 10 : desktop
    var lua = "if GlobalWorkspaces then GlobalWorkspaces.switch(" + desktop + ") "
      + "else hl.dispatch(hl.dsp.focus({ workspace = \"" + fallback + "\" })) end"
    root.bar.run("hyprctl eval " + Util.shellQuote(lua))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.desktops().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.desktops()

      WidgetButton {
        required property int modelData

        readonly property bool occupied: root.isOccupied(modelData)
        readonly property bool focused: root.focusedDesktop === modelData

        bar: root.bar
        text: focused ? "󱓻" : String(modelData)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.switchDesktop(modelData) }
      }
    }
  }
}
