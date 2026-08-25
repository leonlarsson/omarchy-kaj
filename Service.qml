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
  property var statsById: ({})
  property string severity: "ok"
  property int runningCount: 0
  property int totalCount: 0
  property string lastError: ""

  readonly property bool readOnly: setting("readOnly", false) === true
  readonly property bool showStats: setting("showStats", true) === true
  readonly property string defaultFilter: String(setting("defaultFilter", "all"))
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
  readonly property string inspectFormat: '{"Id":{{json .Id}},"Name":{{json .Name}},"Created":{{json .Created}},"State":{{json .State}},"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}},"Ports":{{json .NetworkSettings.Ports}},"RestartCount":{{json .RestartCount}},"MemoryLimit":{{json .HostConfig.Memory}},"NanoCpus":{{json .HostConfig.NanoCpus}}}'

  // Counts and severity always come from the full list, never from whatever the
  // panel is currently filtered to, so the bar cannot under-report a problem
  // just because a filter is hiding it.
  function applyContainers(list) {
    // A snapshot that came back is proof the previous failure has passed, so
    // the error clears itself rather than sitting in the panel forever.
    lastError = ""
    containers = list
    severity = Model.rollupSeverity(list)
    runningCount = Model.countRunning(list)
    totalCount = list.length
    probing = false
  }


  // ---- Images and disk -----------------------------------------------------

  // Fetched when the view is opened and on explicit refresh, not streamed:
  // images and disk usage change on the scale of builds and pulls, so a live
  // subscription would cost two more processes to show numbers that rarely move.
  property var images: []
  property var disk: []
  property bool loadingImages: false

  function loadImages() {
    if (!daemonReachable || imagesProcess.running) return
    loadingImages = true
    imagesProcess.command = ["docker", "images", "--format", "{{json .}}"]
    imagesProcess.running = true
  }

  function loadDisk() {
    if (!daemonReachable || diskProcess.running) return
    diskProcess.command = ["docker", "system", "df", "--format", "{{json .}}"]
    diskProcess.running = true
  }

  Process {
    id: imagesProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.images = Model.normalizeImages(Model.parseJsonLines(text))
        root.loadingImages = false
      }
    }
  }

  Process {
    id: diskProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.disk = Model.normalizeDisk(Model.parseJsonLines(text))
    }
  }

  // ---- Environment ---------------------------------------------------------

  // Fetched only when a row is expanded, and dropped when it collapses. The
  // main snapshot deliberately does not carry Env: holding every container's
  // secrets in memory for the lifetime of the shell, to render them almost
  // never, is a poor trade.
  property var envById: ({})

  function loadEnv(container) {
    if (!container || envProcess.running) return
    envProcess.containerId = container.id
    envProcess.command = ["docker", "inspect", "--type", "container",
                          "--format", "{{json .Config.Env}}", container.id]
    envProcess.running = true
  }

  function forgetEnv(id) {
    var next = ({})
    for (var key in envById) if (key !== String(id)) next[key] = envById[key]
    envById = next
  }

  Process {
    id: envProcess
    property string containerId: ""
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var rows = Model.parseJsonLines(text)
        var next = ({})
        for (var key in root.envById) next[key] = root.envById[key]
        next[envProcess.containerId] = Model.envEntries(rows.length > 0 ? rows[0] : [])
        root.envById = next
      }
    }
  }

  // ---- Actions -------------------------------------------------------------

  // Which containers have an action in flight, as id -> verb. A map rather than
  // a single id because actions run in parallel: one shared process meant that
  // a `docker stop`, which waits ten seconds for SIGTERM before resorting to
  // SIGKILL, silently swallowed every click on every other container for the
  // whole of that wait.
  property var busyActions: ({})

  function busyAction(id) {
    var verb = busyActions[String(id)]
    return verb === undefined ? "" : verb
  }

  function setBusy(id, verb) {
    var next = ({})
    for (var key in busyActions) next[key] = busyActions[key]
    if (verb === "") delete next[String(id)]
    else next[String(id)] = verb
    busyActions = next
  }

  // Group actions share the per-target busy map, keyed by project rather than
  // container id, so a project mid-action disables its own header without
  // touching anything else.
  function composeBusyKey(project) { return "compose:" + project }

  function composeAction(project, verb) {
    if (!daemonReachable) return
    if (readOnly) { lastError = "Read-only mode is on"; return }
    var command = Model.composeCommand(project, verb)
    if (!command) return
    var key = composeBusyKey(project)
    if (busyAction(key) !== "") return

    lastError = ""
    // Every container in the project is about to stop because it was asked to.
    for (var i = 0; i < containers.length; i++) {
      if ((containers[i].project || "") === project) markSelfInitiated(containers[i].id)
    }

    var proc = actionComponent.createObject(root, {
      containerId: key, verb: verb, command: command
    })
    if (!proc) { lastError = "Could not run compose " + verb; return }
    setBusy(key, verb)
    proc.running = true
  }

  // The single mutation entry point. Every button in the UI routes here.
  function runAction(action, container) {
    if (!container || !daemonReachable) return
    if (readOnly) {
      lastError = "Read-only mode is on"
      return
    }
    // Serialised per container, parallel across them: two verbs racing on one
    // container is incoherent, but stopping one while starting another is not.
    if (busyAction(container.id) !== "") return

    var command = commandFor(action, container)
    if (!command) return

    lastError = ""
    // Stopping something on purpose must not notify the person who asked.
    if (action === "stop" || action === "restart" || action === "remove" || action === "removeVolumes") {
      markSelfInitiated(container.id)
    }

    var proc = actionComponent.createObject(root, {
      containerId: container.id,
      verb: action,
      command: command
    })
    if (!proc) {
      lastError = "Could not run " + action
      return
    }
    setBusy(container.id, action)
    proc.running = true
  }

  function finishAction(id, verb, failure) {
    setBusy(id, "")
    if (failure && failure !== "") lastError = failure
    // The event stream reports the real state change; this only settles the UI
    // when an action turned out to be a no-op and produced no event.
    refresh()
  }

  // One process per in-flight action, destroyed when it exits.
  Component {
    id: actionComponent

    Process {
      id: proc
      property string containerId: ""
      property string verb: ""
      property string failure: ""

      stderr: StdioCollector {
        onStreamFinished: proc.failure = Model.firstRealError(text)
      }

      onExited: function (exitCode) {
        root.finishAction(proc.containerId, proc.verb, exitCode === 0 ? "" : proc.failure)
        proc.destroy()
      }
    }
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

  // A shell is not an inspection. `docker exec` hands over a root prompt inside
  // the container, which can delete files, kill processes, and rewrite data —
  // more than any button on the row can do. Read-only refuses it for the same
  // reason it refuses `stop`. Logs, which really only read, stay open.
  function openShell(container) {
    if (!container || !container.running) return
    if (readOnly) { lastError = "Read-only mode is on"; return }
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "docker", "exec", "--interactive", "--tty", container.id, "sh"
    ])
  }

  // Read-only is a setting, so toggling it writes the setting rather than
  // holding a second copy of the truth in the panel. `omarchy bar set` owns
  // shell.json; --json keeps the value a real boolean, since without it the
  // string "false" would be written and read back as a value that is not
  // false. Kaj's own argv rule still holds: every word here is a literal.
  function setReadOnly(next) {
    Quickshell.execDetached([
      "omarchy", "bar", "set", "mozzy.kaj", "readOnly",
      next === true ? "true" : "false", "--json"
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
        // Containers removed between listing the ids and inspecting them are
        // expected; anything else is worth showing.
        var message = Model.firstRealError(text)
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
      if (notifyOnExit && status === "oom") announceOom(event)
      // Anything that changes container state warrants a re-read. Refresh is
      // cheap and coalesced by the running-guard in refresh().
      refreshTimer.restart()
    }
  }

  // Records a container Kaj itself just stopped or removed, so the die event
  // that follows does not get announced back to the person who asked for it.
  property var _selfInitiated: ({})

  function markSelfInitiated(id) {
    var next = ({})
    for (var key in _selfInitiated) next[key] = _selfInitiated[key]
    next[String(id)] = Date.now()
    _selfInitiated = next
  }

  function wasSelfInitiated(id) {
    var at = _selfInitiated[String(id)]
    // Only recent enough to be the same act. A container stopped through Kaj an
    // hour ago and crashing now deserves the notification.
    return at !== undefined && (Date.now() - at) < 15000
  }

  // A container that failed is worth interrupting someone for. A container that
  // did what it was told is not, and the difference is entirely in the exit
  // code: 143 is SIGTERM, which is exactly what `docker stop` sends, and 130 is
  // SIGINT. Treating those as failures would turn every ordinary stop into an
  // alert, which is the fastest way to teach someone to ignore the alerts.
  readonly property var quietExitCodes: [0, 130, 143]

  // A container in a restart loop dies every few seconds. Notifying on each one
  // buries the desktop in identical popups and makes the notification worthless
  // precisely when something is actually wrong, so each container gets one
  // notification per cooldown window no matter how often it flaps.
  property var _lastNotified: ({})
  readonly property int notifyCooldownMs: 60000

  function shouldNotify(id) {
    var key = String(id)
    var last = _lastNotified[key]
    if (last !== undefined && (Date.now() - last) < notifyCooldownMs) return false
    var next = ({})
    for (var existing in _lastNotified) next[existing] = _lastNotified[existing]
    next[key] = Date.now()
    _lastNotified = next
    return true
  }

  function announceExit(event) {
    var attributes = event.Actor && event.Actor.Attributes ? event.Actor.Attributes : {}
    var exitCode = parseInt(attributes.exitCode, 10)
    if (!isFinite(exitCode)) return
    if (quietExitCodes.indexOf(exitCode) !== -1) return
    if (wasSelfInitiated(event.id)) return
    if (!shouldNotify(event.id)) return

    var name = Model.sanitizeLine(attributes.name || Model.shortId(event.id), 80)
    // Normal urgency, so it behaves like a notification rather than a modal:
    // critical is sticky in most daemons and has to be dismissed by hand, which
    // is far too much ceremony for a container exiting.
    notify("Container exited", name + " exited with code " + exitCode, "normal")
  }

  // Out of memory is the one case that earns critical. It is rare, it is never
  // something the user asked for, and it is the failure people most often miss.
  function announceOom(event) {
    var attributes = event.Actor && event.Actor.Attributes ? event.Actor.Attributes : {}
    var name = Model.sanitizeLine(attributes.name || Model.shortId(event.id), 80)
    notify("Container out of memory", name + " was killed for exceeding its memory limit", "critical")
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
