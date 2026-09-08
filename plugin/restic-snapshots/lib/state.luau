--!nonstrict
-- Shared state keys and schema.

local M = {}

M.SCHEMA = 1

M.KEY_STATUS = "restic_status"
M.KEY_SNAPSHOTS = "restic_snapshots"
M.KEY_JOB = "restic_job"

M.EVENT_REFRESH = "refresh"
M.EVENT_BACKUP = "backup-now"
M.EVENT_CHECK = "check"
M.EVENT_FORGET_DRY = "forget-dry-run"
M.EVENT_FORGET = "forget"
M.EVENT_RESTORE = "restore"
M.EVENT_CANCEL = "cancel"

function M.emptyStatus()
  return {
    schema = M.SCHEMA,
    updatedAt = 0,
    available = false,
    version = "",
    repository = "",
    repoConfigured = false,
    mode = "plugin",
    phase = "idle",       -- idle | running | error
    lastRun = nil,        -- { at, ok, summary }
    nextRun = nil,        -- epoch seconds
    snapshotCount = 0,
    busy = false,
    error = "",
  }
end

function M.migrate(value)
  if type(value) ~= "table" then
    return M.emptyStatus()
  end
  if value.schema ~= M.SCHEMA then
    local fresh = M.emptyStatus()
    for key, existing in pairs(value) do
      if fresh[key] ~= nil then
        fresh[key] = existing
      end
    end
    return fresh
  end
  return value
end

return M
