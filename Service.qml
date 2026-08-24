import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Kaj's engine. Owns every conversation with the Docker daemon and exposes the
// result as plain properties for the UI to bind against.
//
// Two invariants hold everywhere in this file, and they are the reason the
// plugin can be trusted with a root-equivalent socket:
//
//   1. Every command is an argv array. There is no bash -c, no string
//      concatenation into a shell, and no interpolation of a container name,
//      image tag, or label into a command line. Container metadata is written
//      by whoever built the image; treating it as code would hand them the
//      Docker socket, and the Docker socket is root.
//   2. Nothing mutates without going through runAction(), which refuses while
//      read-only mode is on and which the UI gates behind a confirm for the
//      destructive verbs listed in Model.isDestructive().
Item {
  id: root

  property var shell: null
  property var manifest: null
  // Pushed in by BarWidget.qml, which is where the shell delivers widget
  // settings. Defaults mirror manifest.json so the service is usable before
  // the widget mounts.
  property var settings: ({})

  // ---- Daemon reachability -------------------------------------------------
  property bool dockerInstalled: false
  property bool daemonReachable: false
  property string daemonError: ""
  property bool probing: true

  // ---- Container state -----------------------------------------------------
  property var containers: []
  property var groups: []
  property var statsById: ({})
  property string severity: "ok"
  property int runningCount: 0
  property int totalCount: 0
  property string lastError: ""
  property string busyContainerId: ""

  readonly property bool readOnly: setting("readOnly", false) === true
  readonly property bool showStats: setting("showStats", true) === true
  readonly property bool hideStopped: setting("hideStopped", false) === true
  readonly property bool notifyOnExit: setting("notifyOnExit", true) === true
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int logLines: intSetting("logLines", 500, 50, 5000)
  readonly property string summary: dockerInstalled
    ? (daemonReachable ? Model.barSummary(containers) : "Docker daemon not running")
    : "Docker not installed"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function containerById(id) {
    for (var i = 0; i < containers.length; i++) {
      if (containers[i].id === id) return containers[i]
    }
    return null
  }

  function statsFor(container) {
    if (!container) return null
    return statsById[container.shortId] || null
  }

  // ---- Lifecycle -----------------------------------------------------------

  Component.onCompleted: probe()

  function probe() {
    probing = true
    whichProcess.command = ["which", "docker"]
    whichProcess.running = true
  }

  // Reachability is a separate question from installation: the binary can be
  // present while the daemon is stopped or the user is not in the docker group.
  function checkDaemon() {
    if (!dockerInstalled) return
    if (pingProcess.running) return
    pingProcess.command = ["docker", "version", "--format", "{{.Server.Version}}"]
    pingProcess.running = true
  }

  // Snapshot is two processes rather than one, on purpose. Getting the ids and
  // inspecting them in a single call would need `docker inspect $(docker ps
  // -aq)`, and that needs a shell. Two argv-only processes cost one extra fork
  // and keep the no-shell invariant absolute.
  function refresh() {
    if (!dockerInstalled || !daemonReachable) return
    if (idsProcess.running || inspectProcess.running) return
    idsProcess.command = ["docker", "ps", "-a", "--no-trunc", "--quiet"]
    idsProcess.running = true
  }

  property var _pendingIds: []
  property string _idsBuffer: ""
  property string _inspectBuffer: ""

  function inspectIds(ids) {
    if (!Array.isArray(ids) || ids.length === 0) {
      applyContainers([])
      return
    }
    // Ids come from the daemon and are hex digests, but they are still appended
    // as separate argv entries rather than joined into a string.
    var command = ["docker", "inspect", "--type", "container", "--format", inspectFormat]
    for (var i = 0; i < ids.length; i++) command.push(ids[i])
    _inspectBuffer = ""
    inspectProcess.command = command
    inspectProcess.running = true
  }

  // Each {{json ...}} is encoded by Go, and every key is a literal we wrote, so
  // no container-controlled text can break out of the JSON structure. This is
  // the safe alternative to hand-building JSON in a Go template.
  readonly property string inspectFormat: '{"Id":{{json .Id}},"Name":{{json .Name}},"Created":{{json .Created}},"State":{{json .State}},"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}},"Ports":{{json .NetworkSettings.Ports}},"RestartCount":{{json .RestartCount}}}'

  // Counts and severity are computed from the full list even when the panel is
  // hiding stopped containers, so the bar never under-reports a problem just
  // because the list is filtered.
  function applyContainers(list) {
    containers = list
    groups = Model.groupByProject(Model.visibleContainers(list, hideStopped))
    severity = Model.rollupSeverity(list)
    runningCount = Model.countRunning(list)
    totalCount = list.length
    probing = false
  }

  onHideStoppedChanged: applyContainers(containers)

  // ---- Actions -------------------------------------------------------------

  // The single mutation entry point. Every button in the UI routes here.
  function runAction(action, container) {
    if (!container || !daemonReachable) return
    if (readOnly) {
      lastError = "Read-only mode is on"
      return
    }
    if (actionProcess.running) return

    var command = commandFor(action, container)
    if (!command) return

    busyContainerId = container.id
    lastError = ""
    actionProcess.command = command
    actionProcess.running = true
  }

  // Maps a verb to argv. The container id is always passed as its own argv
  // entry; it is never formatted into a string.
  function commandFor(action, container) {
    var id = container.id
    if (id === "") return null
    switch (action) {
      case "start": return ["docker", "start", id]
      case "stop": return ["docker", "stop", id]
      case "restart": return ["docker", "restart", id]
      case "pause": return ["docker", "pause", id]
      case "unpause": return ["docker", "unpause", id]
      case "remove": return ["docker", "rm", id]
      case "removeVolumes": return ["docker", "rm", "--volumes", id]
      default: return null
    }
  }

  // Logs and shells open in a terminal rather than in the panel. A bar popup is
  // the wrong place to hold a long-lived interactive session, and handing the
  // stream to a real terminal means Kaj never has to render attacker-controlled
  // bytes as rich text.
  function openLogs(container) {
    if (!container) return
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "docker", "logs", "--follow", "--tail", String(logLines), container.id
    ])
  }

  function openShell(container) {
    if (!container || !container.running) return
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "docker", "exec", "--interactive", "--tty", container.id, "sh"
    ])
  }

  function openPort(url) {
    if (!url || url === "") return
    Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  function copyText(text) {
    // The value goes over stdin, never argv. Copying a container's environment
    // value is the one place Kaj handles a secret directly, and an argv entry
    // would expose it to every process that can read /proc.
    if (copyProcess.running) return
    copyProcess.pending = String(text === undefined || text === null ? "" : text)
    copyProcess.command = ["wl-copy"]
    copyProcess.running = true
  }

  function notify(title, body, urgency) {
    Quickshell.execDetached([
      "notify-send", "--app-name", "Kaj",
      "--urgency", urgency || "normal",
      String(title || ""), String(body || "")
    ])
  }

  // ---- Processes -----------------------------------------------------------

  Process {
    id: whichProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.dockerInstalled = String(text || "").trim() !== ""
        if (root.dockerInstalled) root.checkDaemon()
        else root.probing = false
      }
    }
  }

  // Reachability is decided by the exit code in onExited, never by either
  // stream handler on its own. Both stdout and stderr finish on every run —
  // including when one of them is empty — so a stderr handler that concluded
  // "unreachable" would clobber a successful probe a moment after stdout had
  // already reported success.
  Process {
    id: pingProcess
    property string version: ""
    property string failure: ""
    running: false

    stdout: StdioCollector {
      onStreamFinished: pingProcess.version = String(text || "").trim()
    }
    stderr: StdioCollector {
      onStreamFinished: pingProcess.failure = Model.sanitizeLine(text, 300)
    }

    onExited: function (exitCode) {
      var reachable = exitCode === 0 && pingProcess.version !== ""
      var became = reachable && !root.daemonReachable
      root.daemonReachable = reachable
      root.probing = false

      if (reachable) {
        root.daemonError = ""
        root.refresh()
        if (became) root.startStreams()
      } else {
        // A daemon that is down reports it on stderr; keep that text, because
        // "permission denied on the socket" and "daemon not running" need very
        // different fixes from the person reading the panel.
        root.daemonError = pingProcess.failure !== ""
          ? pingProcess.failure
          : "Could not reach the Docker daemon"
      }

      pingProcess.version = ""
      pingProcess.failure = ""
    }
  }

  Process {
    id: idsProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var ids = String(text || "").split("\n").filter(function (line) {
          // Accept only what a container id can actually be. A daemon that
          // returned something else is a daemon we do not talk to.
          return /^[0-9a-f]{12,64}$/.test(line.trim())
        }).map(function (line) { return line.trim() })
        root.inspectIds(ids)
      }
    }
  }

  Process {
    id: inspectProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.applyContainers(Model.normalizeContainers(Model.parseJsonLines(text)))
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = Model.sanitizeLine(text, 300)
        if (message !== "") root.lastError = message
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    onExited: function (exitCode) {
      root.busyContainerId = ""
      // The event stream will report the real state change; this is only a
      // nudge so a no-op action still settles the UI.
      root.refresh()
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = Model.sanitizeLine(text, 300)
        if (message !== "") root.lastError = message
      }
    }
  }

  Process {
    id: copyProcess
    property string pending: ""
    running: false
    stdinEnabled: true
    onStarted: {
      write(pending)
      pending = ""
      stdinEnabled = false
    }
  }

  // ---- Live streams --------------------------------------------------------

  // Kaj is event-driven, not poll-driven: `docker events` pushes state changes
  // the instant they happen, so the panel is correct without a timer hammering
  // the daemon. The reconcile timer below is only a safety net.
  function startStreams() {
    if (!daemonReachable) return
    if (!eventsProcess.running) {
      eventsProcess.command = ["docker", "events", "--format", "{{json .}}"]
      eventsProcess.running = true
    }
    syncStatsStream()
  }

  function syncStatsStream() {
    var want = daemonReachable && showStats
    if (want && !statsProcess.running) {
      statsProcess.command = ["docker", "stats", "--format", "{{json .}}"]
      statsProcess.running = true
    } else if (!want && statsProcess.running) {
      statsProcess.running = false
      statsById = ({})
    }
  }

  onShowStatsChanged: syncStatsStream()

  Process {
    id: eventsProcess
    running: false
    stdout: SplitParser {
      onRead: function (line) { root.handleEvent(line) }
    }
    onExited: function () {
      // The daemon restarting or the socket dropping ends the stream. Re-probe
      // rather than silently going stale.
      root.daemonReachable = false
      reconnectTimer.restart()
    }
  }

  Process {
    id: statsProcess
    running: false
    stdout: SplitParser {
      onRead: function (line) {
        var parsed = Model.parseJsonLines(line)
        for (var i = 0; i < parsed.length; i++) {
          root.statsById = Model.mergeStats(root.statsById, parsed[i])
        }
      }
    }
  }

  function handleEvent(line) {
    var events = Model.parseJsonLines(line)
    for (var i = 0; i < events.length; i++) {
      var event = events[i]
      if (!event || event.Type !== "container") continue
      var status = String(event.status || event.Action || "")
      if (notifyOnExit && status === "die") announceExit(event)
      // Anything that changes container state warrants a re-read. Refresh is
      // cheap and coalesced by the running-guard in refresh().
      refreshTimer.restart()
    }
  }

  // A container exiting non-zero, or being OOM-killed, is the one thing worth
  // interrupting someone for. Everything else stays in the panel.
  function announceExit(event) {
    var attributes = event.Actor && event.Actor.Attributes ? event.Actor.Attributes : {}
    var exitCode = parseInt(attributes.exitCode, 10)
    if (!isFinite(exitCode) || exitCode === 0) return
    var name = Model.sanitizeLine(attributes.name || Model.shortId(event.id), 80)
    notify("Container exited", name + " exited with code " + exitCode, "critical")
  }

  // ---- Timers --------------------------------------------------------------

  // Coalesces a burst of events (a compose up emits many) into one refresh.
  Timer {
    id: refreshTimer
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: reconnectTimer
    interval: 3000
    repeat: false
    onTriggered: root.checkDaemon()
  }

  // Safety net only. If an event is ever missed, this bounds how long the panel
  // can disagree with reality.
  Timer {
    interval: Math.max(5, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.daemonReachable
    onTriggered: root.refresh()
  }
}
