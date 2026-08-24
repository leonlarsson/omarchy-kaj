import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kaj's panel: containers grouped by Compose project, because that is how
// people think about them — "my app", not eleven unrelated names.
//
// Keyboard model. PanelKeyCatcher already claims h/j/k/l, x, Esc, Tab, Enter
// and Space before Kaj sees a key, and forwards everything else as textKey.
// Search is therefore entered deliberately with Ctrl+F or "/" rather than by
// typing into the list: type-to-filter would swallow the whole alphabet and
// permanently foreclose single-letter action keys. While the search field has
// focus the catcher is `blocked`, which is the mechanism the base component
// documents for exactly this case, so the two modes never fight over a key.
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

  readonly property bool readOnly: kaj ? kaj.readOnly === true : false
  readonly property bool showStats: kaj ? kaj.showStats === true : true
  readonly property bool installed: kaj ? kaj.dockerInstalled === true : false
  readonly property bool reachable: kaj ? kaj.daemonReachable === true : false
  readonly property bool probing: kaj ? kaj.probing === true : true
  readonly property bool hasContainers: kaj ? kaj.totalCount > 0 : false

  // ---- Filter and search state ---------------------------------------------

  property string query: ""
  property bool searchActive: false
  property string statusFilter: "all"

  readonly property var allContainers: kaj ? kaj.containers : []
  readonly property var counts: Model.statusCounts(allContainers, query)
  // Replaced only when the set or order of rows changes, so a container merely
  // changing state does not rebuild every delegate. See Model.groupsKey.
  property var groups: []
  property string groupsKey: ""

  function rebuildGroups() {
    var next = Model.groupByProject(Model.filterContainers(allContainers, query, statusFilter))
    var key = Model.groupsKey(next)
    if (key === groupsKey) return
    groupsKey = key
    groups = next
  }

  onAllContainersChanged: rebuildGroups()
  onQueryChanged: rebuildGroups()
  onStatusFilterChanged: rebuildGroups()
  Component.onCompleted: rebuildGroups()
  // The flat sequence the keyboard walks. Groups are a visual convenience, so
  // j from the last row of one project lands on the first row of the next.
  readonly property var flatContainers: Model.flattenGroups(groups)
  readonly property bool filtering: query !== "" || statusFilter !== "all"

  // ---- Keyboard cursor -----------------------------------------------------

  property int cursorIndex: -1
  // The cursor stays invisible until a key is actually pressed, so a
  // mouse-driven panel never shows a stray highlight the user did not ask for.
  property bool cursorActive: false
  // Tracked by id, not position: an event can rebuild the list while you are
  // three rows down, and the selection must stay on the container you chose.
  property string cursorId: ""

  // The cached list supplies the id; the container itself is looked up live, so
  // Enter never acts on a state that has since changed.
  readonly property var cursorContainer: {
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= flatContainers.length) return null
    if (!kaj) return null
    return kaj.containerById(flatContainers[cursorIndex].id)
  }

  onFlatContainersChanged: {
    if (!cursorActive) return
    cursorIndex = Model.cursorIndexForId(flatContainers, cursorId, cursorIndex)
    cursorId = cursorContainer ? cursorContainer.id : ""
    if (cursorIndex < 0) cursorActive = false
  }

  function moveCursorBy(delta) {
    if (flatContainers.length === 0) return
    cursorActive = true
    cursorIndex = Model.moveCursor(cursorIndex, delta, flatContainers.length)
    cursorId = cursorContainer ? cursorContainer.id : ""
  }

  // h and l are handed to us by the key catcher and would otherwise go unused;
  // stepping the status filter with them keeps every navigation key meaningful.
  function stepFilter(delta) {
    var index = Model.statusFilters.indexOf(statusFilter)
    if (index < 0) index = 0
    var next = index + delta
    if (next < 0) next = Model.statusFilters.length - 1
    if (next >= Model.statusFilters.length) next = 0
    setStatusFilter(Model.statusFilters[next])
  }

  function setStatusFilter(next) {
    statusFilter = next
    resetCursor()
  }

  function resetCursor() {
    cursorIndex = -1
    cursorId = ""
    cursorActive = false
  }

  // ---- Search --------------------------------------------------------------

  function openSearch() {
    searchActive = true
    Qt.callLater(function () { searchField.forceActiveFocus() })
  }

  // Esc in the field clears and leaves; the query is not worth preserving
  // through an explicit cancel.
  function cancelSearch() {
    query = ""
    searchField.text = ""
    searchActive = false
    resetCursor()
    keyCatcher.forceActiveFocus()
  }

  // Enter keeps the query but hands focus back, so j/k drive the list that the
  // search just narrowed — the fzf shape people already expect.
  function commitSearch() {
    keyCatcher.forceActiveFocus()
    if (flatContainers.length > 0) {
      cursorActive = true
      cursorIndex = 0
      cursorId = flatContainers[0].id
    }
  }

  // ---- Actions -------------------------------------------------------------

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
      Qt.callLater(function () { confirmKeys.forceActiveFocus() })
      return
    }
    kaj.runAction(action, container)
  }

  function requestCompose(project, verb, stats) {
    if (!kaj || project === "") return
    if (verb === "down") {
      pendingCompose = project
      pendingAction = "down"
      confirm.message = Model.composeConfirmText(project, stats.running, stats.total)
      confirm.confirmText = "Remove"
      confirm.selectedIndex = 0
      confirm.opened = true
      Qt.callLater(function () { confirmKeys.forceActiveFocus() })
      return
    }
    kaj.composeAction(project, verb)
  }

  property string pendingCompose: ""

  function activateCursor() {
    var container = cursorContainer
    if (!container) return
    requestAction(Model.primaryAction(container), container)
  }

  function removeCursor() {
    var container = cursorContainer
    if (!container) { flash("Select a container first"); return }
    var reason = Model.unavailableReason("remove", container)
    if (reason !== "") { flash(reason); return }
    requestAction("remove", container)
  }

  function handleTextKey(text) {
    // Covers both "/" and Ctrl+F; see Model.isSearchKey for why Ctrl+F has to
    // be recognised here by its control character rather than as a shortcut.
    if (Model.isSearchKey(text)) { openSearch(); return }
    if (text === "?") { helpOpen = !helpOpen; return }
    if (text === "e") { toggleExpanded(cursorContainer); return }
    var container = cursorContainer
    if (!container) return
    var action = Model.intendedAction(text, container)
    if (action === "") return
    var reason = Model.unavailableReason(action, container)
    if (reason !== "") { flash(reason); return }
    requestAction(action, container)
  }

  // Pending destructive action, held while the confirm dialog is up. Kaj never
  // performs one of these directly from a click.
  property string pendingAction: ""
  property var pendingContainer: null

  function clearPending() {
    pendingAction = ""
    pendingContainer = null
    pendingCompose = ""
    // Hand keyboard control back to the list.
    if (opened) keyCatcher.forceActiveFocus()
  }

  // A keystroke that cannot act has to say so. Silence leaves the user unable
  // to tell an unavailable action from a broken keybind, which is how "x does
  // nothing" becomes a bug report instead of a shrug.
  property string notice: ""
  property bool helpOpen: false
  // Only one row is expanded at a time: the panel is a bar popup, not a table.
  property string expandedId: ""
  // Reveals live here rather than in the row for the same reason expandedId
  // does: rows are recreated on every refresh, panel state is not.
  property var revealedKeys: ({})

  function toggleReveal(key) {
    var next = ({})
    for (var existing in revealedKeys) next[existing] = revealedKeys[existing]
    if (next[key]) delete next[key]
    else next[key] = true
    revealedKeys = next
  }

  function toggleExpanded(container) {
    if (!container) return
    if (expandedId === container.id) {
      if (kaj) kaj.forgetEnv(container.id)
      expandedId = ""
      revealedKeys = ({})
      return
    }
    if (kaj) {
      if (expandedId !== "") kaj.forgetEnv(expandedId)
      kaj.loadEnv(container)
    }
    revealedKeys = ({})
    expandedId = container.id
  }

  function flash(message) {
    notice = message
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 2600
    repeat: false
    onTriggered: root.notice = ""
  }

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

  // Every open starts from the configured filter with no stale query or cursor
  // left over from last time.
  onOpenedChanged: {
    if (opened) {
      statusFilter = kaj ? kaj.defaultFilter : "all"
      query = ""
      searchField.text = ""
      searchActive = false
      helpOpen = false
      resetCursor()
    } else {
      searchActive = false
      // Collapse on close, and drop the fetched values rather than merely
      // hiding them: reopening the panel should never show an environment the
      // user last looked at some time ago, and nothing keeps them in memory in
      // the meantime.
      if (kaj && expandedId !== "") kaj.forgetEnv(expandedId)
      expandedId = ""
      revealedKeys = ({})
      helpOpen = false
    }
  }

  // Ctrl+F as a real shortcut rather than sniffing for the raw control byte the
  // key catcher would otherwise deliver through textKey. Gated on `opened` so
  // it cannot fire while the panel is closed.

  function scrollPanel(delta) {
    panelFlick.contentY = Math.max(
      0,
      Math.min(panelFlick.contentY + delta, Math.max(0, panelFlick.contentHeight - panelFlick.height))
    )
  }

  // Keeps the cursor row on screen as j/k walk past the fold.
  function ensureVisible(item) {
    if (!item) return
    var top = item.mapToItem(content, 0, 0).y
    var bottom = top + item.height
    var pad = Style.space(8)
    if (top - pad < panelFlick.contentY) {
      panelFlick.contentY = Math.max(0, top - pad)
    } else if (bottom + pad > panelFlick.contentY + panelFlick.height) {
      panelFlick.contentY = Math.min(
        Math.max(0, panelFlick.contentHeight - panelFlick.height),
        bottom + pad - panelFlick.height)
    }
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
      // While the field has focus every key belongs to it, including j and x.
      // While the confirm dialog is up it owns every key. Without this the
      // catcher underneath kept interpreting them, so an arrow key aimed at
      // Cancel/Remove stepped the status filter behind the dialog instead.
      blocked: (root.searchActive && searchField.activeFocus) || confirm.opened

      onCloseRequested: {
        if (root.helpOpen) root.helpOpen = false
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursorBy(dy)
        else if (dx !== 0) root.stepFilter(dx)
      }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeCursor()
      onTextKey: function (text) { root.handleTextKey(text) }

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
          spacing: Style.space(10)

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
              width: parent.width - Style.space(36) - helpButton.width - searchButton.width - refreshButton.width - Style.space(50)
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
                // The subtitle doubles as the transient notice line. A message
                // appended below the list is never seen: it sits under a
                // scrolling column, off screen, and is gone before anyone
                // scrolls to it. Here it is always visible and costs no layout
                // shift, because the line already exists.
                text: {
                  if (root.notice !== "") return root.notice
                  if (!root.kaj) return ""
                  if (!root.reachable) return root.kaj.summary
                  // While filtering, the honest summary is what is on screen
                  // versus what exists — not the unfiltered total.
                  if (root.filtering) return root.flatContainers.length + " of " + root.kaj.totalCount + " shown"
                  return root.kaj.summary
                }
                color: root.notice !== "" ? Color.accent : root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }

            PanelActionButton {
              id: helpButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰘥"
              tooltipText: "Keyboard shortcuts  (?)"
              foreground: root.helpOpen ? Color.accent : root.contentForeground
              hoverColor: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.helpOpen = !root.helpOpen
            }

            PanelActionButton {
              id: searchButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰍉"
              tooltipText: "Search  (Ctrl+F)"
              foreground: root.searchActive ? Color.accent : root.contentForeground
              hoverColor: Color.accent
              fontFamily: root.contentFontFamily
              enabled: root.reachable
              opacity: enabled ? 1.0 : 0.35
              onClicked: root.searchActive ? root.cancelSearch() : root.openSearch()
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

          // ---- Search field ------------------------------------------------

          TextField {
            id: searchField
            width: parent.width
            visible: root.searchActive
            height: visible ? implicitHeight : 0
            placeholderText: "Filter by name, service, project, or image"
            foreground: root.contentForeground
            accent: Color.accent
            font.family: root.contentFontFamily

            onTextChanged: {
              root.query = text
              root.resetCursor()
            }

            Keys.onEscapePressed: function (event) {
              root.cancelSearch()
              event.accepted = true
            }
            Keys.onReturnPressed: function (event) {
              root.commitSearch()
              event.accepted = true
            }
            Keys.onEnterPressed: function (event) {
              root.commitSearch()
              event.accepted = true
            }
            // Down from the field moves straight into the list without
            // needing Enter first.
            Keys.onDownPressed: function (event) {
              root.commitSearch()
              event.accepted = true
            }
          }

          // ---- Keyboard shortcuts ------------------------------------------

          Column {
            width: parent.width
            visible: root.helpOpen
            spacing: Style.space(3)

            Repeater {
              model: Model.keyHelp

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(10)

                Text {
                  width: Style.space(74)
                  horizontalAlignment: Text.AlignRight
                  text: modelData.keys
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }

                Text {
                  text: modelData.what
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }

          // ---- Status filter chips -----------------------------------------

          Row {
            width: parent.width
            spacing: Style.space(5)
            visible: root.reachable && root.hasContainers

            Repeater {
              model: Model.statusFilters

              Button {
                required property string modelData
                readonly property int count: root.counts ? (root.counts[modelData] || 0) : 0

                // The count makes each chip informative rather than just a
                // control: the numbers always add up to what clicking produces.
                text: Model.statusFilterLabel(modelData) + "  " + count
                selected: root.statusFilter === modelData
                foreground: modelData === "problems" && count > 0
                  ? Color.urgent : root.contentForeground
                accent: modelData === "problems" && count > 0 ? Color.urgent : Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                // An empty bucket stays clickable so its empty state can
                // explain itself, but reads as unremarkable.
                opacity: count > 0 || root.statusFilter === modelData ? 1.0 : 0.45
                onClicked: root.setStatusFilter(modelData)
              }
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

          // ---- Empty states ------------------------------------------------

          Text {
            width: parent.width
            visible: root.reachable && !root.probing
              && root.flatContainers.length === 0
            text: {
              if (!root.hasContainers) return "No containers yet."
              if (root.query !== "") return "Nothing matches “" + root.query + "”."
              if (root.statusFilter === "problems") return "Nothing is broken."
              if (root.statusFilter === "running") return "Nothing is running."
              if (root.statusFilter === "stopped") return "Nothing is stopped."
              return "No containers to show."
            }
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          // ---- Groups ------------------------------------------------------

          Repeater {
            model: root.groups

            Column {
              required property var modelData

              width: content.width
              spacing: Style.space(4)

              Item {
                id: groupBar
                width: parent.width
                height: groupHeader.implicitHeight

                readonly property var project: modelData.project
                readonly property bool standalone: modelData.standalone
                readonly property var stats: Model.groupStats(root.allContainers, modelData.project)
                readonly property string busyVerb: root.kaj && !modelData.standalone
                  ? root.kaj.busyAction(root.kaj.composeBusyKey(modelData.project)) : ""

                // Same rule as the container rows: project actions appear when
                // the group is hovered, not permanently.
                MouseArea {
                  id: groupHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelSectionHeader {
                  id: groupHeader
                  anchors.left: parent.left
                  anchors.right: composeRow.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  // Compose project name, or a plain label for the containers
                  // that belong to no project.
                  text: groupBar.standalone
                    ? "CONTAINERS"
                    : (groupBar.project + "  ·  "
                       + (groupBar.busyVerb !== ""
                          ? Model.composeBusyLabel(groupBar.busyVerb)
                          : groupBar.stats.running + "/" + groupBar.stats.total))
                  foreground: groupBar.busyVerb !== ""
                    ? Color.accent
                    : (groupBar.stats.severity === "error" ? Color.urgent : root.contentForeground)
                  fontFamily: root.contentFontFamily
                  elide: Text.ElideRight
                }

                // Whole-project actions, run through docker compose rather than
                // by fanning out per-container commands: compose owns networks
                // and dependency order, which a loop over containers does not.
                Row {
                  id: composeRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  visible: !groupBar.standalone && !root.readOnly
                  opacity: groupHover.containsMouse || groupBar.busyVerb !== "" ? 1 : 0
                  enabled: opacity > 0
                  Behavior on opacity { NumberAnimation { duration: 90 } }

                  Repeater {
                    model: ["start", "stop", "restart", "down"]

                    PanelActionButton {
                      required property string modelData

                      readonly property bool destructive: modelData === "down"
                      iconText: {
                        switch (modelData) {
                          case "start": return "󰐊"
                          case "stop": return "󰓛"
                          case "restart": return "󰑐"
                          default: return "󰹩"
                        }
                      }
                      tooltipText: "docker compose " + modelData
                      enabled: groupBar.busyVerb === ""
                      opacity: enabled ? 1.0 : 0.35
                      foreground: destructive ? Color.urgent : root.dim
                      hoverColor: destructive ? Color.urgent : Color.accent
                      fontFamily: root.contentFontFamily
                      fontSize: Style.font.caption
                      onClicked: root.requestCompose(groupBar.project, modelData, groupBar.stats)
                    }
                  }
                }
              }

              Repeater {
                model: modelData.containers

                ContainerRow {
                  id: containerRow
                  required property var modelData

                  width: content.width
                  // Only the id comes from the cached row list; the data is
                  // looked up live so a stable list still shows fresh state.
                  container: root.kaj ? root.kaj.containerById(modelData.id) : null
                  stats: root.kaj && container ? root.kaj.statsFor(container) : null
                  kaj: root.kaj
                  now: root.nowMs
                  expanded: root.expandedId === modelData.id
                  env: root.kaj && root.expandedId === modelData.id
                    ? root.kaj.envById[modelData.id] || null : null
                  revealed: root.revealedKeys
                  onToggleExpandRequested: root.toggleExpanded(container)
                  onRevealToggled: function (key) { root.toggleReveal(key) }
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  showStats: root.showStats
                  readOnly: root.readOnly
                  busyVerb: root.kaj ? root.kaj.busyAction(modelData.id) : ""
                  hasCursor: root.cursorContainer
                    && root.cursorContainer.id === modelData.id

                  onHasCursorChanged: if (hasCursor) root.ensureVisible(containerRow)
                  onActionRequested: function (action) { root.requestAction(action, container) }
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
    // Takes focus for as long as the dialog is open and hands every key to it.
    // ConfirmDialog has no key handling of its own — it exposes handleKey and
    // expects the host to call it, which is how the first-party panels drive it.
    Item {
      id: confirmKeys
      anchors.fill: parent
      z: 11
      focus: confirm.opened
      visible: confirm.opened

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        if (!confirm.opened) return
        // h/j/k/l reach the dialog as plain letters, so they are translated to
        // the left/right the dialog understands. Anything the dialog does not
        // claim is swallowed rather than passed down, so no keystroke leaks
        // through to the list while a confirmation is pending.
        if (event.text === "h" || event.text === "l"
            || event.text === "j" || event.text === "k") {
          confirm.selectedIndex = confirm.selectedIndex === 0 ? 1 : 0
          event.accepted = true
          return
        }
        confirm.handleKey(event)
        event.accepted = true
      }
    }

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
