import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kaj's panel: containers grouped by Compose project, because that is how
// people think about them — "my app", not eleven unrelated names.
Panel {
  id: root
  moduleName: "mozzy.kaj"
  // Gives `omarchy-shell mozzy.kaj toggle`, so the panel can be bound to a key
  // in hyprland instead of only reachable by clicking the bar.
  ipcTarget: "mozzy.kaj"
  manageIpc: true

  property var anchorItem: null
  property var hostWidget: null
  property var kaj: null

  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Util.alpha(contentForeground, 0.62)

  readonly property var groups: kaj ? kaj.groups : []
  readonly property bool readOnly: kaj ? kaj.readOnly === true : false
  readonly property bool showStats: kaj ? kaj.showStats === true : true
  readonly property bool installed: kaj ? kaj.dockerInstalled === true : false
  readonly property bool reachable: kaj ? kaj.daemonReachable === true : false
  readonly property bool probing: kaj ? kaj.probing === true : true
  readonly property bool hasContainers: kaj ? kaj.totalCount > 0 : false

  // Pending destructive action, held while the confirm dialog is up. Kaj never
  // performs one of these directly from a click.
  property string pendingAction: ""
  property var pendingContainer: null

  // Uptime is derived from a fixed startedAt, so nothing in the container data
  // changes as it ages. Without a clock of its own the label would sit at
  // whatever it read when the list was last rebuilt — which is why it could
  // show "Up 5s" long after the fact while live stats kept moving. Ticking only
  // while the panel is open keeps a closed panel completely idle.
  property double nowMs: Date.now()

  Timer {
    running: root.opened
    interval: 1000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  function scrollPanel(delta) {
    panelFlick.contentY = Math.max(
      0,
      Math.min(panelFlick.contentY + delta, Math.max(0, panelFlick.contentHeight - panelFlick.height))
    )
  }

  // The one place a container action enters the panel. Destructive verbs are
  // parked here until the user confirms; everything else runs immediately,
  // because putting a dialog in front of "restart" is how people learn to click
  // through the dialog that actually matters.
  function requestAction(action, container) {
    if (!kaj || !container) return
    if (action === "logs") { kaj.openLogs(container); return }
    if (action === "shell") { kaj.openShell(container); return }

    if (Model.isDestructive(action)) {
      pendingAction = action
      pendingContainer = container
      confirm.message = Model.confirmText(action, container)
      confirm.confirmText = Model.confirmVerb(action)
      confirm.selectedIndex = 0
      confirm.opened = true
      return
    }
    kaj.runAction(action, container)
  }

  function clearPending() {
    pendingAction = ""
    pendingContainer = null
  }


  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.scrollPanel(dy * Style.space(56))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        WheelHandler {
          onWheel: function (event) {
            if (event.angleDelta.y === 0) return
            root.scrollPanel(event.angleDelta.y > 0 ? -Style.space(56) : Style.space(56))
            event.accepted = true
          }
        }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- Header ------------------------------------------------------

          Row {
            width: parent.width
            spacing: Style.space(12)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰡨"
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.space(36)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(36) - refreshButton.width - Style.space(30)
              spacing: Style.space(2)

              Row {
                spacing: Style.space(7)

                Text {
                  text: "Kaj"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  textFormat: Text.PlainText
                }

                // Read-only is a mode with real consequences for what the
                // buttons do, so it is stated in the header rather than hidden
                // in settings.
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.readOnly
                  width: readOnlyLabel.implicitWidth + Style.space(10)
                  height: readOnlyLabel.implicitHeight + Style.space(3)
                  radius: Style.cornerRadius
                  color: Util.alpha(root.contentForeground, 0.1)

                  Text {
                    id: readOnlyLabel
                    anchors.centerIn: parent
                    text: "READ-ONLY"
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                }
              }

              Text {
                width: parent.width
                text: root.kaj ? root.kaj.summary : ""
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.contentForeground
              hoverColor: Color.accent
              fontFamily: root.contentFontFamily
              enabled: root.reachable
              opacity: enabled ? 1.0 : 0.35
              onClicked: if (root.kaj) root.kaj.refresh()
            }
          }

          PanelSeparator { width: parent.width }

          // ---- Degraded states ---------------------------------------------

          // Docker missing or unreachable is not an error to bury in a toast:
          // it is the whole state of the panel, so it takes the whole panel.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.probing && (!root.installed || !root.reachable)

            Text {
              width: parent.width
              text: root.installed ? "Docker daemon is not running" : "Docker is not installed"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            Text {
              width: parent.width
              text: {
                if (!root.installed) return "Install it with: omarchy install docker"
                var detail = root.kaj ? root.kaj.daemonError : ""
                if (detail && detail !== "") return detail
                return "Start it with: sudo systemctl start docker"
              }
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            // Deliberately not a button. Starting a system daemon is a
            // privileged action, and Kaj would rather hand over a command the
            // user runs knowingly than escalate on their behalf from a bar
            // popup — a click there is too cheap for what it does.
          }

          // ---- Empty state -------------------------------------------------

          Text {
            width: parent.width
            visible: root.reachable && !root.hasContainers && !root.probing
            text: "No containers yet."
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
          }

          // ---- Groups ------------------------------------------------------

          Repeater {
            model: root.groups

            Column {
              required property var modelData

              width: content.width
              spacing: Style.space(5)

              PanelSectionHeader {
                width: parent.width
                // Compose project name, or a plain label for the containers
                // that belong to no project.
                text: modelData.standalone
                  ? "CONTAINERS"
                  : (modelData.project + "  ·  " + modelData.running + "/" + modelData.total)
                foreground: modelData.severity === "error" ? Color.urgent : root.contentForeground
                fontFamily: root.contentFontFamily
              }

              Repeater {
                model: modelData.containers

                ContainerRow {
                  required property var modelData

                  width: content.width
                  container: modelData
                  stats: root.kaj ? root.kaj.statsFor(modelData) : null
                  kaj: root.kaj
                  now: root.nowMs
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  showStats: root.showStats
                  readOnly: root.readOnly
                  busy: root.kaj ? root.kaj.busyContainerId === modelData.id : false

                  onActionRequested: function (action) { root.requestAction(action, modelData) }
                }
              }
            }
          }

          // ---- Errors ------------------------------------------------------

          Text {
            width: parent.width
            visible: root.kaj && root.kaj.lastError !== ""
            text: root.kaj ? root.kaj.lastError : ""
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
        }
      }
    }

    // The gate in front of every destructive verb. It lives inside the panel
    // surface rather than under the Panel root: that root is a zero-sized Item
    // in the bar hierarchy, so anchors.fill there would size the dialog to
    // nothing and the confirmation would silently never appear.
    ConfirmDialog {
      id: confirm
      anchors.fill: parent
      z: 10
      background: Color.background
      foreground: root.contentForeground
      fontFamily: root.contentFontFamily
      cancelText: "Cancel"

      onConfirmed: {
        if (root.kaj && root.pendingContainer) {
          root.kaj.runAction(root.pendingAction, root.pendingContainer)
        }
        confirm.opened = false
        root.clearPending()
      }

      onCanceled: {
        confirm.opened = false
        root.clearPending()
      }
    }
  }
}
