.pragma library

// Pure logic for Kaj. No QML, no filesystem. Tested by test/model.test.js.
// All data from Docker is untrusted and is cleaned here.

// ---------------------------------------------------------------------------
// Untrusted text
// ---------------------------------------------------------------------------

// Names, tags, labels and log lines come from the image, not from the user.
// Rule 1: never put this text in a shell string. Service.qml uses argv arrays.
// Rule 2: never render it as rich text. The UI uses Text.PlainText.

// Escape sequences: CSI, OSC, short escapes, and 8-bit CSI.
// Written as hex escapes. A literal ESC byte makes grep treat the file as binary.
var ansiPattern = /\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]|\x9b[0-9;?]*[ -\/]*[@-~]/g
// C0 controls except tab and newline, plus DEL and C1.
var controlPattern = /[\x00-\x08\x0b-\x1f\x7f-\x9f]/g

// undefined and null become "", so callers never test for them.
function str(value) {
  return value === undefined || value === null ? "" : String(value)
}

function stripAnsi(text) {
  return str(text).replace(ansiPattern, "")
}

// Clean text for display. Strips escapes, then control bytes, then caps length.
function sanitize(text, maxLength) {
  var limit = maxLength === undefined ? 4096 : maxLength
  var out = stripAnsi(text).replace(controlPattern, "")
  if (out.length > limit) out = out.slice(0, limit) + "…"
  return out
}

// Single-line version, for names and status text.
function sanitizeLine(text, maxLength) {
  var single = str(text).replace(/[\r\n\t]+/g, " ")
  return sanitize(single, maxLength === undefined ? 256 : maxLength)
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

// All values are hidden until the user asks. Kaj does not guess which keys are
// secret, because such a list always misses one.

// Only the first = separates. Values often contain more.
function splitEnvEntry(entry) {
  var text = str(entry)
  var index = text.indexOf("=")
  if (index < 0) return { key: sanitizeLine(text), value: "" }
  return { key: sanitizeLine(text.slice(0, index)), value: sanitizeLine(text.slice(index + 1), 512) }
}

// Fixed-width mask. The real length is a hint, so it is not shown.
function maskValue(value) {
  return str(value) === "" ? "" : "••••••••"
}

function envEntries(list) {
  var out = []
  if (!list || list.length === undefined) return out
  for (var i = 0; i < list.length; i++) {
    var parts = splitEnvEntry(list[i])
    out.push({ key: parts.key, value: parts.value, masked: maskValue(parts.value) })
  }
  return out
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

// Docker writes one JSON object per line. Bad lines are skipped.
// Escapes are stripped first: docker stats writes cursor codes around each record.
function parseJsonLines(text) {
  var out = []
  var lines = stripAnsi(str(text)).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(controlPattern, "").trim()
    if (line === "") continue
    try {
      var parsed = JSON.parse(line)
      if (parsed && typeof parsed === "object") out.push(parsed)
    } catch (e) {
      // Ignore: partial line, or output we do not understand.
    }
  }
  return out
}

// Whole-document JSON, for docker network inspect and docker system df -v.
function parseJson(text) {
  var body = stripAnsi(str(text))
    .replace(controlPattern, "").trim()
  if (body === "") return []
  try {
    var parsed = JSON.parse(body)
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

// Accept only valid Docker ids. Anything else never reaches a command line.
function parseIds(text) {
  var out = []
  var lines = str(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (/^[0-9a-f]{12,64}$/.test(line)) out.push(line)
  }
  return out
}

// Ids reach a command line, so they are checked against what Docker can
// return. Kaj honours DOCKER_HOST, and a hostile endpoint could answer with an
// id like "--privileged" that argv position alone would not make safe.
function isValidId(id) {
  return /^[0-9a-f]{12,64}$/.test(str(id))
}

function shortId(id) {
  return String(id || "").replace(/^sha256:/, "").slice(0, 12)
}

// Docker reports container names with a leading slash.
function displayName(name) {
  return sanitizeLine(String(name || "").replace(/^\//, ""))
}

// Health is empty when the image has no healthcheck. Do not show it as unhealthy.
function healthOf(state) {
  if (!state || typeof state !== "object") return ""
  var health = state.Health
  if (!health || typeof health !== "object") return ""
  return sanitizeLine(health.Status || "")
}

// One container, flattened from inspect into the shape the UI binds to.
function normalizeContainer(raw) {
  if (!raw || typeof raw !== "object") return null
  var state = raw.State && typeof raw.State === "object" ? raw.State : {}
  var labels = raw.Labels && typeof raw.Labels === "object" ? raw.Labels : {}
  var status = sanitizeLine(state.Status || "unknown")

  return {
    id: String(raw.Id || ""),
    shortId: shortId(raw.Id),
    name: displayName(raw.Name),
    image: sanitizeLine(raw.Image || ""),
    status: status,
    running: state.Running === true,
    paused: state.Paused === true,
    restarting: state.Restarting === true,
    dead: state.Dead === true,
    oomKilled: state.OOMKilled === true,
    exitCode: Number(state.ExitCode || 0),
    error: sanitizeLine(state.Error || "", 512),
    health: healthOf(state),
    restartCount: Number(raw.RestartCount || 0),
    startedAt: parseTime(state.StartedAt),
    finishedAt: parseTime(state.FinishedAt),
    createdAt: parseTime(raw.Created),
    project: sanitizeLine(labels["com.docker.compose.project"] || ""),
    service: sanitizeLine(labels["com.docker.compose.service"] || ""),
    ports: normalizePorts(raw.Ports),
    // Names only. The full objects carry host paths and IPAM detail the UI never shows.
    mounts: mountNames(raw.Mounts),
    networks: networkNames(raw.Networks),
    // 0 means no limit. Keeping the 0 lets the UI tell unlimited from limited.
    memoryLimit: positiveNumber(raw.MemoryLimit),
    cpuLimit: positiveNumber(raw.NanoCpus) / 1e9
  }
}

// A bind mount has no name. It is not a volume and must not make one look used.
function mountNames(list) {
  var out = []
  if (!list || list.length === undefined) return out
  for (var i = 0; i < list.length; i++) {
    var mount = list[i]
    if (!mount || mount.Type !== "volume") continue
    var name = sanitizeLine(mount.Name || "")
    if (name !== "" && out.indexOf(name) === -1) out.push(name)
  }
  return out
}

function networkNames(map) {
  var out = []
  if (!map || typeof map !== "object") return out
  for (var key in map) {
    var name = sanitizeLine(key)
    if (name !== "" && out.indexOf(name) === -1) out.push(name)
  }
  return out
}

function positiveNumber(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : 0
}

function normalizeContainers(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var item = normalizeContainer(list[i])
    if (item && item.id !== "") out.push(item)
  }
  return out
}

// Docker's zero timestamp means never. Return 0 so callers can test it.
function parseTime(value) {
  var text = String(value || "")
  if (text === "" || text.indexOf("0001-01-01") === 0) return 0
  var ms = Date.parse(text)
  return isFinite(ms) ? ms : 0
}

// Ports map "5800/tcp" to host bindings, or to null when not published.
function normalizePorts(ports) {
  var out = []
  if (!ports || typeof ports !== "object") return out
  var keys = Object.keys(ports).sort()
  for (var i = 0; i < keys.length; i++) {
    var bindings = ports[keys[i]]
    var parts = String(keys[i]).split("/")
    var containerPort = parseInt(parts[0], 10)
    if (!isFinite(containerPort)) continue
    if (!Array.isArray(bindings) || bindings.length === 0) {
      out.push({ containerPort: containerPort, protocol: parts[1] || "tcp", hostIp: "", hostPort: 0, published: false })
      continue
    }
    // Collapse the v4/v6 pair Docker reports for one -p flag.
    var seen = {}
    for (var j = 0; j < bindings.length; j++) {
      var hostPort = parseInt(bindings[j] && bindings[j].HostPort, 10)
      if (!isFinite(hostPort) || seen[hostPort]) continue
      seen[hostPort] = true
      out.push({
        containerPort: containerPort,
        protocol: parts[1] || "tcp",
        hostIp: sanitizeLine(bindings[j].HostIp || ""),
        hostPort: hostPort,
        published: true
      })
    }
  }
  return out
}

// Only a port on a loopback-reachable address can be a link.
// 0.0.0.0 and :: are reachable. Another specific interface may not be.
function browsableUrl(port) {
  if (!port || !port.published || port.protocol !== "tcp") return ""
  var host = port.hostIp
  if (host !== "" && host !== "0.0.0.0" && host !== "::" && host !== "127.0.0.1" && host !== "localhost") return ""
  var scheme = port.hostPort === 443 || port.hostPort === 8443 ? "https" : "http"
  return scheme + "://localhost:" + port.hostPort
}

// Ports worth showing in a row: published, and reachable from this machine.
function linkablePorts(container) {
  var out = []
  if (!container) return out
  // Not Array.isArray: QML returns arrays held in a var property as a list type
  // that fails that check but works like an array.
  var ports = container.ports
  if (!ports || ports.length === undefined) return out
  var seen = {}
  for (var i = 0; i < ports.length; i++) {
    var url = browsableUrl(ports[i])
    if (url === "" || seen[url]) continue
    seen[url] = true
    out.push({ port: ports[i].hostPort, url: url })
  }
  return out
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

// docker stats returns strings like "3.49%" and "74.71MiB / 7.628GiB".
// Parse them to numbers so the UI can sort and draw meters.
function parsePercent(value) {
  var n = parseFloat(String(value || "").replace("%", ""))
  return isFinite(n) && n >= 0 ? n : 0
}

var unitFactors = { B: 1, KB: 1e3, MB: 1e6, GB: 1e9, TB: 1e12, KIB: 1024, MIB: 1048576, GIB: 1073741824, TIB: 1099511627776 }

function parseSize(value) {
  var match = String(value || "").trim().match(/^([0-9.]+)\s*([A-Za-z]+)?$/)
  if (!match) return 0
  var n = parseFloat(match[1])
  if (!isFinite(n)) return 0
  var factor = unitFactors[String(match[2] || "B").toUpperCase()]
  return factor ? n * factor : 0
}

// "74.71MiB / 7.628GiB" -> { used, limit }
function parseUsagePair(value) {
  var parts = String(value || "").split("/")
  return { used: parseSize(parts[0]), limit: parseSize(parts[1]) }
}

function normalizeStat(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = String(raw.ID || raw.Container || "")
  if (id === "") return null
  var mem = parseUsagePair(raw.MemUsage)
  return {
    shortId: shortId(id),
    cpu: parsePercent(raw.CPUPerc),
    memPercent: parsePercent(raw.MemPerc),
    memUsed: mem.used,
    memLimit: mem.limit,
    pids: parseInt(raw.PIDs, 10) || 0
  }
}

// Usage against the container's own limit, or -1 when it has none.
// Without a limit the only number to compare against is the whole host.
function memoryPressure(container, stats) {
  if (!container || !stats) return -1
  var limit = Number(container.memoryLimit || 0)
  if (!isFinite(limit) || limit <= 0) return -1
  var used = Number(stats.memUsed || 0)
  if (!isFinite(used) || used < 0) return -1
  return used / limit
}

// The level where a figure turns urgent. Not a hard limit, but close to trouble.
var pressureWarning = 0.9

// The same for CPU. docker stats reports a percentage of every core on the host,
// so 150% means nothing until you know the container's own ration.
function cpuPressure(container, stats) {
  if (!container || !stats) return -1
  var cpus = Number(container.cpuLimit || 0)
  if (!isFinite(cpus) || cpus <= 0) return -1
  var cpu = Number(stats.cpu || 0)
  if (!isFinite(cpu) || cpu < 0) return -1
  return cpu / (cpus * 100)
}

// Stats arrive keyed by short id. Fold them into a lookup the UI can index.
function mergeStats(existing, raw) {
  var out = {}
  if (existing && typeof existing === "object") {
    var keys = Object.keys(existing)
    for (var i = 0; i < keys.length; i++) out[keys[i]] = existing[keys[i]]
  }
  var stat = normalizeStat(raw)
  if (stat) out[stat.shortId] = stat
  return out
}

// ---------------------------------------------------------------------------
// Grouping and rollup
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// A container that disappears during a refresh is normal, not an error.
// The snapshot is two commands, so anything removed between them is missing.
function isMissingContainerError(line) {
  return /No such (container|object)/i.test(String(line || ""))
}

// Docker writes one line per failure. Show only the first one that matters.
function firstRealError(text, maxLength) {
  var lines = str(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (isMissingContainerError(line)) continue
    return sanitizeLine(line, maxLength === undefined ? 200 : maxLength)
  }
  return ""
}

// ---------------------------------------------------------------------------
// Search and status filtering
// ---------------------------------------------------------------------------

var statusFilters = ["all", "running", "stopped", "problems"]

function statusFilterLabel(filter) {
  if (filter === "running") return "Running"
  if (filter === "stopped") return "Stopped"
  if (filter === "problems") return "Problems"
  return "All"
}

function matchesStatus(container, filter) {
  if (!container) return false
  if (filter === "running") return container.running === true
  if (filter === "stopped") return container.running !== true
  // Problems is the filter nothing else offers: everything worth acting on now.
  if (filter === "problems") return containerSeverity(container) !== "ok"
  return true
}

// Substring, not fuzzy. Names are short ids that people type exactly.
function matchesQuery(container, query) {
  if (!container) return false
  var needle = str(query).trim().toLowerCase()
  if (needle === "") return true
  var haystacks = [container.name, container.service, container.project, container.image, container.shortId]
  for (var i = 0; i < haystacks.length; i++) {
    if (String(haystacks[i] || "").toLowerCase().indexOf(needle) !== -1) return true
  }
  return false
}

function filterContainers(containers, query, statusFilter) {
  var list = Array.isArray(containers) ? containers : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (matchesStatus(list[i], statusFilter) && matchesQuery(list[i], query)) out.push(list[i])
  }
  return out
}

// Counts come from the same list the chips filter, so the numbers always match.
function statusCounts(containers, query) {
  var list = Array.isArray(containers) ? containers : []
  var counts = { all: 0, running: 0, stopped: 0, problems: 0 }
  for (var i = 0; i < list.length; i++) {
    if (!matchesQuery(list[i], query)) continue
    counts.all++
    if (matchesStatus(list[i], "running")) counts.running++
    if (matchesStatus(list[i], "stopped")) counts.stopped++
    if (matchesStatus(list[i], "problems")) counts.problems++
  }
  return counts
}

// ---------------------------------------------------------------------------
// Keyboard cursor
// ---------------------------------------------------------------------------

// The panel renders groups, but the keyboard moves through one flat list.
function flattenGroups(groups) {
  var out = []
  var list = Array.isArray(groups) ? groups : []
  for (var i = 0; i < list.length; i++) {
    var containers = list[i] && Array.isArray(list[i].containers) ? list[i].containers : []
    for (var j = 0; j < containers.length; j++) out.push(containers[j])
  }
  return out
}

// Identity of a rendered list: which containers, in which order.
// Rows are rebuilt only when this changes. A Repeater recreates every delegate
// when its model is replaced, and a rebuilt row loses its hover.
function groupsKey(groups) {
  var parts = []
  var list = Array.isArray(groups) ? groups : []
  for (var i = 0; i < list.length; i++) {
    parts.push(list[i].project)
    var containers = list[i].containers || []
    for (var j = 0; j < containers.length; j++) parts.push(containers[j].id)
  }
  return parts.join("\u0000")
}

// Header numbers for one project, read live so a stable row list stays correct.
function groupStats(containers, project) {
  var list = Array.isArray(containers) ? containers : []
  var mine = []
  for (var i = 0; i < list.length; i++) {
    if ((list[i].project || "") === project) mine.push(list[i])
  }
  return { running: countRunning(mine), total: mine.length, severity: rollupSeverity(mine) }
}

// Where a scroll lands. Kept here because edges are what gets it wrong.
function scrollTarget(contentY, delta, step, contentHeight, viewportHeight) {
  var max = Math.max(0, Number(contentHeight || 0) - Number(viewportHeight || 0))
  var next = Number(contentY || 0) + Number(delta || 0) * Number(step || 0)
  if (!isFinite(next)) return 0
  return Math.max(0, Math.min(max, next))
}

// Wraps, because walking back to the other end of a long list is slow.
function moveCursor(index, delta, length) {
  if (length <= 0) return -1
  if (index < 0) return delta > 0 ? 0 : length - 1
  var next = (index + delta) % length
  return next < 0 ? next + length : next
}

// Keeps the cursor on the same container across a refresh.
function cursorIndexForId(list, id, fallbackIndex) {
  var items = Array.isArray(list) ? list : []
  if (items.length === 0) return -1
  if (id) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].id === id) return i
    }
  }
  if (fallbackIndex === undefined || fallbackIndex < 0) return -1
  return Math.max(0, Math.min(items.length - 1, fallbackIndex))
}

// The key for each action. Tooltips and the help sheet both read this.
// Start and stop share Enter because they are one intent: flip this container.
function actionHotkey(action) {
  switch (action) {
    case "start":
    case "stop": return "Enter"
    case "restart": return "r"
    case "logs": return "o"
    case "shell": return "s"
    case "pause":
    case "unpause": return "p"
    case "remove": return "x"
    default: return ""
  }
}

// Every binding the panel answers to, in the order worth learning them.
var keyHelp = [
  { keys: "h  l", what: "Switch view" },
  { keys: "j  k", what: "Move between containers, or scroll" },
  { keys: "f", what: "Cycle status filter" },
  { keys: "Enter", what: "Start or stop" },
  { keys: "r", what: "Restart" },
  { keys: "o", what: "Logs in a terminal" },
  { keys: "s", what: "Shell in the container" },
  { keys: "p", what: "Pause or resume" },
  { keys: "x", what: "Remove (asks first)" },
  { keys: "e", what: "Environment variables" },
  { keys: "Ctrl+F  /", what: "Search" },
  { keys: "?", what: "This list" },
  { keys: "Esc", what: "Clear search, then close" }
]

// Present tense, because the row shows this while the action still runs.
// docker stop can take ten seconds, and a row that only greys out looks broken.
function busyLabel(action) {
  switch (action) {
    case "start": return "Starting…"
    case "stop": return "Stopping…"
    case "restart": return "Restarting…"
    case "pause": return "Pausing…"
    case "unpause": return "Resuming…"
    case "remove":
    case "removeVolumes": return "Removing…"
    default: return "Working…"
  }
}

// Why a key did nothing, written as the thing to do about it.
// Empty means the action can run. Silence would look like a broken key.
function unavailableReason(action, container, readOnly) {
  if (!container) return "Select a container first"
  // Read-only comes first. Telling the user to stop a container does not help
  // when stopping is refused too.
  if (readOnly === true && action !== "logs") return "Read-only mode is on"
  if (availableActions(container).indexOf(action) !== -1) return ""
  if (action === "remove") {
    if (container.running) return "Stop " + container.name + " before removing it"
    return "Cannot remove " + container.name
  }
  if (action === "shell" && !container.running) return container.name + " is not running"
  if (action === "restart" && !container.running) return "Start " + container.name + " instead"
  return "Not available for " + container.name
}

// The action Enter runs. Start and stop are one key because they are one intent.
function primaryAction(container) {
  if (!container) return ""
  if (container.paused) return "unpause"
  return container.running ? "stop" : "start"
}

// Which keys open search. "/" is plain. Ctrl+F arrives as 0x06 in event.text.
// A QtQuick Shortcut never fires on a layer-shell surface, and a KeyEvent
// arrives already accepted, so PanelKeyCatcher swallows what it does not know.
function isSearchKey(text) {
  if (text === "/") return true
  return str(text).charCodeAt(0) === 6
}

// What a key means, whether or not it can run now. Kept apart from availability
// so the caller can tell an unknown key from a blocked action.
function intendedAction(key, container) {
  if (key === "r") return "restart"
  if (key === "o") return "logs"
  if (key === "s") return "shell"
  if (key === "p") return container && container.paused ? "unpause" : "pause"
  return ""
}

// Containers are grouped by Compose project, because people think in projects.
// Standalone containers collect under an empty project id and render last.
function groupByProject(containers) {
  var order = []
  var groups = {}
  var list = Array.isArray(containers) ? containers : []

  for (var i = 0; i < list.length; i++) {
    var key = list[i].project || ""
    if (!groups[key]) {
      groups[key] = { project: key, standalone: key === "", containers: [] }
      order.push(key)
    }
    groups[key].containers.push(list[i])
  }

  order.sort(function (a, b) {
    if (a === "") return 1
    if (b === "") return -1
    return a.localeCompare(b)
  })

  var out = []
  for (var j = 0; j < order.length; j++) {
    var group = groups[order[j]]
    group.containers.sort(compareContainers)
    group.running = countRunning(group.containers)
    group.total = group.containers.length
    group.severity = rollupSeverity(group.containers)
    out.push(group)
  }
  return out
}

// Running first, then by service name, so rows keep a stable order.
function compareContainers(a, b) {
  if (a.running !== b.running) return a.running ? -1 : 1
  var left = a.service || a.name
  var right = b.service || b.name
  return left.localeCompare(right)
}

function countRunning(containers) {
  var n = 0
  var list = Array.isArray(containers) ? containers : []
  for (var i = 0; i < list.length; i++) if (list[i].running) n++
  return n
}

// Severity drives the bar icon colour. error means: look at this now.
function containerSeverity(container) {
  if (!container) return "ok"
  if (container.oomKilled) return "error"
  if (container.dead) return "error"
  if (container.health === "unhealthy") return "error"
  if (!container.running && container.exitCode !== 0) return "error"
  if (container.restarting) return "warn"
  if (container.paused) return "warn"
  if (container.health === "starting") return "warn"
  return "ok"
}

// A glyph replaces the status dot where the shape carries the meaning.
// A paused container is still up, so a coloured dot would read as running.
function statusGlyph(container) {
  if (!container) return ""
  if (container.paused) return "󰏤"
  return ""
}

var severityRank = { ok: 0, warn: 1, error: 2 }

function rollupSeverity(containers) {
  var worst = "ok"
  var list = Array.isArray(containers) ? containers : []
  for (var i = 0; i < list.length; i++) {
    var severity = containerSeverity(list[i])
    if (severityRank[severity] > severityRank[worst]) worst = severity
  }
  return worst
}

// ---------------------------------------------------------------------------
// Compose
// ---------------------------------------------------------------------------

// Group actions run docker compose, not a loop over containers.
// Compose owns the network and the dependency order.
// -p is enough for these four. up is not here: it needs the compose file.
var composeVerbs = ["start", "stop", "restart", "down"]

function composeCommand(project, verb) {
  if (!project || project === "") return null
  if (composeVerbs.indexOf(verb) === -1) return null
  return ["docker", "compose", "--project-name", project, verb]
}

function composeBusyLabel(verb) {
  if (verb === "down") return "Removing project…"
  return busyLabel(verb)
}

// down removes containers and the project network, so it is confirmed.
function composeConfirmText(project, running, total) {
  return "Run docker compose down on " + project + "? "
    + total + (total === 1 ? " container" : " containers")
    + " and the project network are removed. Named volumes are kept."
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

// One table for every setting: the type, the default, and the limits.
// Service.qml reads it, and a test checks manifest.json still agrees with it.
// toggle marks the settings the panel is allowed to write.
var settingsSchema = [
  { key: "readOnly", type: "bool", fallback: false, toggle: true },
  { key: "showResourceUsage", type: "bool", fallback: true, toggle: true },
  { key: "showContainerCountInBar", type: "bool", fallback: true },
  { key: "notifyOnContainerExit", type: "bool", fallback: false, toggle: true },
  { key: "defaultContainerStatusFilter", type: "enum", fallback: "all", options: statusFilters },
  { key: "refreshIntervalSec", type: "int", fallback: 30, min: 5, max: 3600 },
  { key: "logLines", type: "int", fallback: 500, min: 50, max: 5000 }
]

function settingSpec(key) {
  for (var i = 0; i < settingsSchema.length; i++) {
    if (settingsSchema[i].key === key) return settingsSchema[i]
  }
  return null
}

// The value to use: what the user set, or the default when it is missing or
// makes no sense. A bad value is never passed on.
function readSetting(settings, key) {
  var spec = settingSpec(key)
  if (!spec) return undefined
  var value = settings ? settings[key] : undefined
  if (value === undefined || value === null) return spec.fallback
  if (spec.type === "bool") return value === true || value === "true"
  if (spec.type === "int") {
    var n = parseInt(str(value), 10)
    if (!isFinite(n)) return spec.fallback
    return Math.max(spec.min, Math.min(spec.max, n))
  }
  return spec.options.indexOf(str(value)) === -1 ? spec.fallback : str(value)
}

// Only these can be written from the panel, so no other key reaches a command.
function isTogglable(key) {
  var spec = settingSpec(key)
  return spec !== null && spec.toggle === true
}

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

var views = ["containers", "images", "volumes", "networks", "disk"]

function viewLabel(view) {
  if (view === "images") return "Images"
  if (view === "volumes") return "Volumes"
  if (view === "networks") return "Networks"
  if (view === "disk") return "Disk"
  return "Containers"
}

// ---------------------------------------------------------------------------
// Volumes and networks
// ---------------------------------------------------------------------------

// docker system df and docker volume ls report labels as one string, "a=1,b=2".
// A label value with a comma cannot be recovered. Only the project name is read.
function parseLabelString(value) {
  var out = {}
  var text = str(value)
  if (text === "") return out
  var parts = text.split(",")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq > 0) out[parts[i].slice(0, eq)] = parts[i].slice(eq + 1)
  }
  return out
}

function normalizeVolume(raw) {
  if (!raw || typeof raw !== "object") return null
  var name = sanitizeLine(raw.Name || "")
  if (name === "") return null
  var labels = parseLabelString(raw.Labels)
  return {
    name: name,
    size: parseSize(raw.Size),
    driver: sanitizeLine(raw.Driver || ""),
    mountpoint: sanitizeLine(raw.Mountpoint || ""),
    project: sanitizeLine(labels["com.docker.compose.project"] || "")
  }
}

function normalizeVolumes(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var volume = normalizeVolume(list[i])
    if (volume) out.push(volume)
  }
  out.sort(function (a, b) { return b.size - a.size || a.name.localeCompare(b.name) })
  return out
}

// The three networks every daemon has. They cannot be removed.
var builtinNetworks = ["bridge", "host", "none"]

function isBuiltinNetwork(name) {
  return builtinNetworks.indexOf(String(name || "")) !== -1
}

function normalizeNetwork(raw) {
  if (!raw || typeof raw !== "object") return null
  var name = sanitizeLine(raw.Name || "")
  if (name === "") return null
  var labels = raw.Labels && typeof raw.Labels === "object" ? raw.Labels : {}
  return {
    id: String(raw.Id || ""),
    name: name,
    driver: sanitizeLine(raw.Driver || ""),
    scope: sanitizeLine(raw.Scope || ""),
    internal: raw.Internal === true,
    builtin: isBuiltinNetwork(name),
    subnet: firstSubnet(raw.IPAM),
    project: sanitizeLine(labels["com.docker.compose.project"] || "")
  }
}

function firstSubnet(ipam) {
  if (!ipam || typeof ipam !== "object") return ""
  var config = ipam.Config
  if (!config || config.length === undefined) return ""
  for (var i = 0; i < config.length; i++) {
    if (config[i] && config[i].Subnet) return sanitizeLine(config[i].Subnet)
  }
  return ""
}

function normalizeNetworks(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var network = normalizeNetwork(list[i])
    if (network) out.push(network)
  }
  // Built-in networks last: always present, never actionable.
  out.sort(function (a, b) {
    if (a.builtin !== b.builtin) return a.builtin ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  return out
}

// Usage comes from the containers Kaj already watches, not a second command.
// A volume stops being unused on the same event that redraws the container list.
function containerVolumeNames(container) {
  var out = []
  if (!container) return out
  var mounts = container.mounts
  if (!mounts || mounts.length === undefined) return out
  for (var i = 0; i < mounts.length; i++) {
    var name = String(mounts[i] || "")
    if (name !== "" && out.indexOf(name) === -1) out.push(name)
  }
  return out
}

function usersOf(containers, name, pick) {
  var out = []
  if (!containers || containers.length === undefined || !name) return out
  for (var i = 0; i < containers.length; i++) {
    var names = pick(containers[i])
    if (names.indexOf(name) !== -1) out.push(containers[i].name)
  }
  return out
}

function volumeUsers(containers, volumeName) {
  return usersOf(containers, volumeName, containerVolumeNames)
}

// Only running containers. A stopped container keeps the network in its config,
// but its endpoint is gone and Docker will remove the network anyway.
// Volumes are the opposite: docker volume rm refuses while any container uses one.
function networkMembers(containers, networkName) {
  return usersOf(containers, networkName, function (container) {
    if (!container || container.running !== true) return []
    return container.networks && container.networks.length !== undefined
      ? container.networks : []
  })
}

// Unused, or the containers using it, capped so a long list cannot fill the row.
function usageLabel(users) {
  if (!users || users.length === 0) return "unused"
  if (users.length <= 3) return users.join(", ")
  return users.slice(0, 3).join(", ") + " +" + (users.length - 3)
}

function filterByName(list, query) {
  var needle = String(query || "").trim().toLowerCase()
  if (!list || list.length === undefined) return []
  if (needle === "") return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    var haystack = (item.name + " " + (item.project || "") + " " + (item.driver || "")).toLowerCase()
    if (haystack.indexOf(needle) !== -1) out.push(item)
  }
  return out
}

// ---------------------------------------------------------------------------
// Images and disk
// ---------------------------------------------------------------------------

// An image with no repository is dangling: old layers left by a rebuild.
function normalizeImage(raw) {
  if (!raw || typeof raw !== "object") return null
  var repository = sanitizeLine(raw.Repository || "")
  var tag = sanitizeLine(raw.Tag || "")
  var dangling = repository === "" || repository === "<none>"
  return {
    id: shortId(raw.ID),
    repository: dangling ? "" : repository,
    tag: dangling ? "" : (tag === "<none>" ? "" : tag),
    dangling: dangling,
    name: dangling ? "untagged" : (repository + (tag && tag !== "<none>" ? ":" + tag : "")),
    size: parseSize(raw.Size),
    sizeText: sanitizeLine(raw.Size || ""),
    created: sanitizeLine(raw.CreatedSince || ""),
    // How many containers use it. Zero means nothing breaks if it goes.
    containers: parseInt(raw.Containers, 10) || 0
  }
}

function normalizeImages(list) {
  var out = []
  if (!list || list.length === undefined) return out
  for (var i = 0; i < list.length; i++) {
    var image = normalizeImage(list[i])
    if (image && image.id !== "") out.push(image)
  }
  // Largest first: the reason to open this view is to find what is big.
  out.sort(function (a, b) { return b.size - a.size })
  return out
}

// docker system df reports one row per type.
// Reclaimable arrives as "1.2GB (34%)", so the percentage is dropped.
function normalizeDiskRow(raw) {
  if (!raw || typeof raw !== "object") return null
  var reclaimable = String(raw.Reclaimable || "")
  return {
    type: sanitizeLine(raw.Type || ""),
    total: parseInt(raw.TotalCount, 10) || 0,
    active: parseInt(raw.Active, 10) || 0,
    size: parseSize(raw.Size),
    reclaimable: parseSize(reclaimable.split(" ")[0])
  }
}

function normalizeDisk(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var row = normalizeDiskRow(list[i])
    if (row && row.type !== "") out.push(row)
  }
  return out
}

function totalReclaimable(rows) {
  var total = 0
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) total += list[i].reclaimable
  return total
}

function matchesImageQuery(image, query) {
  if (!image) return false
  var needle = str(query).trim().toLowerCase()
  if (needle === "") return true
  return (image.name + " " + image.id).toLowerCase().indexOf(needle) !== -1
}

function filterImages(images, query) {
  var out = []
  var list = Array.isArray(images) ? images : []
  for (var i = 0; i < list.length; i++) {
    if (matchesImageQuery(list[i], query)) out.push(list[i])
  }
  return out
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function formatUptime(startedAtMs, nowMs) {
  if (!startedAtMs) return ""
  var seconds = Math.floor(((nowMs || Date.now()) - startedAtMs) / 1000)
  if (seconds < 0) return ""
  if (seconds < 60) return seconds + "s"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h " + (minutes % 60) + "m"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d " + (hours % 24) + "h"
  return days + "d"
}

// Memory is binary: docker stats prints MiB and --memory 512m means 512 MiB.
// Image and disk sizes stay decimal, which is what Docker reports for them.
function formatMemory(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var index = 0
  while (n >= 1024 && index < units.length - 1) {
    n = n / 1024
    index++
  }
  return (n >= 100 || index === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[index]
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (n >= 1000 && index < units.length - 1) {
    n = n / 1000
    index++
  }
  return (n >= 100 || index === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[index]
}

function formatPercent(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return "0%"
  return (n >= 10 ? Math.round(n) : n.toFixed(1)) + "%"
}

// The line under a container name. Shows why it died, then health, then uptime.
function statusSummary(container, nowMs) {
  if (!container) return ""
  if (container.oomKilled) return "Out of memory"
  if (container.restarting) return "Restarting" + (container.restartCount > 0 ? " ×" + container.restartCount : "")
  if (container.paused) return "Paused"
  if (container.dead) return "Dead"
  if (!container.running) {
    if (container.exitCode !== 0) return "Exited (" + container.exitCode + ")"
    return "Stopped"
  }
  var uptime = formatUptime(container.startedAt, nowMs)
  // A starting container has not been up for anything yet, so time is noise.
  if (container.health === "starting") return "Starting"
  // Unhealthy keeps its uptime: how long it has failed is what you want to know.
  if (container.health === "unhealthy") return "Unhealthy" + (uptime ? " · up " + uptime : "")
  return uptime ? "Up " + uptime : "Running"
}

// Notification daemons render the body as styled text, so markup is escaped
// here. Docker forbids these characters in a container name, which makes this
// a guard against the next caller rather than against today's.
function notificationText(text) {
  return sanitizeLine(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Bar tooltip: one line, no per-container detail.
function barSummary(containers) {
  var list = Array.isArray(containers) ? containers : []
  if (list.length === 0) return "No containers"
  var running = countRunning(list)
  return running + " of " + list.length + " running"
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

// Which actions apply to a container now. Kept here so the set is testable.
function availableActions(container, readOnly) {
  if (!container) return []
  // Logs is all that is left in read-only. A shell can change more than any button.
  if (readOnly === true) return ["logs"]
  if (container.running && !container.paused) return ["stop", "restart", "pause", "logs", "shell"]
  if (container.paused) return ["unpause", "stop", "logs"]
  return ["start", "remove", "logs"]
}

// Every mutation passes through here. True means it needs a confirmation.
// The list is short: friction on start and stop teaches people to click through.
function isDestructive(action) {
  return action === "remove" || action === "removeVolumes" || action === "prune"
    || action === "recreate" || action === "down"
}

// Shown in the confirm dialog. Never built from unsanitized container text.
function confirmText(action, container) {
  var name = container ? container.name : "this container"
  if (action === "remove") return "Remove " + name + "? The container is deleted. Named volumes are kept."
  if (action === "removeVolumes") return "Remove " + name + " and its anonymous volumes? Data in those volumes is lost."
  if (action === "recreate") return "Recreate " + name + "? The current container is replaced."
  return "Continue?"
}

// Verb shown on the confirm button.
function confirmVerb(action) {
  if (action === "remove" || action === "removeVolumes") return "Remove"
  if (action === "recreate") return "Recreate"
  return "Continue"
}
