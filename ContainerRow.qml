import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One container: state, live usage, and the actions valid for that state.
// Every Text here is PlainText. Names and tags come from untrusted images.
Item {
  id: row

  property var container: null
  property var stats: null
  property var kaj: null
  // Driven by the panel's clock so uptime ages in place.
  property double now: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool showResourceUsage: true
  property bool readOnly: false
  // The verb running against this container, or empty when idle.
  property string busyVerb: ""
  readonly property bool busy: busyVerb !== ""
  // Keyboard cursor. Separate from hover, so passing the mouse over the panel
  // never looks like a selection.
  property bool hasCursor: false
  property bool expanded: false
  property var env: null
  // Which keys are revealed. Owned by the panel: the Repeater rebuilds delegates
  // on every refresh, and anything kept here dies with the row.
  property var revealed: ({})

  signal actionRequested(string action)
  signal toggleExpandRequested()

  readonly property string severity: Model.containerSeverity(container)
  readonly property bool running: container ? container.running === true : false
  // In read-only mode the buttons that cannot fire are not drawn at all.
  readonly property var actions: Model.availableActions(container, readOnly)
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property real memoryPressure: Model.memoryPressure(container, stats)
  readonly property real cpuPressure: Model.cpuPressure(container, stats)
  // Stats and actions share one right-anchored slot, so both sit at the same edge
  // on every row.
  readonly property real rightReserve: Style.space(150)
  readonly property bool actionsShown: hasCursor || rowHover.hovered || busy || expanded

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
      : (rowHover.hovered ? Util.alpha(row.foreground, 0.06) : "transparent")
    Behavior on color { ColorAnimation { duration: 90 } }

    // An accent bar on the selected row, so the cursor is legible in any theme.
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
          // Dots give no sign that they can be clicked, so hover brings them to full
          // strength.
          color: shown || valueMouse.containsMouse ? row.foreground : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText

          MouseArea {
            id: valueMouse
            // Sized to the painted text. The value Text runs to the right edge so long
            // values can elide, and filling it would light the dots up from far away.
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: -Style.space(2)
            width: Math.min(parent.width, parent.contentWidth) + Style.space(4)
            height: parent.height + Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.revealToggled(modelData.key)
          }
        }
      }
    }
  }

  // A HoverHandler, not a MouseArea. A child MouseArea takes hover from a parent
  // MouseArea, so buttons under the pointer made the row flicker.
  HoverHandler {
    id: rowHover
  }

  Row {
    id: layout
    anchors.left: parent.left
    anchors.right: parent.right
    // Pinned to the top, because an expanded row grows downward.
    anchors.top: parent.top
    anchors.topMargin: Style.space(5)
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(9)

    // Status indicator. A ring for stopped containers, so state does not rely on
    // colour alone. A glyph where the shape says more than a colour can.
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

      // Only transient states pulse: an action in flight, restarting, or starting.
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
      width: layout.width - Style.space(8) - Style.space(9) - row.rightReserve
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

      // Status and ports share a line. A popup has no room for a second row.
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

    // Live usage. Fixed width so rows stay aligned as the numbers change.

    // Actions stay hidden until the row is hovered or holds the cursor.
    // Opacity, not visibility, so the space stays reserved and nothing shifts.
  }

  Column {
    id: statsColumn
    anchors.verticalCenter: layout.verticalCenter
    anchors.right: layout.right
    visible: row.showResourceUsage && row.running && row.stats !== null
    width: Style.space(62)
    spacing: Style.space(1)
    // Fades out as the actions fade in. They share one slot.
    opacity: row.actionsShown ? 0 : 1

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignRight
      text: row.stats ? Model.formatPercent(row.stats.cpu) + " cpu" : ""
      color: row.cpuPressure >= Model.pressureWarning ? Color.urgent : row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignRight
      text: row.stats ? Model.formatMemory(row.stats.memUsed) : ""
      color: row.memoryPressure >= Model.pressureWarning ? Color.urgent : row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }

    // A meter, not a second number: "483 KB / 512 MiB" does not fit here.
    // Drawn only when the container has its own limit.
    Rectangle {
      width: parent.width
      height: Style.space(2)
      visible: row.memoryPressure >= 0
      radius: height / 2
      color: Util.alpha(row.foreground, 0.15)

      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, row.memoryPressure))
        height: parent.height
        radius: parent.radius
        color: row.memoryPressure >= Model.pressureWarning
          ? Color.urgent : Util.alpha(row.foreground, 0.55)
      }
    }
  }

  Row {
    id: actionRow
    anchors.verticalCenter: layout.verticalCenter
    anchors.right: layout.right
    spacing: Style.space(2)
    opacity: row.actionsShown ? 1 : 0
    enabled: row.actionsShown

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
        // Read-only leaves logs alone. It does not exempt shell.
        readonly property bool inspectOnly: modelData === "logs"

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

        // The tooltip is where a mouse user learns the key.
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
