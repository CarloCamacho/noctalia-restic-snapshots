--!nonstrict
-- Bar module: restic health at a glance.

local restic = require("./lib/restic.luau")
local schedule = require("./lib/schedule.luau")
local state = require("./lib/state.luau")

local status = state.migrate(noctalia.state.get(state.KEY_STATUS))

local function nowSec()
  return math.floor(noctalia.nowMs() / 1000)
end

local function colourFor()
  if not status.available then
    return "on_surface/0.5"
  end
  if not status.repoConfigured then
    return "on_surface/0.5"
  end
  if status.phase == "running" then
    return "primary"
  end
  if status.error ~= nil and status.error ~= "" then
    return "error"
  end
  return "on_surface"
end

local function render()
  local colour = colourFor()
  local children = {
    ui.glyph({ name = status.phase == "running" and "loader-2" or "archive", size = 15, color = colour }),
  }

  if noctalia.getConfig("show_count") == true then
    table.insert(children, ui.label({ text = tostring(status.snapshotCount or 0), color = colour }))
  end

  -- [0.2.0] staleness readout. `status.stale` / `status.staleness` are published by the service;
  -- the label stays out of the bar unless the snapshot age actually crossed the threshold.
  if noctalia.getConfig("show_staleness") == true and status.stale == true and status.staleness ~= nil then
    table.insert(children, ui.label({
      text = string.format("%.0fh", tonumber(status.staleness) or 0),
      color = "error",
      fontSize = 11,
    }))
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, children))

  local rows = {}
  local function row(key, value)
    table.insert(rows, { key = key, value = tostring(value) })
  end

  if not status.available then
    row("Restic", "not installed")
  else
    row("Restic", status.version ~= "" and status.version or "installed")
    row("Repository", status.repoConfigured and status.repository or "not configured")
    row("Mode", status.mode)
    row("Snapshots", status.snapshotCount or 0)
    if status.newestSnapshotAt ~= nil then
      row("Newest snapshot", restic.ageLabel(nowSec() - status.newestSnapshotAt) .. " ago")
    end
    if status.stale == true then
      row("Stale", status.staleness ~= nil and (string.format("%.0fh", status.staleness) .. " old") or "yes")
    end
    if status.job ~= nil and status.job.percent ~= nil then
      row("Progress", string.format("%.0f%%", tonumber(status.job.percent) * 100))
    end
    if status.lastRun ~= nil then
      local state_ = status.lastRun.cancelled == true and "cancelled"
        or (status.lastRun.ok and "ok" or "failed")
      row("Last run", state_ .. " " .. restic.ageLabel(nowSec() - (status.lastRun.at or nowSec())) .. " ago")
    else
      row("Last run", "never")
    end
    row("Next run", schedule.untilLabel(nowSec(), status.nextRun))
  end
  if status.error ~= nil and status.error ~= "" then
    row("Error", status.error)
  end

  barWidget.setTooltip(rows)
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("carlocamacho/restic-snapshots:browser")
end

noctalia.state.watch(state.KEY_STATUS, function(value)
  status = state.migrate(value)
  render()
end)

render()
