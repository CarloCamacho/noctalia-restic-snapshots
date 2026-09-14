--!nonstrict
-- Shared state keys, event names and the status shape.
--
-- FROZEN for the 0.2.0 work: the service writes these fields and the panel/widget read them,
-- so both sides must agree exactly. See docs/CONTRACTS-0.2.0.md. Add a field here first, then
-- use it -- never ad hoc in one entry.

local M = {}

M.SCHEMA = 2

-- ── state keys ───────────────────────────────────────────────────────────────

M.KEY_STATUS = "restic_status"      -- the status table described below
M.KEY_SNAPSHOTS = "restic_snapshots" -- { schema, updatedAt, snapshots = { row, ... } }
M.KEY_JOB = "restic_job"            -- forget-dry preview / last-job footer
M.KEY_JOBLOG = "restic_joblog"      -- { kind, at, ok, cancelled, exitCode, lines, truncated }
M.KEY_STATS = "restic_stats"        -- { totalBytes, totalFileCount, snapshotsCount, updatedAt }
M.KEY_FILES = "restic_files"        -- { snapshot, entries, truncated, at }
M.KEY_DIFF = "restic_diff"          -- { from, to, added, removed, changed, truncated, at, ok }

-- ── events (payload: a JSON string, or nothing) ──────────────────────────────

M.EVENT_REFRESH = "refresh"
M.EVENT_BACKUP = "backup-now"
M.EVENT_CHECK = "check"
M.EVENT_FORGET_DRY = "forget-dry-run"
M.EVENT_FORGET = "forget"
M.EVENT_FORGET_ONE = "forget-one"         -- { snapshot }
M.EVENT_RESTORE_DRY = "restore-dry-run"   -- { snapshot, target?, include? }
M.EVENT_RESTORE = "restore"               -- { snapshot, target?, include?, verify? }
M.EVENT_CANCEL = "cancel"
M.EVENT_STATS = "stats"
M.EVENT_LS = "ls"                         -- { snapshot }
M.EVENT_DIFF = "diff"                     -- { from, to }
M.EVENT_INIT = "init"
M.EVENT_UNLOCK = "unlock"
M.EVENT_LOGS = "job-log"                  -- { kind? } -- re-publish the last job's log

-- ── the status shape ─────────────────────────────────────────────────────────
-- Written by the service (publish()), read by the panel, the widget and the shortcut tile.
-- Every field must exist here so migrate() keeps it across a schema bump.

function M.emptyStatus()
  return {
    schema = M.SCHEMA,
    updatedAt = 0,
    available = false,        -- restic binary resolved
    version = "",             -- from `restic version`
    repository = "",          -- REDACTED for display (restic.redactRepository)
    repoConfigured = false,   -- repository + password file both set
    mode = "plugin",          -- plugin | observe
    phase = "idle",           -- idle | running | error
    busy = false,             -- a job is in flight
    job = nil,                -- { kind, percent, filesDone, totalFiles, bytesDone, totalBytes }
    jobStartedAt = nil,       -- epoch seconds; the watchdog compares against it
    lastRun = nil,            -- { at, ok, cancelled, files, bytes, added, error }
    lastSuccessAt = nil,      -- epoch seconds of the last successful backup
    nextRun = nil,            -- epoch seconds
    snapshotCount = 0,
    newestSnapshotAt = nil,   -- epoch seconds, straight from `snapshots --json`
    staleness = nil,          -- hours since the newest snapshot; nil until known
    stale = false,            -- staleness passed the configured threshold
    checks = nil,             -- { lastAt, lastOk, numErrors }
    initNeeded = false,       -- repository reachable but not initialised yet
    error = "",               -- last failure message shown in the panel/widget
  }
end

function M.migrate(value)
  if type(value) ~= "table" then
    return M.emptyStatus()
  end
  if value.schema == M.SCHEMA then
    return value
  end
  -- Schema drift. Keep every field the old shape carried -- a plugin update must not blank the
  -- user's UI or drop a useful field -- then fill in whatever the new shape adds and re-stamp.
  local fresh = M.emptyStatus()
  for key, existing in pairs(value) do
    fresh[key] = existing
  end
  fresh.schema = M.SCHEMA
  return fresh
end

return M
