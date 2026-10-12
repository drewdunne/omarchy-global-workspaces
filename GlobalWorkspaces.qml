import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Desktop indicators for Global Workspaces. A desktop is one workspace per
// monitor (id = desktop * 10 + monitor), so the bar shows desktops rather
// than raw workspace ids, and clicking one switches every monitor at once.
//
// While the Hyprland half is not running (`setup off`, or not loaded), the
// widget shows plain workspaces 1-10 instead, like Omarchy's own widget.
BarWidget {
  id: root
  moduleName: "gg.arkship.global-workspaces"

  // Keyboard order: SUPER+1 .. SUPER+9, then SUPER+0.
  readonly property var desktopOrder: [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

  // Assume on until Hyprland says otherwise, so the bar does not flicker
  // where the plugin always runs.
  property bool running: true

  Process {
    id: probe
    command: ["hyprctl", "repl", "return GlobalWorkspaces ~= nil"]
    stdout: StdioCollector {
      onStreamFinished: {
        var answer = String(text || "").trim()
        if (answer === "true" || answer === "false") root.running = answer === "true"
      }
    }
  }

  Component.onCompleted: probe.running = true

  // `setup off` and `setup on` both end in a config reload.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") probe.running = true
    }
  }

  function desktopOf(id) {
    if (id < 1 || id > 99 || id % 10 === 0) return -1
    return Math.floor(id / 10)
  }

  // Plain workspaces: 10 is shown as 0, like the key that reaches it.
  function slotOf(id) {
    if (!root.running) return id >= 1 && id <= 10 ? id % 10 : -1
    return desktopOf(id)
  }

  readonly property int focusedSlot: Hyprland.focusedWorkspace !== null
    ? slotOf(Hyprland.focusedWorkspace.id) : -1

  function isOccupied(slot) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (slotOf(values[i].id) === slot && values[i].toplevels.values.length > 0) return true
    }

    return false
  }

  function exists(slot) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (slotOf(values[i].id) === slot) return true
    }

    return false
  }

  // Desktops 1-5 always show. Past that the row grows one empty desktop
  // beyond the last one with windows (windows on 5 reveal 6, on 6 reveal 7),
  // and always reaches the focused desktop. Plain workspaces show 1-5 and
  // any other that exists, as Omarchy's widget does.
  function slots() {
    var count = 5
    var order = []
    for (var i = 0; i < desktopOrder.length; i++) {
      var slot = desktopOrder[i]
      if (root.running) {
        if (isOccupied(slot)) count = Math.max(count, i + 2)
        if (slot === focusedSlot) count = Math.max(count, i + 1)
      } else if (i < 5 || exists(slot)) {
        order.push(slot)
      }
    }

    return root.running ? desktopOrder.slice(0, Math.min(count, desktopOrder.length)) : order
  }

  function switchTo(slot) {
    if (!root.bar) return
    // Falls back to a plain workspace switch if the Hyprland half of the
    // plugin is not loaded (see `setup install` and `setup off`).
    var fallback = slot === 0 ? 10 : slot
    var lua = "if GlobalWorkspaces then GlobalWorkspaces.switch(" + slot + ") "
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
    columns: root.vertical ? 1 : root.slots().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.slots()

      WidgetButton {
        required property int modelData

        readonly property bool occupied: root.isOccupied(modelData)
        readonly property bool focused: root.focusedSlot === modelData

        bar: root.bar
        text: focused ? "󱓻" : String(modelData)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.switchTo(modelData) }
      }
    }
  }
}
