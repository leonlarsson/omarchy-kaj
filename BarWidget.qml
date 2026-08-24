import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar face of Kaj: one glyph, one count, one colour. Everything else lives
// in Panel.qml. The rule for this file is that a glance should answer "is
// anything wrong?" without opening anything.
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

  // The shell hands widget settings to the bar widget, so this is where they
  // enter the plugin. Forward them to the service, which is what actually acts
  // on readOnly, showStats, and the rest.
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

    // The count rides in the label rather than as a sibling Item: WidgetButton
    // derives implicitWidth from its own text, so anything anchored outside it
    // would overlap the neighbouring widget on a busy bar. A vertical bar has
    // no room for the number, so it shows the glyph alone.
    text: {
      if (root.vertical || root.degraded || root.runningCount <= 0) return "󰡨"
      return "󰡨 " + root.runningCount
    }

    tooltipText: root.kaj ? root.kaj.summary : "Docker"

    // Severity maps onto the bar's own palette rather than hardcoded colours,
    // so Kaj follows `omarchy theme set` like every first-party widget does.
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
