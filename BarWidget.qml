import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar face of Kaj: one glyph, one count, one colour.
// A glance must answer "is anything wrong?" without opening the panel.
BarWidget {
  id: root
  moduleName: "mozzy.kaj"

  readonly property var kaj: bar && bar.shell ? bar.shell.serviceFor("mozzy.kaj") : null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  readonly property string severity: kaj ? kaj.severity : "ok"
  readonly property bool degraded: kaj ? (!kaj.dockerInstalled || !kaj.daemonReachable) : true
  readonly property int runningCount: kaj ? kaj.runningCount : 0

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // The shell hands widget settings here. Forward them to the service.
  function pushSettings() {
    if (kaj) kaj.settings = root.settings || ({})
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.kaj = root.kaj
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onKajChanged: { injectPanel(); pushSettings() }
  onSettingsChanged: pushSettings()
  Component.onCompleted: pushSettings()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // The count is part of the label, not a sibling. WidgetButton sizes itself from
    // its own text, so anything outside it would overlap the next widget.
    // A vertical bar has no room for the number.
    readonly property bool countShown: !root.vertical && !root.degraded
      && root.runningCount > 0
      && (!root.kaj || root.kaj.showContainerCountInBar)

    text: countShown ? "󰡨 " + root.runningCount : "󰡨"

    // The icon alone carries the widget, so it is drawn a little larger. Beside
    // a number it would tower over it.
    fontSize: countShown ? Style.font.body : Style.font.body * 1.25

    tooltipText: root.kaj ? root.kaj.summary : "Docker"

    // Severity uses the bar's palette, so Kaj follows omarchy theme set.
    foreground: {
      var base = root.bar ? root.bar.barForeground : Color.foreground
      if (root.degraded) return Qt.darker(base, 1.55)
      if (root.severity === "error") return root.bar ? root.bar.urgent : Color.urgent
      if (root.severity === "warn") return Color.accent
      return base
    }

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton && root.kaj) root.kaj.refresh()
    }
  }
}
