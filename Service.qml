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
  property bool errorFromAction: false

  // Types, defaults and limits all live in Model.settingsSchema.
  readonly property bool readOnly: Model.readSetting(settings, "readOnly")
  readonly property bool showResourceUsage: Model.readSetting(settings, "showResourceUsage")
  readonly property bool showContainerCountInBar: Model.readSetting(settings, "showContainerCountInBar")
  readonly property bool notifyOnContainerExit: Model.readSetting(settings, "notifyOnContainerExit")
  readonly property string defaultContainerStatusFilter: Model.readSetting(settings, "defaultContainerStatusFilter")
  readonly property int refreshIntervalSec: Model.readSetting(settings, "refreshIntervalSec")
  readonly property int logLines: Model.readSetting(settings, "logLines")
  readonly property string summary: dockerInstalled
    ? (daemonReachable ? Model.barSummary(containers) : "Docker daemon not running")
    : "Docker not installed"

  // A producer that runs past its budget is stopped mid-read and its output is
  // dropped. Nothing partial reaches the panel: half a container list is worse
  // than an error saying the list was too large.
  // Every one-shot command is watched. Quickshell's Process has no timeout of
  // its own, so a stalled endpoint would keep the pipe open for the life of the
  // shell: Kaj is keep-loaded, and nothing else would ever close it.
  property var _watched: []

  function watch(proc, what) {
    var next = []
    for (var i = 0; i < _watched.length; i++) {
      if (_watched[i].proc !== proc) next.push(_watched[i])
    }
    next.push({ proc: proc, what: what, due: Date.now() + Model.commandDeadlineMs })
    _watched = next
    deadlineTimer.running = true
  }

  function unwatch(proc) {
    var next = []
    for (var i = 0; i < _watched.length; i++) {
      if (_watched[i].proc !== proc) next.push(_watched[i])
    }
    _watched = next
    if (next.length === 0) deadlineTimer.running = false
  }

  function enforceDeadlines() {
    var now = Date.now()
    var next = []
    for (var i = 0; i < _watched.length; i++) {
      var entry = _watched[i]
      if (entry.due > now) { next.push(entry); continue }
      markRefused(entry.proc, true)
      entry.proc.running = false
      lastError = entry.what + " did not answer in time"
      errorFromAction = false
    }
    _watched = next
    if (next.length === 0) deadlineTimer.running = false
  }

  property var _refused: ({})

  function isRefused(proc) { return _refused[String(proc)] === true }

  function markRefused(proc, refused) {
    var next = ({})
    for (var key in _refused) next[key] = _refused[key]
    if (refused) next[String(proc)] = true
    else delete next[String(proc)]
    _refused = next
  }

  function refuseOversized(proc, what) {
    markRefused(proc, true)
    proc.running = false
    lastError = what + " returned more data than Kaj will read"
    errorFromAction = false
    return true
  }

  function clearError() {
    lastError = ""
    errorFromAction = false
  }

  // The ids the last snapshot listed. Stats for anything else are dropped, so
  // an endpoint inventing ids cannot grow the map.
  readonly property var knownShortIds: {
    var out = []
    for (var i = 0; i < containers.length; i++) out.push(containers[i].shortId)
    return out
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
    watch(whichProcess, "docker")
    whichProcess.running = true
  }

  // Installed and reachable are different: the binary can be there while the
  // daemon is stopped or the user is not in the docker group.
  function checkDaemon() {
    if (!dockerInstalled) return
    if (pingProcess.running) return
    pingProcess.command = ["docker", "version", "--format", "{{.Server.Version}}"]
    watch(pingProcess, "docker version")
    pingProcess.running = true
  }

  // Two processes on purpose. One call would need docker inspect $(docker ps -aq),
  // and that needs a shell.
  function refresh() {
    if (!dockerInstalled || !daemonReachable) return
    if (idsProcess.running || inspectProcess.running) return
    idsProcess.command = ["docker", "ps", "-a", "--no-trunc", "--quiet"]
    watch(idsProcess, "docker ps")
    idsProcess.running = true
  }

  property var _pendingIds: []
  property string _idsBuffer: ""

  // Inspect runs in batches. One call carrying every id is a command line whose
  // length depends on how many containers the endpoint claims to have.
  property var _pendingBatches: []
  property var _collected: []

  function inspectIds(ids) {
    if (!Array.isArray(ids) || ids.length === 0) {
      applyContainers([])
      return
    }
    _pendingBatches = Model.idBatches(ids)
    _collected = []
    runNextBatch()
  }

  function runNextBatch() {
    if (_pendingBatches.length === 0) {
      applyContainers(Model.normalizeContainers(_collected))
      _collected = []
      return
    }
    var batch = _pendingBatches[0]
    _pendingBatches = _pendingBatches.slice(1)
    var command = ["docker", "inspect", "--type", "container", "--format", inspectFormat]
    for (var i = 0; i < batch.length; i++) command.push(batch[i])
    inspectProcess.command = command
    watch(inspectProcess, "docker inspect")
    inspectProcess.running = true
  }

  // Go encodes each {{json ...}} and every key is a literal, so container text
  // cannot break out of the JSON.
  readonly property string inspectFormat: '{"Id":{{json .Id}},"Name":{{json .Name}},"Created":{{json .Created}},"State":{{json .State}},"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}},"Ports":{{json .NetworkSettings.Ports}},"RestartCount":{{json .RestartCount}},"MemoryLimit":{{json .HostConfig.Memory}},"NanoCpus":{{json .HostConfig.NanoCpus}},"Mounts":{{json .Mounts}},"Networks":{{json .NetworkSettings.Networks}}}'

  // Counts always come from the full list, never the filtered one, so the bar
  // cannot hide a problem.
  function applyContainers(list) {
    // A snapshot that arrived proves the last refresh failure is over. An
    // action that failed is not: the refresh that follows one used to wipe the
    // reason off the screen before it could be read.
    if (!errorFromAction) lastError = ""
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
    watch(imagesProcess, "docker images")
    imagesProcess.running = true
  }

  // docker system df -v, not docker volume ls, because only df reports size.
  function loadVolumes() {
    if (!daemonReachable || volumesProcess.running) return
    loadingVolumes = true
    volumesProcess.command = ["docker", "system", "df", "-v", "--format", "{{json .Volumes}}"]
    watch(volumesProcess, "docker system df")
    volumesProcess.running = true
  }

  // Two steps: docker network ls has no subnets, and inspect returns labels as an
  // object instead of a flat string.
  function loadNetworks() {
    if (!daemonReachable || networkIdsProcess.running || networksProcess.running) return
    loadingNetworks = true
    networkIdsProcess.command = ["docker", "network", "ls", "--quiet"]
    watch(networkIdsProcess, "docker network ls")
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
    watch(networksProcess, "docker network inspect")
    networksProcess.running = true
  }

  function loadDisk() {
    if (!daemonReachable || diskProcess.running) return
    diskProcess.command = ["docker", "system", "df", "--format", "{{json .}}"]
    watch(diskProcess, "docker system df")
    diskProcess.running = true
  }

  Process {
    id: imagesProcess
    running: false
    onExited: root.unwatch(imagesProcess)
    onRunningChanged: if (running) root.markRefused(imagesProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(imagesProcess, "docker images")
      }
      onStreamFinished: {
        if (root.isRefused(imagesProcess)) { root.loadingImages = false; return }
        root.images = Model.normalizeImages(Model.parseJsonLines(text))
        root.loadingImages = false
      }
    }
  }

  Process {
    id: volumesProcess
    running: false
    onExited: root.unwatch(volumesProcess)
    onRunningChanged: if (running) root.markRefused(volumesProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(volumesProcess, "docker system df")
      }
      onStreamFinished: {
        if (root.isRefused(volumesProcess)) { root.loadingVolumes = false; return }
        root.volumes = Model.normalizeVolumes(Model.parseJson(text))
        root.loadingVolumes = false
      }
    }
  }

  Process {
    id: networkIdsProcess
    running: false
    onExited: root.unwatch(networkIdsProcess)
    onRunningChanged: if (running) root.markRefused(networkIdsProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(networkIdsProcess, "docker network ls")
      }
      onStreamFinished: {
        if (root.isRefused(networkIdsProcess)) { root.loadingNetworks = false; return }
        root.inspectNetworks(Model.parseIds(text))
      }
    }
  }

  Process {
    id: networksProcess
    running: false
    onExited: root.unwatch(networksProcess)
    onRunningChanged: if (running) root.markRefused(networksProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(networksProcess, "docker network inspect")
      }
      onStreamFinished: {
        if (root.isRefused(networksProcess)) { root.loadingNetworks = false; return }
        root.networks = Model.normalizeNetworks(Model.parseJson(text))
        root.loadingNetworks = false
      }
    }
  }

  Process {
    id: diskProcess
    running: false
    onExited: root.unwatch(diskProcess)
    onRunningChanged: if (running) root.markRefused(diskProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(diskProcess, "docker system df")
      }
      onStreamFinished: {
        if (root.isRefused(diskProcess)) return
        root.disk = Model.normalizeDisk(Model.parseJsonLines(text))
      }
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
    watch(envProcess, "docker inspect")
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
    onExited: root.unwatch(envProcess)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(envProcess, "docker inspect")
      }
      onStreamFinished: {
        if (root.isRefused(envProcess)) return
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

    clearError()
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

    clearError()
    // Stopping on purpose must not notify the person who asked.
    if (action === "stop" || action === "restart" || action === "remove") {
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
    if (failure && failure !== "") {
      lastError = failure
      errorFromAction = true
    }
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
        onDataChanged: if (Model.overBudget(text, Model.maxErrorBytes)) proc.running = false
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
    onExited: root.unwatch(whichProcess)
    onRunningChanged: if (running) root.markRefused(whichProcess, false)
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
      root.unwatch(pingProcess)
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
    onExited: root.unwatch(idsProcess)
    onRunningChanged: if (running) root.markRefused(idsProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(idsProcess, "docker ps")
      }
      onStreamFinished: {
        if (root.isRefused(idsProcess)) return
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
    onExited: root.unwatch(inspectProcess)
    onRunningChanged: if (running) root.markRefused(inspectProcess, false)
    stdout: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text)) root.refuseOversized(inspectProcess, "docker inspect")
      }
      onStreamFinished: {
        if (root.isRefused(inspectProcess)) return
        var rows = Model.parseJsonLines(text)
        for (var i = 0; i < rows.length && root._collected.length < Model.maxRows; i++) {
          root._collected.push(rows[i])
        }
        root.runNextBatch()
      }
    }
    // Diagnostics are bounded too: stderr is read for one line, and a daemon
    // that floods it is cut off rather than buffered.
    stderr: StdioCollector {
      onDataChanged: {
        if (Model.overBudget(text, Model.maxErrorBytes)) inspectProcess.running = false
      }
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
    var want = daemonReachable && showResourceUsage
    if (want && !statsProcess.running) {
      statsProcess.command = ["docker", "stats", "--format", "{{json .}}"]
      statsProcess.running = true
    } else if (!want && statsProcess.running) {
      statsProcess.running = false
      statsById = ({})
    }
  }

  onShowResourceUsageChanged: syncStatsStream()

  Process {
    id: eventsProcess
    property int consumed: 0
    property string tail: ""
    running: false
    onRunningChanged: if (running) { consumed = 0; tail = "" }
    // Read through a collector rather than a line parser, because a collector's
    // buffer can be measured. A record with no newline never reaches a line
    // parser's callback, so its size is invisible: here it stays in the tail,
    // and a tail past the cap drops the stream instead of holding it.
    stdout: StdioCollector {
      onDataChanged: {
        var fresh = text.slice(eventsProcess.consumed)
        eventsProcess.consumed = text.length
        var taken = Model.takeRecords(eventsProcess.tail + fresh)
        eventsProcess.tail = taken.rest
        if (taken.overflow) { root.dropStream(eventsProcess, "docker events"); return }
        for (var i = 0; i < taken.records.length; i++) root.handleEvent(taken.records[i])
        if (text.length > Model.maxStreamBufferBytes) root.recycleStreams()
      }
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
    property int consumed: 0
    property string tail: ""
    onRunningChanged: if (running) { consumed = 0; tail = "" }
    stdout: StdioCollector {
      onDataChanged: {
        var fresh = text.slice(statsProcess.consumed)
        statsProcess.consumed = text.length
        var taken = Model.takeRecords(statsProcess.tail + fresh)
        statsProcess.tail = taken.rest
        if (taken.overflow) { root.dropStream(statsProcess, "docker stats"); return }
        for (var i = 0; i < taken.records.length; i++) {
          // Stats records are rate limited too: a flood of short lines drove
          // every callback and every binding behind it.
          if (root._statsThisWindow >= Model.maxStatsPerWindow) break
          root._statsThisWindow++
          var parsed = Model.parseJsonLines(taken.records[i])
          for (var j = 0; j < parsed.length; j++) {
            root.statsById = Model.mergeStats(root.statsById, parsed[j], root.knownShortIds)
          }
        }
        if (text.length > Model.maxStreamBufferBytes) root.recycleStreams()
      }
    }
  }

  // Events arrive in bursts and a burst is fine. Past the ceiling the rest of
  // the window is dropped: the reconcile timer still corrects the panel, so a
  // flood costs accuracy for a second rather than the shell's main thread.
  property int _eventsThisWindow: 0
  property int _statsThisWindow: 0

  // A stream whose buffer runs past the cap is stopped, not held. The
  // reconnect path brings it back.
  function dropStream(proc, what) {
    proc.running = false
    lastError = what + " sent a record larger than Kaj will read"
    errorFromAction = false
    reconnectTimer.restart()
  }

  function recycleStreams() {
    eventsProcess.running = false
    statsProcess.running = false
    startStreams()
  }

  function handleEvent(line) {
    if (_eventsThisWindow >= Model.maxEventsPerWindow) return
    _eventsThisWindow++
    var events = Model.parseJsonLines(line)
    for (var i = 0; i < events.length; i++) {
      var event = events[i]
      if (!event || event.Type !== "container") continue
      var status = String(event.status || event.Action || "")
      if (notifyOnContainerExit && status === "die") announceExit(event)
      if (notifyOnContainerExit && status === "oom") announceOom(event)
      // Any state change means re-read. refresh() coalesces the calls.
      refreshTimer.restart()
    }
  }

  // Records a container Kaj just stopped, so the die event is not announced back.
  property var _selfInitiated: ({})

  function markSelfInitiated(id) {
    _selfInitiated = Model.pruneTimestamps(_selfInitiated)
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

  // Two ceilings, because the per-container cooldown alone does not bound a
  // daemon inventing ids: each new id was a free notification and a permanent
  // map entry. The map is pruned, and no more than a few notifications leave
  // Kaj in any one window however many containers report.
  readonly property int maxNotificationsPerWindow: 3
  property int _notificationsThisWindow: 0

  function shouldNotify(id) {
    if (_notificationsThisWindow >= maxNotificationsPerWindow) return false
    var key = String(id)
    var last = _lastNotified[key]
    if (last !== undefined && (Date.now() - last) < notifyCooldownMs) return false
    var next = ({})
    for (var existing in _lastNotified) next[existing] = _lastNotified[existing]
    next[key] = Date.now()
    _lastNotified = Model.pruneTimestamps(next)
    _notificationsThisWindow++
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
    id: eventWindowTimer
    interval: Model.eventWindowMs
    repeat: true
    running: root.daemonReachable
    onTriggered: {
      root._eventsThisWindow = 0
      root._statsThisWindow = 0
      root._notificationsThisWindow = 0
    }
  }

  // A stream is read line by line, and a record with no newline never reaches
  // that guard: it sits in the parser's buffer growing. Kaj cannot see that
  // buffer, so it bounds the process instead and starts a fresh one.
  Timer {
    id: streamRecycleTimer
    interval: 600000
    repeat: true
    running: root.daemonReachable
    onTriggered: root.recycleStreams()
  }

  Timer {
    id: deadlineTimer
    interval: 1000
    repeat: true
    running: false
    onTriggered: root.enforceDeadlines()
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
