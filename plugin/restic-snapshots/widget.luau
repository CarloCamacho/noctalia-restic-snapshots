--!nonstrict
-- Bar module: restic health at a glance.
--
-- [0.2.0] The glyph and the colour carry the state, and the tooltip lists the same fields the
-- panel shows so the two never disagree. Every string comes from a frozen key in
-- translations/en.json.

local restic = require("./lib/restic.luau")
local schedule = require("./lib/schedule.luau")
local state = require("./lib/state.luau")

local status = state.migrate(noctalia.state.get(state.KEY_STATUS))

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nowSec()
  return math.floor(noctalia.nowMs() / 1000)
end

local function running()
  return status.phase == "running" or status.busy == true
end

local function usable()
  return status.available == true and status.repoConfigured == true
end

-- Glyph and colour by state, in this order: not installed / not configured are dimmed, running is
-- accented, an error is red, stale is red too, and anything else is plain.
local function colourFor()
  if not usable() then
    -- Nothing can run yet, so the widget stays neutral rather than alarming: there is no failure
    -- to report, only a missing setup step.
    return "on_surface/0.5"
  end
  if running() then
    return "primary"
  end
  if status.error ~= nil and status.error ~= "" then
    return "error"
  end
  -- Stale is deliberately the SAME error colour as a failure: a newest snapshot past the threshold
  -- means backups have silently stopped, which is the same class of problem as a failing job. A
  -- softer role (tertiary) would read as informational and be easy to ignore in a bar.
  if status.stale == true then
    return "error"
  end
  return "on_surface"
end

local function glyphFor()
  if running() then
    return "loader-2"
  end
  if not usable() then
    -- An unusable plugin says so with the glyph as well as the colour.
    return "archive-off"
  end
  return "archive"
end

local function ago(at)
  return tr("panel.label.ago", { age = restic.ageLabel(nowSec() - at) })
end

local function modeLabel()
  if status.mode == "observe" then
    return tr("settings.mode.observe")
  end
  return tr("settings.mode.plugin")
end

-- ok / failed / cancelled, the same three verdicts the Run tab and the Log tab use.
local function verdict()
  local last = status.lastRun
  if type(last) ~= "table" then
    return tr("panel.label.never")
  end
  if last.cancelled == true then
    return tr("panel.label.cancelled")
  end
  if last.ok == true then
    return tr("panel.label.ok")
  end
  return tr("panel.label.failed")
end

local function render()
  local colour = colourFor()
  local children = {
    ui.glyph({ name = glyphFor(), size = 15, color = colour }),
  }

  if noctalia.getConfig("show_count") == true then
    table.insert(children, ui.label({ text = tostring(status.snapshotCount or 0), color = colour }))
  end

  -- Staleness readout: the age of the newest snapshot, shown only once it crossed the threshold
  -- the service computed. `status.stale` is set by the service's staleness guardian.
  if noctalia.getConfig("show_staleness") == true and status.stale == true and status.staleness ~= nil then
    table.insert(children, ui.label({
      text = tr("widget.label.stale", { age = restic.ageLabel((tonumber(status.staleness) or 0) * 3600) }),
      color = "error",
      fontSize = 11,
    }))
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, children))

  local rows = {}
  local function row(key, value)
    table.insert(rows, { key = key, value = tostring(value) })
  end

  if status.available ~= true then
    row(tr("widget.row.restic"), tr("panel.label.not_installed"))
  elseif type(status.version) == "string" and status.version ~= "" then
    row(tr("widget.row.restic"), status.version)
  else
    row(tr("widget.row.restic"), tr("panel.label.installed"))
  end

  -- status.repository is ALREADY redacted by the service; the widget must not redact it again.
  row(tr("widget.row.repository"),
    status.repoConfigured == true and status.repository or tr("panel.label.not_configured"))
  row(tr("widget.row.mode"), modeLabel())
  row(tr("widget.row.snapshots"), status.snapshotCount or 0)

  if status.newestSnapshotAt ~= nil then
    row(tr("widget.row.newest"), ago(status.newestSnapshotAt))
  end

  local last = status.lastRun
  if type(last) == "table" then
    row(tr("widget.row.last_run"), verdict() .. " " .. ago(last.at or nowSec()))
  else
    row(tr("widget.row.last_run"), tr("panel.label.never"))
  end

  row(tr("widget.row.next_run"), schedule.untilLabel(nowSec(), status.nextRun))

  if type(status.job) == "table" and status.job.percent ~= nil then
    row(tr("widget.row.progress"), tr("widget.label.progress", {
      percent = string.format("%.0f", (tonumber(status.job.percent) or 0) * 100),
    }))
  end

  if status.error ~= nil and status.error ~= "" then
    row(tr("widget.row.error"), status.error)
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
