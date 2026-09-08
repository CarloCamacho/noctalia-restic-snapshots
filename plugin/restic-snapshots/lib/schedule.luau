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

return M
