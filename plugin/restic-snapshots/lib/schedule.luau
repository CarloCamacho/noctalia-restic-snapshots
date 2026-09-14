--!nonstrict
-- Schedule arithmetic. Pure, so it is unit-testable.

local M = {}

-- Next run at least `intervalMinutes` after `lastRun`, rounded up to a whole minute.
-- Returns epoch seconds.
function M.nextRun(nowSec, intervalMinutes, lastRunSec)
  local interval = math.max(5, math.floor(tonumber(intervalMinutes) or 60)) * 60
  local base = tonumber(lastRunSec) or tonumber(nowSec) or 0
  local nextAt = base + interval
  if nextAt <= nowSec then
    -- Overdue (shell was off): run a full interval from now rather than immediately
    -- stampeding on startup.
    nextAt = nowSec + interval
  end
  return math.floor(nextAt)
end

function M.due(nowSec, nextRunSec)
  if nextRunSec == nil then
    return false
  end
  return tonumber(nowSec) >= tonumber(nextRunSec)
end

-- Human label for the next run, e.g. "in 42m".
function M.untilLabel(nowSec, nextRunSec)
  if nextRunSec == nil then
    return "not scheduled"
  end
  local delta = math.floor(tonumber(nextRunSec) - tonumber(nowSec))
  if delta <= 0 then
    return "due now"
  end
  if delta < 60 then
    return string.format("in %ds", delta)
  end
  if delta < 3600 then
    return string.format("in %dm", math.floor(delta / 60))
  end
  return string.format("in %dh", math.floor(delta / 3600))
end

-- ── staleness ────────────────────────────────────────────────────────────────
-- Staleness is measured against the *repository*, not against our own last run, so it says
-- something useful in observe mode too: if the newest snapshot is old, whoever was supposed to
-- write it did not.

-- Hours after which a repository counts as stale. An explicit setting wins; otherwise two
-- backup intervals (a single missed run is a late backup, two is a missed one), with a floor of
-- two hours so a 5-minute test interval does not flap.
function M.staleThresholdHours(cfg)
  local explicit = tonumber(cfg ~= nil and cfg.staleAfterHours or nil) or 0
  if explicit > 0 then
    return explicit
  end
  local intervalMinutes = tonumber(cfg ~= nil and cfg.intervalMinutes or nil) or 60
  return math.max(2 * intervalMinutes / 60, 2)
end

-- Strictly older than the threshold: exactly at it is late, not yet stale. An unknown newest
-- snapshot (empty repository, unreadable time) is never stale -- there is nothing to compare.
function M.isStale(nowSec, newestSnapshotAt, thresholdHours)
  local newest = tonumber(newestSnapshotAt)
  local threshold = tonumber(thresholdHours)
  if newest == nil or threshold == nil or threshold <= 0 then
    return false
  end
  local now = tonumber(nowSec) or 0
  return (now - newest) > threshold * 3600
end

-- ── integrity checks ─────────────────────────────────────────────────────────

-- True when a scheduled check is due. A check that has never run is due, so switching the
-- interval on in the settings takes effect instead of waiting out a whole interval.
function M.checkDue(nowSec, lastCheckAt, intervalHours)
  local interval = tonumber(intervalHours)
  if interval == nil or interval <= 0 then
    return false
  end
  local last = tonumber(lastCheckAt)
  if last == nil then
    return true
  end
  return tonumber(nowSec) >= last + interval * 3600
end

-- The `--read-data-subset` value for one slot of the rotation. `index` is a zero-based counter
-- that wraps, so the series walks 1/total, 2/total ... total/total, 1/total ... and every part
-- of the repository is read over time without ever reading all of it in one run.
function M.subsetForIndex(index, total)
  local size = math.floor(tonumber(total) or 0)
  if size < 1 then
    size = 1
  end
  local slot = math.floor(tonumber(index) or 0) % size + 1
  return string.format("%d/%d", slot, size)
end

return M
