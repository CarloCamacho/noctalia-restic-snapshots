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
  tooltipKeys() == "Restic,Repository,Mode,Snapshots,Newest snapshot,Last run,Next run", tooltipKeys())
check("no progress row while idle", tooltipFor("Progress") == nil)
check("no error row while healthy", tooltipFor("Error") == nil)

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

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
