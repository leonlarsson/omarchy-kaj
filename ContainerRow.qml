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
  property bool expanded: false
  property var env: null
  // Which keys are currently revealed. Owned by the panel, not by this row:
  // the list Repeater rebuilds its delegates on every refresh, so anything
  // kept here is destroyed along with the row a few seconds after the user
  // clicks — which looked exactly like the reveal spontaneously undoing itself.
  property var revealed: ({})

  signal actionRequested(string action)
  signal toggleExpandRequested()

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
    + (expanded ? envBlock.implicitHeight + Style.space(8) : 0)

  signal revealToggled(string key)

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: layout.implicitHeight + Style.space(10)
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

  // Environment, shown only while the row is expanded.
  Column {
    id: envBlock
    visible: row.expanded
    anchors.top: layout.bottom
    anchors.topMargin: Style.space(6)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(23)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(2)

    Text {
      visible: !row.env || row.env.length === 0
      text: row.env ? "No environment variables" : "Loading…"
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }

    Repeater {
      model: row.expanded && row.env ? row.env : []

      Row {
        required property var modelData
        readonly property bool shown: row.revealed[modelData.key] === true

        width: envBlock.width
        spacing: Style.space(8)

        Text {
          text: modelData.key
          color: Util.alpha(row.foreground, 0.8)
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }

        Text {
          width: envBlock.width - x
          text: shown ? modelData.value : modelData.masked
          color: shown ? row.foreground : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(2)
            cursorShape: Qt.PointingHandCursor
            onClicked: row.revealToggled(modelData.key)
          }
        }
      }
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
    // Pinned to the top rather than centred: an expanded row grows downward,
    // and centring would push the container's own line into the middle of its
    // own environment list.
    anchors.top: parent.top
    anchors.topMargin: Style.space(5)
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(9)

    // Status indicator. A ring rather than a fill for stopped containers, so
    // state is legible without relying on colour alone, and a glyph in place of
    // the dot for states whose shape says more than a colour can.
    Item {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(8)
      height: width

      readonly property string glyph: Model.statusGlyph(row.container)

      Text {
        anchors.centerIn: parent
        visible: parent.glyph !== ""
        text: parent.glyph
        color: row.severityColor
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }

    Rectangle {
      anchors.centerIn: parent
      visible: parent.glyph === ""
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

      PanelActionButton {
        iconText: row.expanded ? "󰅁" : "󰅀"
        tooltipText: "Environment variables  (e)"
        foreground: row.expanded ? Color.accent : row.foreground
        hoverColor: Color.accent
        fontFamily: row.fontFamily
        fontSize: Style.font.caption
        onClicked: row.toggleExpandRequested()
      }

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
