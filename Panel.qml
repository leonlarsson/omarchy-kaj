import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kaj's panel: containers grouped by Compose project.
// PanelKeyCatcher claims h/j/k/l, x, Esc, Tab, Enter and Space, and forwards the
// rest as textKey. Search is opened with Ctrl+F or "/", never by typing into the
// list, so single-letter action keys stay free. While the field has focus the
// catcher is blocked, so the two modes never fight over a key.
Panel {
  id: root
  moduleName: "mozzy.kaj"
  // Gives omarchy-shell mozzy.kaj toggle, so the panel can be bound to a key.
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
  readonly property bool notifyOnContainerExit: kaj ? kaj.notifyOnContainerExit === true : false
  readonly property bool showResourceUsage: kaj ? kaj.showResourceUsage === true : true
  readonly property bool installed: kaj ? kaj.dockerInstalled === true : false
  readonly property bool reachable: kaj ? kaj.daemonReachable === true : false
  // No service at all: it failed to load, which is not the same as probing.
  // Left as probing, the panel waited forever and showed nothing.
  readonly property bool serviceMissing: !kaj
  readonly property bool probing: kaj ? kaj.probing === true : false
  readonly property bool hasContainers: kaj ? kaj.totalCount > 0 : false

  // ---- Filter and search state ---------------------------------------------

  property string query: ""
  property bool searchActive: false
  property string statusFilter: "all"
  property string view: "containers"

  function setView(next) {
    if (view === next) return
    view = next
    resetCursor()
    query = ""
    searchField.text = ""
    searchActive = false
    keyCatcher.forceActiveFocus()
    if (kaj) {
      loadFor(next)
    }
  }

  // The refresh button means this view again. Containers stream themselves.
  // Every other view is a snapshot taken when it was opened.
  function loadFor(next) {
    if (!kaj) return
    if (next === "images") kaj.loadImages()
    else if (next === "volumes") kaj.loadVolumes()
    else if (next === "networks") kaj.loadNetworks()
    else if (next === "disk") kaj.loadDisk()
  }

  // About one row per press.
  function scrollBy(delta) {
    panelFlick.contentY = Model.scrollTarget(panelFlick.contentY, delta,
      Style.space(46), panelFlick.contentHeight, panelFlick.height)
  }

  function stepView(delta) {
    var index = Model.views.indexOf(view)
    if (index < 0) index = 0
    var next = index + delta
    if (next < 0) next = Model.views.length - 1
    if (next >= Model.views.length) next = 0
    setView(Model.views[next])
  }

  readonly property var allContainers: kaj ? kaj.containers : []
  readonly property var counts: Model.statusCounts(allContainers, query)
  // Replaced only when the set or order of rows changes. See Model.groupsKey.
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
  // The flat sequence the keyboard walks.
  readonly property var flatContainers: Model.flattenGroups(groups)
  readonly property bool filtering: query !== "" || statusFilter !== "all"

  // ---- Keyboard cursor -----------------------------------------------------

  property int cursorIndex: -1
  // The cursor stays hidden until a key is pressed.
  property bool cursorActive: false
  // Tracked by id, not position: an event can rebuild the list under the cursor.
  property string cursorId: ""

  // The cached list gives the id. The container is looked up live.
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

  // h and l come from the key catcher and would otherwise go unused.
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

  // Also drops the scroll. Every caller changes what the list contains.
  // A refresh does not come through here, so it keeps its place.
  function resetCursor() {
    cursorIndex = -1
    cursorId = ""
    cursorActive = false
    panelFlick.contentY = 0
  }

  // ---- Search --------------------------------------------------------------

  function openSearch() {
    searchActive = true
    Qt.callLater(function () { searchField.forceActiveFocus() })
  }

  // Esc clears and leaves. The query is not worth keeping through a cancel.
  function cancelSearch() {
    query = ""
    searchField.text = ""
    searchActive = false
    resetCursor()
    keyCatcher.forceActiveFocus()
  }

  // Enter keeps the query but hands focus back, so j/k drive the narrowed list.
  function commitSearch() {
    keyCatcher.forceActiveFocus()
    if (flatContainers.length > 0) {
      cursorActive = true
      cursorIndex = 0
      cursorId = flatContainers[0].id
    }
  }

  // ---- Actions -------------------------------------------------------------

  // The one place a container action enters the panel. Destructive verbs wait for
  // a confirm. Everything else runs at once.
  function requestAction(action, container) {
    if (!kaj || !container) return
    // Every refusal is decided here and reported the same way.
    var reason = Model.unavailableReason(action, container, root.readOnly)
    if (reason !== "") { flash(reason); return }
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
    var reason = Model.unavailableReason("remove", container, root.readOnly)
    if (reason !== "") { flash(reason); return }
    requestAction("remove", container)
  }

  function handleTextKey(text) {
    // Covers "/" and Ctrl+F. See Model.isSearchKey.
    if (Model.isSearchKey(text)) { openSearch(); return }
    if (text === "?") { helpOpen = !helpOpen; return }
    if (text === "e") { toggleExpanded(cursorContainer); return }
    // The status filter belongs to the container list, so it gets its own key.
    if (text === "f") { if (view === "containers") stepFilter(1); return }
    var container = cursorContainer
    if (!container) return
    var action = Model.intendedAction(text, container)
    if (action === "") return
    requestAction(action, container)
  }

  // Pending destructive action, held while the dialog is up.
  property string pendingAction: ""
  property var pendingContainer: null

  function clearPending() {
    pendingAction = ""
    pendingContainer = null
    pendingCompose = ""
    // Hand keyboard control back to the list.
    if (opened) keyCatcher.forceActiveFocus()
  }

  // A keystroke that cannot act must say so. Silence looks like a broken key.
  property string notice: ""
  property bool helpOpen: false
  // Only one row is expanded at a time.
  property string expandedId: ""
  // Reveals live here, not in the row: rows are recreated on every refresh.
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

  // Uptime comes from a fixed startedAt, so the row needs a clock to age.
  // It ticks only while the panel is open.
  property double nowMs: Date.now()

  Timer {
    running: root.opened
    interval: 1000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // Every open starts from the configured filter, with no stale query or cursor.
  onOpenedChanged: {
    if (opened) {
      view = "containers"
      statusFilter = kaj ? kaj.defaultContainerStatusFilter : "all"
      keyCatcher.forceActiveFocus()
      query = ""
      searchField.text = ""
      searchActive = false
      helpOpen = false
      resetCursor()
    } else {
      searchActive = false
      // Collapse on close and drop the fetched values. Reopening must never show an
      // environment read some time ago.
      if (kaj && expandedId !== "") kaj.forgetEnv(expandedId)
      expandedId = ""
      revealedKeys = ({})
      helpOpen = false
    }
  }

  // Ctrl+F as a real shortcut. Gated on opened so it cannot fire when closed.

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
    // The pinned rows always show in full. Only the list scrolls.
    contentHeight: panel.fittedContentHeight(pinnedTop.implicitHeight
      + content.implicitHeight + pinnedBottom.implicitHeight + Style.space(20))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the field has focus every key belongs to it, including j and x.
      // While the dialog is up it owns every key.
      blocked: (root.searchActive && searchField.activeFocus) || confirm.opened

      onCloseRequested: {
        if (root.helpOpen) root.helpOpen = false
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        // Left and right always step the view. The filter has its own key.
        if (dx !== 0) { root.stepView(dx); return }
        if (dy === 0) return
        // Down and up move the cursor where there is something to select, and scroll
        // where there is not. Volumes and Networks have no actions.
        if (root.view === "containers") root.moveCursorBy(dy)
        else root.scrollBy(dy)
      }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.removeCursor()
      onTextKey: function (text) { root.handleTextKey(text) }

      // Only the list scrolls. The header, tabs and filter row are how you navigate,
      // and a long list used to carry them off the top. The error line is pinned too.
      Column {
        id: pinnedTop
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
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
            textFormat: Text.PlainText
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(36) - helpButton.width - searchButton.width
              - lockButton.width - bellButton.width - refreshButton.width - Style.space(74)
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

              // Read-only changes what every button does, so the header states it.
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.readOnly
                width: readOnlyBadge.implicitWidth + Style.space(10)
                height: readOnlyBadge.implicitHeight + Style.space(3)
                radius: Style.cornerRadius
                color: Util.alpha(root.contentForeground, 0.1)

                Row {
                  id: readOnlyBadge
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  // The lock reads at a glance. The word stays, because an icon alone is a guess.
                  Text {
                    text: "󰌾"
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }

                  Text {
                    text: "READ-ONLY"
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                }
              }
            }

            Text {
              width: parent.width
              // The subtitle doubles as the notice line. A message under a scrolling list is
              // never seen.
              text: {
                if (root.notice !== "") return root.notice
                if (!root.kaj) return ""
                if (!root.reachable) return root.kaj.summary
                // While filtering, the honest summary is what is on screen versus what exists.
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

          // Read-only is reachable from the panel, because a setting nobody can find is a
          // setting nobody uses. The click writes shell.json, so the lock survives a restart.
          PanelActionButton {
            id: lockButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.readOnly ? "󰌾" : "󰌿"
            tooltipText: root.readOnly
              ? "Read-only mode is on. Click to allow actions again"
              : "Read-only mode is off. Click to disable every action that changes a container"
            foreground: root.readOnly ? Color.accent : root.contentForeground
            hoverColor: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: if (root.kaj) root.kaj.writeSetting("readOnly", !root.readOnly)
          }

          PanelActionButton {
            id: bellButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.notifyOnContainerExit ? "󰂚" : "󰂛"
            tooltipText: root.notifyOnContainerExit
              ? "Notifications are on. Click to stop them"
              : "Notifications are off. Click to be told when a container fails"
            foreground: root.notifyOnContainerExit ? Color.accent : root.contentForeground
            hoverColor: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: if (root.kaj) root.kaj.writeSetting("notifyOnContainerExit", !root.notifyOnContainerExit)
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
            onClicked: {
              if (!root.kaj) return
              root.kaj.refresh()
              root.loadFor(root.view)
            }
          }
        }

        // ---- Search field ------------------------------------------------

        TextField {
          id: searchField
          width: parent.width
          visible: root.searchActive
          // Disabled when hidden so it cannot hold focus. A focused invisible field made
          // every keystroke count twice.
          enabled: root.searchActive
          height: visible ? implicitHeight : 0
          placeholderText: "Filter by name, service, project, or image"
          foreground: root.contentForeground
          accent: Color.accent
          font.family: root.contentFontFamily

          onTextChanged: {
            if (!root.searchActive) return
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
          // Down from the field moves into the list without needing Enter.
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

        // ---- View tabs ---------------------------------------------------

        Row {
          width: parent.width
          spacing: Style.space(4)
          visible: root.reachable

          Repeater {
            model: Model.views

            Button {
              required property string modelData

              text: Model.viewLabel(modelData)
              selected: root.view === modelData
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: root.setView(modelData)
            }
          }
        }

        // ---- Status filter chips -----------------------------------------

        Row {
          width: parent.width
          spacing: Style.space(5)
          visible: root.reachable && root.hasContainers && root.view === "containers"

          Repeater {
            model: Model.statusFilters

            Button {
              required property string modelData
              readonly property int count: root.counts ? (root.counts[modelData] || 0) : 0

              // The count makes each chip informative, and the numbers match what a click gives.
              text: Model.statusFilterLabel(modelData) + "  " + count
              selected: root.statusFilter === modelData
              foreground: modelData === "problems" && count > 0
                ? Color.urgent : root.contentForeground
              accent: modelData === "problems" && count > 0 ? Color.urgent : Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              // An empty bucket stays clickable so its empty state can explain itself.
              opacity: count > 0 || root.statusFilter === modelData ? 1.0 : 0.45
              onClicked: root.setStatusFilter(modelData)
            }
          }
        }

        PanelSeparator { width: parent.width }
      }

      Column {
        id: pinnedBottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

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

      Flickable {
        id: panelFlick
        anchors.top: pinnedTop.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: pinnedBottom.top
        anchors.left: parent.left
        anchors.right: parent.right
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

          // ---- Degraded states ---------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.serviceMissing

            Text {
              width: parent.width
              text: "Kaj failed to load"
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }

            Text {
              width: parent.width
              text: "See the error with: journalctl --user -b | grep mozzy.kaj"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }
          }

          // Docker missing or unreachable is the whole state of the panel, so it takes
          // the whole panel.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.probing && !root.serviceMissing && (!root.installed || !root.reachable)

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

            // Not a button. Starting a daemon is privileged, so Kaj hands over a command
            // rather than escalating from a bar popup.
          }

          // ---- Empty states ------------------------------------------------

          Text {
            width: parent.width
            visible: root.reachable && !root.probing && root.view === "containers"
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
            model: root.view === "containers" ? root.groups : []

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

                // Project actions appear when the group is hovered, like the container rows.
                HoverHandler {
                  id: groupHover
                }

                PanelSectionHeader {
                  id: groupHeader
                  anchors.left: parent.left
                  anchors.right: composeRow.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  // Compose project name, or a label for containers that belong to no project.
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

                // Whole-project actions run through docker compose, which owns the network and
                // the dependency order.
                Row {
                  id: composeRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  visible: !groupBar.standalone && !root.readOnly
                  opacity: groupHover.hovered || groupBar.busyVerb !== "" ? 1 : 0
                  enabled: groupHover.hovered || groupBar.busyVerb !== ""
            
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
                  // Only the id comes from the cached list. The data is looked up live.
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
                  showResourceUsage: root.showResourceUsage
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

          // ---- Images ------------------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: root.view === "images" && root.reachable

            Text {
              width: parent.width
              visible: root.kaj && root.kaj.images.length === 0
              text: root.kaj && root.kaj.loadingImages ? "Loading…" : "No images."
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }

            Repeater {
              model: root.view === "images" && root.kaj
                ? Model.filterImages(root.kaj.images, root.query) : []

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: parent.width - sizeText.width - Style.space(8)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: modelData.name
                    // A dangling image has no name worth trusting, so it reads as muted.
                    color: modelData.dangling ? root.dim : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }

                  Text {
                    width: parent.width
                    // Whether anything uses it is the only question worth answering here.
                    text: modelData.id + "  ·  " + modelData.created
                      + (modelData.containers === 0
                         ? "  ·  unused"
                         : "  ·  " + modelData.containers
                           + (modelData.containers === 1 ? " container" : " containers"))
                    color: modelData.containers === 0 ? Color.accent : root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                }

                Text {
                  id: sizeText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(62)
                  horizontalAlignment: Text.AlignRight
                  text: Model.formatBytes(modelData.size)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }

          // ---- Volumes -----------------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.view === "volumes" && root.reachable

            Text {
              width: parent.width
              visible: root.kaj && root.kaj.volumes.length === 0
              text: root.kaj && root.kaj.loadingVolumes ? "Loading…" : "No volumes."
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }

            Repeater {
              model: root.view === "volumes" && root.kaj
                ? Model.filterByName(root.kaj.volumes, root.query) : []

              Row {
                required property var modelData
                readonly property var users: root.kaj
                  ? Model.volumeUsers(root.kaj.containers, modelData.name) : []

                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: parent.width - volumeSize.width - Style.space(8)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }

                  Text {
                    width: parent.width
                    // What is using it. docker volume ls cannot answer this.
                    text: (modelData.project === "" ? "" : modelData.project + "  ·  ")
                      + Model.usageLabel(parent.parent.users)
                    color: parent.parent.users.length === 0 ? Color.accent : root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                }

                Text {
                  id: volumeSize
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(62)
                  horizontalAlignment: Text.AlignRight
                  text: Model.formatBytes(modelData.size)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }

          // ---- Networks ----------------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.view === "networks" && root.reachable

            Text {
              width: parent.width
              visible: root.kaj && root.kaj.networks.length === 0
              text: root.kaj && root.kaj.loadingNetworks ? "Loading…" : "No networks."
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }

            Repeater {
              model: root.view === "networks" && root.kaj
                ? Model.filterByName(root.kaj.networks, root.query) : []

              Row {
                required property var modelData
                readonly property var members: root.kaj
                  ? Model.networkMembers(root.kaj.containers, modelData.name) : []

                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: parent.width - networkDriver.width - Style.space(8)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: modelData.name
                    // The three built-in networks are context, not findings.
                    color: modelData.builtin ? root.dim : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }

                  Text {
                    width: parent.width
                    text: (modelData.subnet === "" ? "" : modelData.subnet + "  ·  ")
                      + Model.usageLabel(parent.parent.members)
                      + (modelData.internal ? "  ·  internal" : "")
                    color: parent.parent.members.length === 0 && !modelData.builtin
                      ? Color.accent : root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                }

                Text {
                  id: networkDriver
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(62)
                  horizontalAlignment: Text.AlignRight
                  text: modelData.driver
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }

          // ---- Disk --------------------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(5)
            visible: root.view === "disk" && root.reachable

            Repeater {
              model: root.view === "disk" && root.kaj ? root.kaj.disk : []

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: parent.width - Style.space(156)
                  spacing: Style.space(1)

                  Text {
                    text: modelData.type
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    textFormat: Text.PlainText
                  }

                  Text {
                    text: modelData.active + " of " + modelData.total + " in use"
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(66)
                  horizontalAlignment: Text.AlignRight
                  text: Model.formatBytes(modelData.size)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(66)
                  horizontalAlignment: Text.AlignRight
                  // Reclaimable is the number people act on, so it gets the accent.
                  text: modelData.reclaimable > 0
                    ? Model.formatBytes(modelData.reclaimable) + " free"
                    : "—"
                  color: modelData.reclaimable > 0 ? Color.accent : root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.view === "disk" && root.reachable && root.kaj
              && Model.totalReclaimable(root.kaj.disk) > 0
            text: root.kaj
              ? Model.formatBytes(Model.totalReclaimable(root.kaj.disk)) + " can be reclaimed"
              : ""
            color: Color.accent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
        }
      }
    }

    // The gate in front of every destructive verb. It lives inside the panel surface:
    // the Panel root is a zero-sized Item, so a dialog anchored there never appears.
    // ConfirmDialog exposes handleKey and expects the host to call it.
    Item {
      id: confirmKeys
      anchors.fill: parent
      z: 11
      focus: confirm.opened
      visible: confirm.opened

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        if (!confirm.opened) return
        // h/j/k/l reach the dialog as letters, so they are translated to left and right.
        // Anything else is swallowed, so no key leaks through to the list.
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
