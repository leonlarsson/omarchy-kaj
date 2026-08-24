import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One container. Renders state, live usage, and the actions valid for that
// state — Model.availableActions() decides which, so the panel can never offer
// "start" on something already running.
//
// Every Text in here is PlainText. Container names and image tags come from
// images the user may not have built, and QML's RichText would parse an
// <img src="file:///..."> hidden in one of them.
Item {
  id: row

  property var container: null
  property var stats: null
  property var kaj: null
  // Driven by the panel's clock so uptime ages in place. Falling back to
  // Date.now() keeps the row correct if it is ever used without one.
  property double now: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool showStats: true
  property bool readOnly: false
  // The verb currently running against this container, or "" when idle.
  property string busyVerb: ""
  readonly property bool busy: busyVerb !== ""
  // Keyboard cursor. Distinct from hover so a mouse passing over the panel
  // never looks like a selection the keyboard would act on.
  property bool hasCursor: false

  signal actionRequested(string action)

  readonly property string severity: Model.containerSeverity(container)
  readonly property bool running: container ? container.running === true : false
  readonly property var actions: Model.availableActions(container)
  readonly property color dim: Util.alpha(foreground, 0.6)

  readonly property color severityColor: {
    if (severity === "error") return Color.urgent
    if (severity === "warn") return Color.accent
    return running ? Color.accent : Util.alpha(foreground, 0.35)
  }

  implicitHeight: layout.implicitHeight + Style.space(10)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.hasCursor
      ? Style.selectedFillFor(row.foreground, Color.accent)
      : (hover.containsMouse ? Util.alpha(row.foreground, 0.06) : "transparent")
    Behavior on color { ColorAnimation { duration: 90 } }

    // An accent bar on the selected row, so the cursor is legible even where
    // the fill tint is subtle against the theme background.
    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(2)
      height: parent.height * 0.62
      radius: width
      visible: row.hasCursor
      color: Color.accent
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  Row {
    id: layout
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(9)

    // Status dot. A ring rather than a fill for stopped containers, so state is
    // legible without relying on colour alone.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(8)
      height: width
      radius: width / 2
      color: row.running ? row.severityColor : "transparent"
      border.width: row.running ? 0 : 1
      border.color: row.severityColor

      // Transient states are the ones worth animating: an action in flight,
      // restarting, and waiting on a healthcheck. A still dot would read as
      // settled when it is not.
      SequentialAnimation on opacity {
        running: row.busy || (row.container
          ? (row.container.restarting === true || row.container.health === "starting")
          : false)
        loops: Animation.Infinite
        NumberAnimation { to: 0.25; duration: 620; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: layout.width - Style.space(8) - actionRow.width - statsColumn.width - Style.space(36)
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: row.container ? (row.container.service !== "" ? row.container.service : row.container.name) : ""
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      // Status and published ports share a line: a bar popup has no room for a
      // second row per container, and a port is only meaningful alongside
      // whether the thing is actually up.
      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: statusText
          text: row.busy
            ? Model.busyLabel(row.busyVerb)
            : (row.container ? Model.statusSummary(row.container, row.now || Date.now()) : "")
          color: row.busy
            ? Color.accent
            : (row.severity === "error" ? Color.urgent : row.dim)
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }

        Repeater {
          model: row.running && !row.busy ? Model.linkablePorts(row.container) : []

          Text {
            required property var modelData

            text: ":" + modelData.port
            color: portMouse.containsMouse ? Color.accent : Util.alpha(row.foreground, 0.75)
            font.family: row.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: portMouse.containsMouse
            textFormat: Text.PlainText

            MouseArea {
              id: portMouse
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (row.kaj) row.kaj.openPort(modelData.url)
            }
          }
        }
      }
    }

    // Live usage. Fixed width so rows stay aligned as numbers change instead of
    // jittering the action buttons left and right.
    Column {
      id: statsColumn
      anchors.verticalCenter: parent.verticalCenter
      visible: row.showStats && row.running && row.stats !== null
      width: visible ? Style.space(62) : 0
      spacing: Style.space(1)

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: row.stats ? Model.formatPercent(row.stats.cpu) + " cpu" : ""
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: row.stats ? Model.formatBytes(row.stats.memUsed) : ""
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }
    }

    Row {
      id: actionRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Repeater {
        model: row.actions

        PanelActionButton {
          required property string modelData

          readonly property bool destructive: Model.isDestructive(modelData)
          // Read-only mode disables mutation but deliberately leaves logs and
          // shell alone: reading is the thing read-only mode is for.
          readonly property bool inspectOnly: modelData === "logs" || modelData === "shell"

          iconText: {
            switch (modelData) {
              case "start": return "󰐊"
              case "stop": return "󰓛"
              case "restart": return "󰑐"
              case "pause": return "󰏤"
              case "unpause": return "󰐊"
              case "remove": return "󰩹"
              case "logs": return "󰈙"
              case "shell": return "󰆍"
              default: return "󰋼"
            }
          }

          // The tooltip is where a mouse user discovers the keyboard, so every
          // one names its key.
          tooltipText: {
            var key = Model.actionHotkey(modelData)
            return baseTooltip + (key === "" ? "" : "  (" + key + ")")
          }

          readonly property string baseTooltip: {
            switch (modelData) {
              case "start": return "Start"
              case "stop": return "Stop"
              case "restart": return "Restart"
              case "pause": return "Pause"
              case "unpause": return "Resume"
              case "remove": return "Remove container"
              case "logs": return "Follow logs in a terminal"
              case "shell": return "Open a shell in this container"
              default: return modelData
            }
          }

          enabled: !row.busy && (inspectOnly || !row.readOnly)
          opacity: enabled ? 1.0 : 0.35
          foreground: destructive ? Color.urgent : row.foreground
          hoverColor: destructive ? Color.urgent : Color.accent
          fontFamily: row.fontFamily
          fontSize: Style.font.caption

          onClicked: row.actionRequested(modelData)
        }
      }
    }
  }
}
