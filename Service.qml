import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Kaj's engine. Talks to the Docker daemon and exposes the result as properties.
// Two rules hold everywhere in this file:
// 1. Every command is an argv array. No bash -c, no text from a container in a
//    command line. The Docker socket is root-equivalent.
// 2. Nothing mutates except through runAction(), which refuses in read-only mode.
Item {
  id: root

  property var shell: null
  property var manifest: null
  // Pushed in by BarWidget.qml. Defaults match manifest.json.
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

  // Types, defaults and limits all live in Model.settingsSchema.
  readonly property bool readOnly: Model.readSetting(settings, "readOnly")
  readonly property bool showStats: Model.readSetting(settings, "showStats")
  readonly property bool notifyOnExit: Model.readSetting(settings, "notifyOnExit")
  readonly property string defaultFilter: Model.readSetting(settings, "defaultFilter")
  readonly property int refreshIntervalSec: Model.readSetting(settings, "refreshIntervalSec")
  readonly property int logLines: Model.readSetting(settings, "logLines")
  readonly property string summary: dockerInstalled
    ? (daemonReachable ? Model.barSummary(containers) : "Docker daemon not running")
    : "Docker not installed"

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

  // Installed and reachable are different: the binary can be there while the
  // daemon is stopped or the user is not in the docker group.
  function checkDaemon() {
    if (!dockerInstalled) return
    if (pingProcess.running) return
    pingProcess.command = ["docker", "version", "--format", "{{.Server.Version}}"]
    pingProcess.running = true
  }

  // Two processes on purpose. One call would need docker inspect $(docker ps -aq),
  // and that needs a shell.
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
    // Ids are hex, but they are still passed as separate argv entries.
    var command = ["docker", "inspect", "--type", "container", "--format", inspectFormat]
    for (var i = 0; i < ids.length; i++) command.push(ids[i])
    _inspectBuffer = ""
    inspectProcess.command = command
    inspectProcess.running = true
  }

  // Go encodes each {{json ...}} and every key is a literal, so container text
  // cannot break out of the JSON.
  readonly property string inspectFormat: '{"Id":{{json .Id}},"Name":{{json .Name}},"Created":{{json .Created}},"State":{{json .State}},"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}},"Ports":{{json .NetworkSettings.Ports}},"RestartCount":{{json .RestartCount}},"MemoryLimit":{{json .HostConfig.Memory}},"NanoCpus":{{json .HostConfig.NanoCpus}},"Mounts":{{json .Mounts}},"Networks":{{json .NetworkSettings.Networks}}}'

  // Counts always come from the full list, never the filtered one, so the bar
  // cannot hide a problem.
  function applyContainers(list) {
    // A snapshot that arrived proves the last failure is over.
    lastError = ""
    containers = list
    severity = Model.rollupSeverity(list)
    runningCount = Model.countRunning(list)
    totalCount = list.length
    probing = false
  }


  // ---- Images and disk -----------------------------------------------------

  // Fetched when the view opens and on refresh, not streamed. These numbers
  // change on the scale of builds and pulls.
  property var images: []
  property var disk: []
  property var volumes: []
  property var networks: []
  property bool loadingImages: false
  property bool loadingVolumes: false
  property bool loadingNetworks: false

  function loadImages() {
    if (!daemonReachable || imagesProcess.running) return
    loadingImages = true
    imagesProcess.command = ["docker", "images", "--format", "{{json .}}"]
    imagesProcess.running = true
  }

  // docker system df -v, not docker volume ls, because only df reports size.
  function loadVolumes() {
    if (!daemonReachable || volumesProcess.running) return
    loadingVolumes = true
    volumesProcess.command = ["docker", "system", "df", "-v", "--format", "{{json .Volumes}}"]
    volumesProcess.running = true
  }

  // Two steps: docker network ls has no subnets, and inspect returns labels as an
  // object instead of a flat string.
  function loadNetworks() {
    if (!daemonReachable || networkIdsProcess.running || networksProcess.running) return
    loadingNetworks = true
    networkIdsProcess.command = ["docker", "network", "ls", "--quiet"]
    networkIdsProcess.running = true
  }

  function inspectNetworks(ids) {
    if (ids.length === 0) {
      networks = []
      loadingNetworks = false
      return
    }
    var command = ["docker", "network", "inspect"]
    for (var i = 0; i < ids.length; i++) command.push(ids[i])
    networksProcess.command = command
    networksProcess.running = true
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
    id: volumesProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.volumes = Model.normalizeVolumes(Model.parseJson(text))
        root.loadingVolumes = false
      }
    }
  }

  Process {
    id: networkIdsProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.inspectNetworks(Model.parseIds(text))
    }
  }

  Process {
    id: networksProcess
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.networks = Model.normalizeNetworks(Model.parseJson(text))
        root.loadingNetworks = false
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

  // Fetched only when a row is expanded, and dropped when it collapses.
  // The main snapshot never carries Env.
  property var envById: ({})
  // The row the user is waiting on. A result for anything else is dropped, so
  // an environment fetched for a row that has since closed is never kept.
  property string wantedEnvId: ""

  function loadEnv(container) {
    if (!container || !Model.isValidId(container.id)) return
    // A second expand while the first is still running used to be dropped, and
    // the new row waited for a result that never came.
    wantedEnvId = container.id
    if (envProcess.running) envProcess.running = false
    envProcess.containerId = container.id
    envProcess.command = ["docker", "inspect", "--type", "container",
                          "--format", "{{json .Config.Env}}", container.id]
    envProcess.running = true
  }

  function forgetEnv(id) {
    if (String(id) === wantedEnvId) wantedEnvId = ""
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
        if (envProcess.containerId !== root.wantedEnvId) return
        var rows = Model.parseJsonLines(text)
        var next = ({})
        for (var key in root.envById) next[key] = root.envById[key]
        next[envProcess.containerId] = Model.envEntries(rows.length > 0 ? rows[0] : [])
        root.envById = next
      }
    }
  }

  // ---- Actions -------------------------------------------------------------

  // Which containers have an action running, as id -> verb. A map, not one id:
  // docker stop waits ten seconds, and one shared process blocked every other row.
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

  // Group actions use the same map, keyed by project.
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

  // The single mutation entry point. Every button routes here.
  function runAction(action, container) {
    if (!container || !daemonReachable) return
    if (readOnly) {
      lastError = "Read-only mode is on"
      return
    }
    // One verb at a time per container, but containers run in parallel.
    if (busyAction(container.id) !== "") return

    var command = commandFor(action, container)
    if (!command) return

    lastError = ""
    // Stopping on purpose must not notify the person who asked.
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
    // The event stream reports the real change. This only settles the UI when an
    // action was a no-op and produced no event.
    refresh()
  }

  // One process per action, destroyed when it exits.
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

  // Maps a verb to argv. The container id is always its own argv entry.
  function commandFor(action, container) {
    var id = container.id
    if (!Model.isValidId(id)) return null
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

  // Logs and shells open in a terminal, not in the panel. A popup is the wrong
  // place for a long session, and a terminal renders the bytes, not Kaj.
  function openLogs(container) {
    if (!container || !Model.isValidId(container.id)) return
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "docker", "logs", "--follow", "--tail", String(logLines), container.id
    ])
  }

  // A shell is not an inspection. docker exec gives a root prompt in the container,
  // which can change more than any button here.
  function openShell(container) {
    if (!container || !container.running) return
    if (!Model.isValidId(container.id)) return
    if (readOnly) { lastError = "Read-only mode is on"; return }
    Quickshell.execDetached([
      "omarchy-launch-terminal",
      "docker", "exec", "--interactive", "--tty", container.id, "sh"
    ])
  }

  // Toggling a setting writes the setting, so the panel holds no second copy.
  // --json keeps the value a real boolean.
  function writeSetting(key, next) {
    if (!Model.isTogglable(key)) return
    Quickshell.execDetached([
      "omarchy", "bar", "set", "mozzy.kaj", key,
      next === true ? "true" : "false", "--json"
    ])
  }

  function openPort(url) {
    if (!url || url === "") return
    Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  function copyText(text) {
    // The value goes over stdin, never argv. An argv entry would expose the secret
    // to every process that can read /proc.
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

  // Reachability is decided by the exit code in onExited, never by a stream
  // handler. Both streams finish on every run, including when empty.
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
        // A stopped daemon reports on stderr. Keep the text: a permission problem and a
        // stopped daemon need different fixes.
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
          // Accept only valid container ids.
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
        // Containers removed between the two commands are expected.
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

  // Kaj is event-driven. docker events pushes changes as they happen.
  // The timer below is only a safety net.
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
      // A daemon restart ends the stream. Re-probe instead of going stale.
      root.daemonReachable = false
      reconnectTimer.restart()
    }
  }

  Process {
    id: statsProcess
    running: false
    // The events stream re-probes the daemon when it dies, but stats can end on
    // its own, and nothing else would notice that the numbers had stopped.
    onExited: root.statsRestartTimer.restart()
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
      // Any state change means re-read. refresh() coalesces the calls.
      refreshTimer.restart()
    }
  }

  // Records a container Kaj just stopped, so the die event is not announced back.
  property var _selfInitiated: ({})

  function markSelfInitiated(id) {
    var next = ({})
    for (var key in _selfInitiated) next[key] = _selfInitiated[key]
    next[String(id)] = Date.now()
    _selfInitiated = next
  }

  function wasSelfInitiated(id) {
    var at = _selfInitiated[String(id)]
    // Only recent enough to be the same act.
    return at !== undefined && (Date.now() - at) < 15000
  }

  // A container that failed is worth an interruption. One that did what it was
  // told is not. 143 is SIGTERM, which docker stop sends, and 130 is SIGINT.
  readonly property var quietExitCodes: [0, 130, 143]

  // A restart loop dies every few seconds. One notification per cooldown window.
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
    // Normal urgency. Critical is sticky in most daemons and must be dismissed.
    notify("Container exited", Model.notificationText(name) + " exited with code " + exitCode, "normal")
  }

  // Out of memory earns critical. It is rare, unasked for, and easy to miss.
  function announceOom(event) {
    var attributes = event.Actor && event.Actor.Attributes ? event.Actor.Attributes : {}
    var name = Model.sanitizeLine(attributes.name || Model.shortId(event.id), 80)
    notify("Container out of memory",
      Model.notificationText(name) + " was killed for exceeding its memory limit", "critical")
  }

  // ---- Timers --------------------------------------------------------------

  // Coalesces a burst of events into one refresh.
  Timer {
    id: refreshTimer
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: statsRestartTimer
    interval: 3000
    repeat: false
    onTriggered: root.syncStatsStream()
  }

  Timer {
    id: reconnectTimer
    interval: 3000
    repeat: false
    onTriggered: root.checkDaemon()
  }

  // Safety net. Bounds how long the panel can disagree with reality.
  Timer {
    interval: Math.max(5, root.refreshIntervalSec) * 1000
    repeat: true
    running: root.daemonReachable
    onTriggered: root.refresh()
  }
}
