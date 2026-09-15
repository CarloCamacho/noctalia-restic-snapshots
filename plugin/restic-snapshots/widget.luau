--!nonstrict
-- Bar module: restic health at a glance.
--
-- [0.2.0] The glyph and the colour carry the state, and the tooltip lists the same fields the
-- panel shows so the two never disagree. Every string comes from a frozen key in
-- translations/en.json.
--
-- [0.3.0] The tooltip also carries the last integrity check and the last restore verification, and a
-- verification that failed -- or that compared nothing and so proved nothing -- gets a short label in
-- the bar next to the staleness readout, because a hover is not a notification.

-- [0.5.0] The bar also carries the shape of the repository: a sparkline of the bytes each recent
-- snapshot added, beside the glyph. It is the one fact a glance can carry that a tooltip cannot.

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

-- The last integrity check, from status.checks = { lastAt, lastOk, numErrors }: the same facts the
-- panel's Run tab shows, so the two never disagree.
local function checkValue()
  local checks = status.checks
  local at = type(checks) == "table" and tonumber(checks.lastAt) or nil
  if at == nil then
    return tr("panel.label.never")
  end
  local errors = tonumber(checks.numErrors) or 0
  local verdictText = tr("panel.label.ok")
  if errors > 0 then
    -- The error count outranks a lastOk of true: a check that reported errors must not read as ok.
    verdictText = tr("panel.label.failed") .. " · " .. tr("panel.label.check_errors", { errors = tostring(errors) })
  elseif checks.lastOk ~= true then
    verdictText = tr("panel.label.failed")
  end
  return ago(at) .. " · " .. verdictText
end

-- The last restore verification, from status.verify. Success is judged on the counts, never on
-- lastOk: a run that compared nothing (checked > 0, matched == 0) publishes lastOk = true and proved
-- nothing, so it reads as "0 of N files matched" rather than as a pass.
local function verifyValue()
  local verify = status.verify
  if type(verify) ~= "table" then
    return tr("panel.label.never_verified")
  end
  local at = tonumber(verify.lastAt)
  local checked = tonumber(verify.checked) or 0
  local matched = tonumber(verify.matched) or 0
  local failed = tonumber(verify.failed) or 0
  local value
  if checked == 0 then
    -- Nothing could be checked at all: the verdict word is all there is to say.
    value = tr("panel.label.failed")
  elseif failed > 0 then
    value = tr("panel.label.failed") .. " · "
      .. tr("panel.label.verified_fail", { failed = tostring(failed), checked = tostring(checked) })
  elseif matched > 0 then
    value = tr("panel.label.ok") .. " · "
      .. tr("panel.label.verified_ok", { matched = tostring(matched), checked = tostring(checked) })
  else
    -- Every file was skipped. Not a success claim and not a failure claim: the counts speak.
    value = tr("panel.label.verified_ok", { matched = "0", checked = tostring(checked) })
  end
  if at ~= nil then
    value = value .. " " .. ago(at)
  end
  return value
end

-- The bar label for a verification the user needs to know about without hovering. Two cases, one
-- short label each: a real mismatch (the same class of problem as a stale repository -- the backup
-- does not restore) and the run that compared nothing (there is no proof the backup restores). Not
-- gated by show_staleness: that setting is about the staleness readout, and a failure is already
-- reported unconditionally through the error colour.
local function verifyHint()
  local verify = status.verify
  if type(verify) ~= "table" then
    return nil
  end
  local checked = tonumber(verify.checked) or 0
  local matched = tonumber(verify.matched) or 0
  local failed = tonumber(verify.failed) or 0
  if checked > 0 and failed > 0 then
    return tr("panel.action.verify") .. ": " .. tr("panel.label.failed"), "error"
  end
  if checked > 0 and matched == 0 and failed == 0 then
    return tr("panel.action.verify") .. ": "
      .. tr("panel.label.verified_ok", { matched = "0", checked = tostring(checked) }), "tertiary"
  end
  return nil
end

-- ── history sparkline (0.5.0) ────────────────────────────────────────────────
-- The bytes each of the last few snapshots added, oldest to newest. A bar widget is a glance, and
-- the thing worth glancing at is the shape of the repository over time: a cluster of full bars is
-- an afternoon of real work, and a long flat run is hours of backups that correctly stored nothing.
local SPARK_POINTS = 20
-- A bar never reaches zero height. With frequent backups most values are legitimately zero, and a
-- graph whose honest reading is "flat along the bottom" is indistinguishable from a broken one, so
-- the floor holds the flat case up where it can be seen and read as flat.
local SPARK_FLOOR = 0.15

local history = {}

-- The status payload carries counts, not per-snapshot history, so this reads the snapshots list.
-- Sorted by the timestamp string, which is ISO 8601 and so sorts chronologically as text.
local function recentAdded(value)
  local rows = type(value) == "table" and value.snapshots or nil
  if type(rows) ~= "table" then
    return {}
  end
  local ordered = {}
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      table.insert(ordered, row)
    end
  end
  if #ordered < 2 then
    return {}
  end
  table.sort(ordered, function(left, right)
    return tostring(left.time or "") < tostring(right.time or "")
  end)
  local series = {}
  local start = #ordered - SPARK_POINTS + 1
  if start < 1 then
    start = 1
  end
  for index = start, #ordered do
    table.insert(series, math.max(0, tonumber(ordered[index].dataAdded) or 0))
  end
  return series
end

local function sparkValues()
  if #history < 2 then
    return nil
  end
  local top = 0
  for _, value in ipairs(history) do
    if value > top then
      top = value
    end
  end
  local out = {}
  for _, value in ipairs(history) do
    local normalised = SPARK_FLOOR
    if top > 0 then
      normalised = SPARK_FLOOR + (1 - SPARK_FLOOR) * (value / top)
    end
    table.insert(out, normalised)
  end
  return out
end

local function render()
  local colour = colourFor()
  local children = {
    ui.glyph({ name = glyphFor(), size = 15, color = colour }),
  }

  local spark = sparkValues()
  if spark ~= nil then
    table.insert(children, ui.graph({
      key = "history-spark",
      values = spark,
      color = colour,
      height = 14,
      width = 46,
      lineWidth = 1,
      fillOpacity = 0.15,
    }))
  end

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

  -- A verification that failed, or that compared nothing, is labelled in the bar itself: the tooltip
  -- is only read on hover, and "the backup does not restore" / "nothing proved the backup restores"
  -- are exactly the facts this widget exists to surface.
  local hintText, hintColor = verifyHint()
  if hintText ~= nil then
    table.insert(children, ui.label({ key = "verify-hint", text = hintText, color = hintColor, fontSize = 11 }))
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

  -- The two results the panel's Run tab shows beside the last run, in the same order.
  row(tr("panel.label.last_check"), checkValue())
  row(tr("panel.label.last_verified"), verifyValue())

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

noctalia.state.watch(state.KEY_SNAPSHOTS, function(value)
  history = recentAdded(value)
  render()
end)

render()
