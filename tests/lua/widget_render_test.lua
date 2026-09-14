--!nonstrict
-- Real render-tree assertions for the widget entry.
-- Run from the repo root:  lua5.4 tests/lua/widget_render_test.lua

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.install("plugin/restic-snapshots")

H.stateValues["restic_status"] = {
  schema = 2,
  updatedAt = 1788874602,
  available = true,
  version = "0.19.1",
  repository = "/tmp/repo",
  repoConfigured = true,
  mode = "plugin",
  phase = "idle",
  lastRun = { at = 1788874502, ok = true, files = 2, bytes = 2048, added = 1024 },
  nextRun = 1788878202,
  snapshotCount = 3,
  busy = false,
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

local glyph = H.find(H.tree, H.byType("glyph"))
check("widget renders an icon", glyph ~= nil)
check("idle widget uses the archive glyph", glyph ~= nil and glyph.props.name == "archive",
  glyph ~= nil and glyph.props.name)
check("idle widget is not accented", glyph ~= nil and glyph.props.color == "on_surface",
  glyph ~= nil and glyph.props.color)
check("count hidden by default", H.find(H.tree, H.byType("label")) == nil)

local function tooltipFor(key)
  for _, row in ipairs(H.tooltip or {}) do
    if row.key == key then return row.value end
  end
  return nil
end
check("tooltip shows the repository", tooltipFor("Repository") == "/tmp/repo", tostring(tooltipFor("Repository")))
check("tooltip shows the snapshot count", tooltipFor("Snapshots") == "3", tostring(tooltipFor("Snapshots")))
check("tooltip shows last run", tostring(tooltipFor("Last run")):find("ok") ~= nil, tostring(tooltipFor("Last run")))
check("tooltip shows the next run", tostring(tooltipFor("Next run")):find("in ") ~= nil, tostring(tooltipFor("Next run")))

-- Running state
H.stateValues["restic_status"].phase = "running"
H.stateValues["restic_status"].job = { kind = "backup", percent = 0.42 }
update()
glyph = H.find(H.tree, H.byType("glyph"))
check("running widget uses a spinner", glyph ~= nil and glyph.props.name == "loader-2",
  glyph ~= nil and glyph.props.name)
check("running widget is accented", glyph ~= nil and glyph.props.color == "primary",
  glyph ~= nil and glyph.props.color)
check("tooltip shows progress", tostring(tooltipFor("Progress")):find("42") ~= nil, tostring(tooltipFor("Progress")))

-- Missing binary
H.stateValues["restic_status"].phase = "idle"
H.stateValues["restic_status"].available = false
update()
glyph = H.find(H.tree, H.byType("glyph"))
check("missing restic is dimmed", glyph ~= nil and glyph.props.color == "on_surface/0.5",
  glyph ~= nil and glyph.props.color)
check("missing restic is named in the tooltip", tooltipFor("Restic") == "not installed",
  tostring(tooltipFor("Restic")))

-- Error state
H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].error = "snapshots failed"
update()
glyph = H.find(H.tree, H.byType("glyph"))
check("error state uses the error colour", glyph ~= nil and glyph.props.color == "error",
  glyph ~= nil and glyph.props.color)

-- Count toggle
H.config.show_count = true
H.stateValues["restic_status"].error = ""
update()
check("count label appears when enabled", H.text(H.tree):find("3") ~= nil, H.text(H.tree))

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
