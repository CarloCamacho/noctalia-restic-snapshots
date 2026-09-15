--!nonstrict
-- Real render-tree assertions for the widget entry (Restic Snapshots 0.2.0).
-- Run from the repo root:  lua5.4 tests/lua/widget_render_test.lua
--
-- [0.2.0] Updated for the new contract: the widget colours and glyphs by state (unusable is
-- dimmed, running is accented, error AND stale are red), the tooltip carries the documented rows,
-- and every string comes from translations/en.json through noctalia.tr.

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.install("plugin/restic-snapshots")

-- ── translations ─────────────────────────────────────────────────────────────
-- Same shim as the panel test: the harness stub returns the key, so read the real catalogue and do
-- the {name} substitution the host does. REQUESTED lists the keys this workstream needs that
-- en.json does not carry yet (translations are owned by another workstream -- see the report).

local REQUESTED = {
  ["panel.label.ago"] = "{age} ago",
  ["panel.label.installed"] = "installed",
}

local CATALOGUE = {}
do
  local handle = io.open("plugin/restic-snapshots/translations/en.json", "rb")
  if handle ~= nil then
    local text = handle:read("*a")
    handle:close()
    for key, value in (text or ""):gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
      CATALOGUE[key] = value
    end
  end
end

local function tr(key, subst)
  local template = CATALOGUE[key] or REQUESTED[key]
  if template == nil then
    return key
  end
  if type(subst) ~= "table" then
    return template
  end
  return (template:gsub("{(%w+)}", function(name)
    local value = subst[name]
    if value == nil then
      return "{" .. name .. "}"
    end
    return tostring(value)
  end))
end

noctalia.tr = tr
noctalia.trp = function(key, count, subst)
  return tr(key, subst)
end

-- ── fixtures ─────────────────────────────────────────────────────────────────

H.stateValues["restic_status"] = {
  schema = 2,
  updatedAt = 1788874602,
  available = true,
  version = "0.19.1",
  repository = "/tmp/repo",
  repoConfigured = true,
  mode = "plugin",
  phase = "idle",
  busy = false,
  lastRun = { at = 1788874502, ok = true, files = 2, bytes = 2048, added = 1024 },
  nextRun = 1788878202,
  snapshotCount = 3,
  newestSnapshotAt = 1788873300,
  staleness = 21,
  stale = false,
  error = "",
}

H.load("widget.luau")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

local function glyph()
  return H.find(H.tree, H.byType("glyph"))
end

local function tooltipFor(key)
  for _, row in ipairs(H.tooltip or {}) do
    if row.key == key then
      return row.value
    end
  end
  return nil
end

local function tooltipKeys()
  local keys = {}
  for _, row in ipairs(H.tooltip or {}) do
    if row.key ~= nil then
      table.insert(keys, row.key)
    end
  end
  return table.concat(keys, ",")
end

-- ── idle ─────────────────────────────────────────────────────────────────────

check("widget renders an icon", glyph() ~= nil)
check("idle widget uses the archive glyph", glyph() ~= nil and glyph().props.name == "archive",
  glyph() ~= nil and glyph().props.name)
check("idle widget is not accented", glyph() ~= nil and glyph().props.color == "on_surface",
  glyph() ~= nil and glyph().props.color)
check("count hidden by default", H.find(H.tree, H.byType("label")) == nil)

check("tooltip shows the repository", tooltipFor("Repository") == "/tmp/repo", tostring(tooltipFor("Repository")))
check("tooltip shows the mode", tooltipFor("Mode") == "Run backups from this plugin", tostring(tooltipFor("Mode")))
check("tooltip shows the snapshot count", tooltipFor("Snapshots") == "3", tostring(tooltipFor("Snapshots")))
check("tooltip shows the newest snapshot age", tostring(tooltipFor("Newest snapshot")):find("21m", 1, true) ~= nil,
  tostring(tooltipFor("Newest snapshot")))
check("tooltip shows last run", tostring(tooltipFor("Last run")):find("ok", 1, true) ~= nil, tostring(tooltipFor("Last run")))
check("tooltip shows the next run", tostring(tooltipFor("Next run")):find("in ", 1, true) ~= nil, tostring(tooltipFor("Next run")))
check("tooltip shows the restic version", tooltipFor("Restic") == "0.19.1", tostring(tooltipFor("Restic")))
check("tooltip carries the documented rows",
  tooltipKeys() == "Restic,Repository,Mode,Snapshots,Newest snapshot,Last run,Last check,Last verified,Next run",
  tooltipKeys())
check("no progress row while idle", tooltipFor("Progress") == nil)
check("no error row while healthy", tooltipFor("Error") == nil)
check("the check row reads never before any check", tooltipFor("Last check") == "never",
  tostring(tooltipFor("Last check")))
check("the verification row reads never before any verification", tooltipFor("Last verified") == "never",
  tostring(tooltipFor("Last verified")))
check("no verification hint in the bar when nothing was verified",
  H.find(H.tree, H.byKey("verify-hint")) == nil, H.text(H.tree))

-- ── running ──────────────────────────────────────────────────────────────────

H.stateValues["restic_status"].phase = "running"
H.stateValues["restic_status"].busy = true
H.stateValues["restic_status"].job = { kind = "backup", percent = 0.42 }
update()
check("running widget uses a spinner", glyph() ~= nil and glyph().props.name == "loader-2",
  glyph() ~= nil and glyph().props.name)
check("running widget is accented", glyph() ~= nil and glyph().props.color == "primary",
  glyph() ~= nil and glyph().props.color)
check("tooltip shows progress", tostring(tooltipFor("Progress")):find("42", 1, true) ~= nil,
  tostring(tooltipFor("Progress")))
check("progress row is a percentage", tooltipFor("Progress") == "42%", tostring(tooltipFor("Progress")))

H.stateValues["restic_status"].phase = "idle"
H.stateValues["restic_status"].busy = false
H.stateValues["restic_status"].job = nil

-- ── unavailable ──────────────────────────────────────────────────────────────

H.stateValues["restic_status"].available = false
update()
check("missing restic is dimmed", glyph() ~= nil and glyph().props.color == "on_surface/0.5",
  glyph() ~= nil and glyph().props.color)
check("missing restic uses the disabled glyph", glyph() ~= nil and glyph().props.name == "archive-off",
  glyph() ~= nil and glyph().props.name)
check("missing restic is named in the tooltip", tooltipFor("Restic") == "not installed",
  tostring(tooltipFor("Restic")))

-- ── not configured ───────────────────────────────────────────────────────────

H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].repoConfigured = false
update()
check("unconfigured repository is dimmed", glyph() ~= nil and glyph().props.color == "on_surface/0.5",
  glyph() ~= nil and glyph().props.color)
check("unconfigured repository is named in the tooltip", tooltipFor("Repository") == "not configured",
  tostring(tooltipFor("Repository")))
H.stateValues["restic_status"].repoConfigured = true

-- ── error ────────────────────────────────────────────────────────────────────

H.stateValues["restic_status"].error = "snapshots failed"
update()
check("error state uses the error colour", glyph() ~= nil and glyph().props.color == "error",
  glyph() ~= nil and glyph().props.color)
check("error state is named in the tooltip", tooltipFor("Error") == "snapshots failed",
  tostring(tooltipFor("Error")))

-- ── stale ────────────────────────────────────────────────────────────────────
-- Stale shares the error colour on purpose: backups have silently stopped, which is the same class
-- of problem as a failing job.

H.stateValues["restic_status"].error = ""
H.stateValues["restic_status"].stale = true
H.stateValues["restic_status"].staleness = 30
update()
check("stale state uses the error colour", glyph() ~= nil and glyph().props.color == "error",
  glyph() ~= nil and glyph().props.color)
check("stale state keeps the archive glyph", glyph() ~= nil and glyph().props.name == "archive",
  glyph() ~= nil and glyph().props.name)
check("staleness label appears when enabled",
  H.text(H.tree):find("stale 1d", 1, true) ~= nil, H.text(H.tree))

H.config.show_staleness = false
update()
check("staleness label hides when disabled", H.find(H.tree, H.byType("label")) == nil, H.text(H.tree))
H.config.show_staleness = true
update()

-- ── run verdicts ─────────────────────────────────────────────────────────────

H.stateValues["restic_status"].stale = false
H.stateValues["restic_status"].lastRun = { at = 1788874502, ok = false, cancelled = true, files = 1, bytes = 512, added = 0 }
update()
check("a cancelled run is not reported as failed",
  tostring(tooltipFor("Last run")):find("cancelled", 1, true) ~= nil, tostring(tooltipFor("Last run")))
H.stateValues["restic_status"].lastRun = { at = 1788874502, ok = false, files = 1, bytes = 512, added = 0 }
update()
check("a failed run is reported as failed",
  tostring(tooltipFor("Last run")):find("failed", 1, true) ~= nil, tostring(tooltipFor("Last run")))
H.stateValues["restic_status"].lastRun = nil
update()
check("no run recorded reads as never", tooltipFor("Last run") == "never", tostring(tooltipFor("Last run")))
H.stateValues["restic_status"].lastRun = { at = 1788874502, ok = true, files = 2, bytes = 2048, added = 1024 }

-- ── count toggle ─────────────────────────────────────────────────────────────

H.config.show_count = true
update()
check("count label appears when enabled", H.text(H.tree):find("3", 1, true) ~= nil, H.text(H.tree))
check("count label uses the state colour", glyph() ~= nil and glyph().props.color == "on_surface",
  glyph() ~= nil and glyph().props.color)

-- ── the last check and the last verification (0.3.0) ────────────────────────
-- status.checks = { lastAt, lastOk, numErrors } and status.verify = { lastAt, lastOk, checked,
-- matched, failed, detail } are what the service publishes. The tooltip carries both next to the
-- last run, and a verification the user must act on is labelled in the bar itself.

H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = true, numErrors = 0 }
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = true, checked = 4, matched = 4, failed = 0, detail = "4 of 4 files matched",
}
update()
check("tooltip shows a passing check",
  tooltipFor("Last check") == "1h ago · ok", tostring(tooltipFor("Last check")))
check("tooltip shows a passed verification with its counts",
  tooltipFor("Last verified") == "ok · 4 of 4 files matched 6m ago", tostring(tooltipFor("Last verified")))
check("a passed verification adds no bar label",
  H.find(H.tree, H.byKey("verify-hint")) == nil, H.text(H.tree))

-- An errored check is reported as such, not silently green.
H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = false, numErrors = 3 }
update()
check("tooltip reports an errored check",
  tooltipFor("Last check") == "1h ago · failed · 3 errors", tostring(tooltipFor("Last check")))
H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = true, numErrors = 3 }
update()
check("an error count outranks a lastOk of true in the tooltip",
  tooltipFor("Last check") == "1h ago · failed · 3 errors", tostring(tooltipFor("Last check")))
H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = true, numErrors = 0 }

-- A failed verification reads as a failure in the tooltip, and the bar carries a label.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = false, checked = 3, matched = 1, failed = 2,
  detail = "2 of 3 checked files do not match the backup: /home/ian/dots/x",
}
update()
check("tooltip reports a failed verification with its counts",
  tooltipFor("Last verified") == "failed · 2 of 3 files did not match 6m ago",
  tostring(tooltipFor("Last verified")))
local hint = H.find(H.tree, H.byKey("verify-hint"))
check("a failed verification is labelled in the bar", hint ~= nil)
check("the bar label names the feature and the failure",
  hint ~= nil and hint.props.text == "Verify restore: failed", hint ~= nil and hint.props.text)
check("the bar label uses the error colour", hint ~= nil and hint.props.color == "error",
  hint ~= nil and hint.props.color)

-- The honesty case: checked > 0 with nothing compared. The service publishes lastOk = true, and the
-- widget must not read that as a verification.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = true, checked = 3, matched = 0, failed = 0,
  detail = "3 file(s) restored and read back, but none could be compared with a live file",
}
update()
check("an all-skipped verification does not read as ok in the tooltip",
  tooltipFor("Last verified") == "0 of 3 files matched 6m ago", tostring(tooltipFor("Last verified")))
hint = H.find(H.tree, H.byKey("verify-hint"))
check("an all-skipped verification is hinted in the bar",
  hint ~= nil and hint.props.text == "Verify restore: 0 of 3 files matched",
  hint ~= nil and hint.props.text)
check("the hint for a run that proved nothing is not a success colour",
  hint ~= nil and hint.props.color == "tertiary", hint ~= nil and hint.props.color)

-- A verification that could not run at all: failed, with nothing to count.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = false, checked = 0, matched = 0, failed = 0,
  detail = "there is no snapshot to verify",
}
update()
check("a verification that could not run reads as failed",
  tooltipFor("Last verified") == "failed 6m ago", tostring(tooltipFor("Last verified")))
check("a verification that could not run adds no counts to the tooltip",
  tostring(tooltipFor("Last verified")):find("of 0", 1, true) == nil, tostring(tooltipFor("Last verified")))

H.stateValues["restic_status"].checks = nil
H.stateValues["restic_status"].verify = nil
update()
check("the check row goes back to never", tooltipFor("Last check") == "never", tostring(tooltipFor("Last check")))
check("the verification row goes back to never",
  tooltipFor("Last verified") == "never", tostring(tooltipFor("Last verified")))

-- ── click behaviour ──────────────────────────────────────────────────────────

local toggled = nil
noctalia.togglePanel = function(id)
  toggled = id
end
onClick()
check("clicking the widget opens the panel",
  toggled == "carlocamacho/restic-snapshots:browser", tostring(toggled))

-- ── shortcut tile ────────────────────────────────────────────────────────────
-- The control-center tile reads the same status, and the gate runs only the two lua suites this
-- workstream owns, so it is exercised here rather than in a new file.

H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].repoConfigured = true
H.load("shortcut.luau")
check("tile names the action", H.shortcutLabel == "Back up now", tostring(H.shortcutLabel))
check("tile offers both icons", type(H.shortcutIcon) == "table" and H.shortcutIcon[1] == "archive"
  and H.shortcutIcon[2] == "archive-off", tostring(H.shortcutIcon and H.shortcutIcon[1]))
check("tile is enabled when restic and the repository are ready", H.shortcutEnabled == true)
onClick()
check("one tap starts a backup", table.concat(H.commands[#H.commands] or {}, " "):find("backup-now", 1, true) ~= nil,
  table.concat(H.commands[#H.commands] or {}, " "))

H.stateValues["restic_status"].phase = "running"
update()
check("tile marks itself active while running", H.shortcutActive == true)
H.stateValues["restic_status"].phase = "idle"

H.stateValues["restic_status"].available = false
update()
check("tile disables without restic", H.shortcutEnabled == false)
H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].repoConfigured = false
update()
check("tile disables without a repository", H.shortcutEnabled == false)

-- ── history sparkline (0.5.0) ────────────────────────────────────────────────
-- The bar carries the repository's shape beside the glyph. It reads the snapshots list rather than
-- the status payload, so before any snapshot history is published there is nothing to draw and the
-- widget must render exactly as it did -- which every check above this line has already proved.

local function publishSnapshots(snapshots)
  local value = { schema = 2, updatedAt = 1788874602, snapshots = snapshots }
  H.stateValues["restic_snapshots"] = value
  local watch = H.stateValues["__watch_restic_snapshots"]
  if watch ~= nil then
    watch(value)
  end
  update()
end

-- The shortcut tile loaded above owns the global update() from here on, and it left the status
-- unconfigured, so the widget's tree is stale. Publishing an empty history forces a fresh render of
-- the widget -- through its own state watch -- so the glyph comparison at the end of this block is
-- between two renders of the same status rather than between a fresh one and a stale one.
H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].repoConfigured = true
publishSnapshots({})

check("no sparkline while no snapshot history exists", H.find(H.tree, H.byType("graph")) == nil)
local glyphBefore = glyph() ~= nil and glyph().props.name or nil
check("a usable widget with no history leads with the archive glyph", glyphBefore == "archive",
  tostring(glyphBefore))

publishSnapshots({
  { id = "a", time = "2026-09-08T20:00:00+08:00", dataAdded = 0 },
  { id = "b", time = "2026-09-08T21:00:00+08:00", dataAdded = 0 },
  { id = "c", time = "2026-09-08T22:00:00+08:00", dataAdded = 4096 },
})
local spark = H.find(H.tree, H.byType("graph"))
check("a sparkline appears once snapshot history exists", spark ~= nil)
check("the sparkline has one point per snapshot",
  spark ~= nil and #spark.props.values == 3, spark ~= nil and tostring(#spark.props.values) or "no graph")
check("the point for the snapshot that added data is the tallest",
  spark ~= nil and spark.props.values[3] > spark.props.values[1],
  spark ~= nil and (tostring(spark.props.values[3]) .. " vs " .. tostring(spark.props.values[1])) or "no graph")
-- An honest reading of an idle repository is "flat", and a line pinned along the floor is
-- indistinguishable from a graph that failed to draw. The floor is what keeps those apart.
check("no point sits at zero, so a flat repository reads as flat and not as broken",
  spark ~= nil and spark.props.values[1] > 0, spark ~= nil and tostring(spark.props.values[1]) or "no graph")
check("no point exceeds the box", spark ~= nil and spark.props.values[3] <= 1,
  spark ~= nil and tostring(spark.props.values[3]) or "no graph")
check("the sparkline does not disturb the glyph",
  spark ~= nil and glyph() ~= nil and glyph().props.name == glyphBefore,
  tostring(glyphBefore) .. " -> " .. tostring(glyph() ~= nil and glyph().props.name))

-- The list arrives newest-first in places and oldest-first in others: the series must be built from
-- the timestamps, not from the array order, or the shape reads backwards.
publishSnapshots({
  { id = "c", time = "2026-09-08T22:00:00+08:00", dataAdded = 4096 },
  { id = "a", time = "2026-09-08T20:00:00+08:00", dataAdded = 0 },
  { id = "b", time = "2026-09-08T21:00:00+08:00", dataAdded = 0 },
})
local reversed = H.find(H.tree, H.byType("graph"))
check("the series is ordered by time, whatever order the rows arrive in",
  reversed ~= nil and reversed.props.values[3] > reversed.props.values[1],
  reversed ~= nil and (tostring(reversed.props.values[3]) .. " vs " .. tostring(reversed.props.values[1]))
    or "no graph")

publishSnapshots({})
check("the sparkline goes away when the history does", H.find(H.tree, H.byType("graph")) == nil)

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
