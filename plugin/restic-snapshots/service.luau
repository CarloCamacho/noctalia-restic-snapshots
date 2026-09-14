--!nonstrict
-- Restic Snapshots service.
--
-- Owns the schedule, the single in-flight job, snapshot state, and every restic invocation.
-- Long operations (backup, check, forget, restore, ls, diff) run as detached jobs (see
-- lib/jobs.luau); short read-only ones (snapshots, stats, version) use a bounded runAsync
-- callback.
--
-- [0.2.0] Trust work (contracts 4.6/4.7). Four things the review found this file could not be
-- trusted with, and where they are fixed:
--   * the schedule lived only in memory and re-armed from "now", so a restart or a settings
--     edit could push a backup forward forever -> lib/store.luau, armSchedule(), catch-up;
--   * a hung restic blocked every future run forever -> the watchdog in pollJob();
--   * a failure never reached status.error and a cancel looked exactly like one -> finishJob();
--   * nothing noticed a repository that had quietly stopped being backed up -> the staleness
--     guardian, derived from the repository so it works in observe mode too.

local restic = require("./lib/restic.luau")
local jobs = require("./lib/jobs.luau")
local env = require("./lib/env.luau")
local schedule = require("./lib/schedule.luau")
local state = require("./lib/state.luau")
local store = require("./lib/store.luau")

-- ── constants ────────────────────────────────────────────────────────────────

-- How long SIGTERM gets before the job is killed. Measured on restic 0.19.1: SIGTERM makes it
-- log "signal terminated received, cleaning up" and it can still be alive tens of seconds later
-- while it drains an upload, so waiting for it to obey the first signal is not an option. The
-- window is short on purpose: it exists to let restic drop its repository lock, not to let a
-- stuck upload finish.
local KILL_GRACE_SECONDS = 10

-- Startup catch-up: a stored nextRunAt already in the past means a run was missed, and it is
-- retried within about a minute instead of a whole interval later.
local CATCHUP_DELAY_SECONDS = 30

-- How often update() sweeps finished job files. Sweeping on the lifecycle events alone was not
-- enough: a long-lived shell kept the files of a finished (or crashed) job indefinitely, and a
-- persisted log path could outlive the file it points at. Running jobs are protected by the
-- runner's own pid-liveness check, so an hourly sweep cannot touch a live one.
local SWEEP_INTERVAL_SECONDS = 3600

-- Bounds for the log the panel shows, matching jobs.readLog's own ceiling.
local LOG_TAIL_BYTES = 32768
local LOG_TAIL_LINES = 200

-- Snapshot rows published for the panel (the widget only needs the count).
local SNAPSHOT_ROWS_MAX = 200

-- restic's own way of saying "this repository is there but not initialised yet".
local INIT_ERROR_PATTERNS = { "does not exist", "unable to open config", "is there a repository" }

-- restic's own way of saying "another process holds the lock".
local LOCK_ERROR_PATTERNS = { "already locked", "unable to create lock", "lock file", "is locked" }

-- ── module state ─────────────────────────────────────────────────────────────

local status = state.emptyStatus()
local cfg = nil
local resticPath = nil
local activeJob = nil
local lastRun = nil
local lastSuccessAt = nil
local nextRunAt = nil
local lastCheckAt = nil
local lastCheckOk = nil
local lastCheckErrors = nil
local checkRotationIndex = 0
local lastLogPath = nil
local lastJobMeta = nil
local lastRestoreAt = nil
local staleNotified = false
local hydrated = false
local storedNextRunAt = nil
local armedInterval = nil
local lastSweepAt = nil

local function nowSec()
  return math.floor(noctalia.nowMs() / 1000)
end

local function publish()
  status.schema = state.SCHEMA
  status.updatedAt = nowSec()
  status.busy = activeJob ~= nil
  status.phase = activeJob ~= nil and "running" or (status.error ~= "" and "error" or "idle")
  status.mode = cfg ~= nil and cfg.mode or "plugin"
  -- The repository string can carry credentials; only the redacted form is ever published.
  status.repository = cfg ~= nil and cfg.redactedRepository or ""
  status.repoConfigured = cfg ~= nil and cfg.repository ~= "" and cfg.passwordFile ~= ""
  status.lastRun = lastRun
  status.lastSuccessAt = lastSuccessAt
  status.nextRun = nextRunAt
  noctalia.state.set(state.KEY_STATUS, status)
end

local function setError(message)
  status.error = tostring(message or "")
  noctalia.log("restic: " .. status.error)
  publish()
end

-- Persisted state is written on transitions only -- a job finished, snapshots refreshed, the
-- configuration changed -- never from the update() tick, so state.json is not rewritten every
-- couple of seconds. A failure to persist is worth a log line but must never break a run.
local function persist(patch)
  local ok, err = store.patch(patch)
  if not ok then
    noctalia.log("restic: state not saved: " .. tostring(err))
  end
end

-- ── error classification ─────────────────────────────────────────────────────

local function trim(text)
  -- One value only: `gsub` returns (string, count), and the count leaking into a call argument
  -- (tonumber, table.insert) is a runtime error waiting for the right input.
  local value = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return value
end

local function containsAny(text, patterns)
  local lower = tostring(text or ""):lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function isInitError(text)
  return containsAny(text, INIT_ERROR_PATTERNS)
end

-- A one-line reason for status.error. restic's --json failures arrive as an `exit_error` (or
-- `error`) record with a `message`; a failure outside --json is a raw stderr line. The last such
-- line is the most specific one, so both passes walk the log backwards.
local function failureMessage(text, fallback)
  if type(text) == "string" and text ~= "" then
    local lines = {}
    for line in text:gmatch("[^\n]+") do
      table.insert(lines, trim(line))
    end
    for i = #lines, 1, -1 do
      if lines[i] ~= "" then
        local ok, decoded = pcall(noctalia.json.decode, lines[i])
        if ok and type(decoded) == "table" then
          local message = decoded.message
          if message == nil and type(decoded.error) == "table" then
            message = decoded.error.message
          end
          if type(message) == "string" and trim(message) ~= "" then
            return trim(message)
          end
        end
      end
    end
    for i = #lines, 1, -1 do
      if lines[i] ~= "" and lines[i]:sub(1, 1) ~= "{" then
        return lines[i]
      end
    end
  end
  return tostring(fallback or "the job failed")
end

-- Make sure a lock failure reads as one: the panel offers to clear the lock by looking for the
-- word "locked" in status.error, and restic phrases it several ways ("unable to create lock").
local function describeFailure(message)
  local text = trim(message)
  if containsAny(text, LOCK_ERROR_PATTERNS) and text:lower():find("locked", 1, true) == nil then
    return "repository locked: " .. text
  end
  return text
end

-- ── staleness guardian ───────────────────────────────────────────────────────

-- Recomputed from the newest snapshot in the repository, never from our own last run: in observe
-- mode another tool keeps it fresh, and if that tool stops, this still notices. Called from the
-- snapshot refresh and from every tick (the arithmetic is free, the notification is not: it
-- fires once on the transition into stale and once on recovery, never per tick).
local function applyStaleness(announce)
  if cfg == nil then
    return
  end
  local newest = tonumber(status.newestSnapshotAt)
  if newest == nil then
    -- Unknown: an empty repository, or times restic did not give us. Drop the "already warned"
    -- flag with the state it describes, so a later transition into stale is still announced
    -- rather than being suppressed by a warning about a different repository state.
    status.staleness = nil
    status.stale = false
    staleNotified = false
    return
  end
  local now = nowSec()
  local age = math.max(0, now - newest)
  status.staleness = age / 3600
  local stale = schedule.isStale(now, newest, schedule.staleThresholdHours(cfg))
  status.stale = stale
  if not announce then
    return
  end
  if stale and not staleNotified then
    staleNotified = true
    noctalia.notifyError("Restic backup is overdue", string.format(
      "the newest snapshot is %s old", restic.ageLabel(age)))
  elseif not stale and staleNotified then
    staleNotified = false
    noctalia.notify("Restic backups are current again", string.format(
      "the newest snapshot is %s old", restic.ageLabel(age)))
  end
end

-- ── job logs ─────────────────────────────────────────────────────────────────

-- The tail of a job log as the panel's viewer wants it: a list of lines, bounded to 200 lines
-- and 32 KiB. jobs.readLog does the bounding; the file size is compared against what came back
-- so `truncated` is honest rather than assumed.
local function collectLogLines(path)
  if type(path) ~= "string" or path == "" then
    return {}, false
  end
  local text = jobs.readLog(path, LOG_TAIL_BYTES, LOG_TAIL_LINES)
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  local truncated = #lines >= LOG_TAIL_LINES
  if not truncated then
    local info = noctalia.fileInfo(path)
    local size = info ~= nil and tonumber(info.size) or nil
    if size ~= nil and size > #text then
      truncated = true
    end
  end
  return lines, truncated
end

local function publishJobLog(meta, path)
  local lines, truncated = collectLogLines(path)
  noctalia.state.set(state.KEY_JOBLOG, {
    kind = meta ~= nil and meta.kind or nil,
    at = meta ~= nil and meta.at or nil,
    ok = meta ~= nil and meta.ok or false,
    cancelled = meta ~= nil and meta.cancelled == true,
    exitCode = meta ~= nil and meta.exitCode or nil,
    lines = lines,
    truncated = truncated or (meta ~= nil and meta.truncated == true) or false,
  })
end

-- Re-publish the last job's log from the persisted path, so the viewer still works after a
-- restart (the job files themselves are swept after a day).
local function republishJobLog()
  if type(lastLogPath) ~= "string" or lastLogPath == "" then
    return false, "no job log yet"
  end
  publishJobLog(lastJobMeta, lastLogPath)
  return true, nil
end

-- ── signalling: TERM, then KILL ──────────────────────────────────────────────

-- restic's own pid, as recorded by the job runner. Read from the pid file, never guessed, and
-- never a pid at or below 1: killing init or the whole process group is not recoverable.
local function readPid(paths)
  if type(paths) ~= "table" or type(paths.pid) ~= "string" then
    return nil
  end
  local text = noctalia.readFile(paths.pid)
  -- Parenthesised: gsub returns two values and tonumber would take the second as a base.
  local pid = tonumber((trim(text)))
  if pid == nil or pid <= 1 then
    return nil
  end
  return pid
end

local function signalKill(paths)
  local pid = readPid(paths)
  if pid == nil then
    noctalia.log("restic: no restic pid recorded; nothing to kill")
    return false
  end
  return noctalia.runAsync({ "kill", "-KILL", tostring(pid) }) == true
end

-- One escalation step per call: SIGTERM first, SIGKILL once the grace window has passed. Returns
-- true when the guard may be released even though the runner never wrote an exit file -- SIGKILL
-- cannot be ignored, so after a second grace window the process is gone and waiting longer would
-- only strand the single-flight guard.
local function escalate(job, now)
  if job.termAt == nil then
    job.termAt = now
    jobs.cancel(job.paths)
    return false
  end
  if now - job.termAt < KILL_GRACE_SECONDS then
    return false
  end
  if job.killAt == nil then
    signalKill(job.paths)
    job.killAt = now
    return false
  end
  return now - job.killAt >= KILL_GRACE_SECONDS
end

-- ── forward declarations ─────────────────────────────────────────────────────

local refreshSnapshots, refreshStats, startJob, finishJob, triggerBackup

-- ── snapshots ────────────────────────────────────────────────────────────────

-- A filter, if a caller asked for one: the panel filters client-side (contract 4.8), so this is
-- only used when an IPC refresh carries one. Unknown keys and non-strings are dropped rather
-- than trusted.
local function sanitiseFilter(value)
  if type(value) ~= "table" then
    return nil
  end
  local filter = {}
  local any = false
  for _, key in ipairs({ "host", "tag", "text" }) do
    if type(value[key]) == "string" and value[key] ~= "" then
      filter[key] = value[key]
      any = true
    end
  end
  if not any then
    return nil
  end
  return filter
end

-- The repository is not initialised. That is a state the user can fix from the panel, so it is
-- recorded as such instead of as an error they cannot act on, and announced once.
local function markInitNeeded(detail)
  if not status.initNeeded then
    status.initNeeded = true
    noctalia.notify("Restic repository is not initialised yet", trim(detail))
  end
  status.error = ""
  publish()
end

refreshSnapshots = function(filter)
  if resticPath == nil or cfg.repository == "" then
    return false, "restic is not available"
  end
  if activeJob ~= nil then
    -- Read-only commands carry --no-lock, but a refresh racing our own backup can still read a
    -- half-written index, and the panel only ever shows a slightly older list.
    return false, "a job is already running"
  end
  noctalia.runAsync(restic.snapshotsArgs(cfg, resticPath), function(result)
    if result == nil then
      setError("snapshots: no result")
      return
    end
    if result.exitCode ~= 0 then
      local detail = trim(result.stderr)
      if detail == "" then
        detail = trim(result.stdout)
      end
      if isInitError(detail) then
        markInitNeeded(detail)
      else
        setError(describeFailure(failureMessage(detail, "snapshots failed")))
      end
      return
    end
    local list = restic.parseSnapshots(result.stdout)
    local rows = {}
    for _, snapshot in ipairs(list) do
      table.insert(rows, restic.snapshotRow(snapshot))
    end
    table.sort(rows, function(a, b)
      return tostring(a.time) > tostring(b.time)
    end)
    while #rows > SNAPSHOT_ROWS_MAX do
      table.remove(rows)
    end
    -- Counts and staleness describe the whole repository, so they are computed before any
    -- display filter is applied.
    local summary = restic.snapshotSummary(rows)
    status.snapshotCount = summary.count
    status.newestSnapshotAt = summary.newestAt
    status.initNeeded = false
    status.error = ""
    applyStaleness(true)
    local published = filter ~= nil and restic.filterSnapshots(rows, filter) or rows
    noctalia.state.set(state.KEY_SNAPSHOTS, {
      schema = state.SCHEMA,
      updatedAt = nowSec(),
      snapshots = published,
      filter = filter,
    })
    persist({
      snapshotCount = summary.count,
      newestSnapshotAt = summary.newestAt,
      stale = status.stale,
      lastRefreshAt = nowSec(),
    })
    publish()
  end, 30000)
  return true, nil
end

-- ── stats ────────────────────────────────────────────────────────────────────

-- The repository card in the panel. On failure the previously published numbers are kept and
-- only `ok` flips, so a transient error does not blank a card the user was reading.
refreshStats = function()
  if resticPath == nil or cfg.repository == "" then
    return false, "restic is not available"
  end
  if activeJob ~= nil then
    return false, "a job is already running"
  end
  noctalia.runAsync(restic.statsArgs(cfg, resticPath), function(result)
    local previous = noctalia.state.get(state.KEY_STATS)
    local payload = {
      totalBytes = 0,
      totalFileCount = 0,
      snapshotsCount = 0,
      updatedAt = nowSec(),
      ok = false,
    }
    if type(previous) == "table" then
      payload.totalBytes = tonumber(previous.totalBytes) or 0
      payload.totalFileCount = tonumber(previous.totalFileCount) or 0
      payload.snapshotsCount = tonumber(previous.snapshotsCount) or 0
    end
    local parsed = nil
    if result ~= nil and result.exitCode == 0 then
      parsed = restic.parseStats(result.stdout)
    end
    if parsed ~= nil then
      payload.totalBytes = parsed.totalBytes
      payload.totalFileCount = parsed.totalFileCount
      payload.snapshotsCount = parsed.snapshotsCount
      payload.ok = true
    end
    noctalia.state.set(state.KEY_STATS, payload)
    if not payload.ok then
      noctalia.log("restic: stats refresh failed")
    end
  end, 30000)
  return true, nil
end

-- ── jobs ─────────────────────────────────────────────────────────────────────

-- Every restic invocation that can take longer than a tick goes through here: one job at a
-- time, detached, polled from update(). `request` is the untrusted-derived context the panel
-- summary needs later (snapshot id, target, diff pair); `buildErr` is the builder's reason when
-- it refused to produce an argv vector.
startJob = function(kind, argv, request, buildErr)
  if argv == nil then
    return false, buildErr or "invalid request"
  end
  if activeJob ~= nil then
    return false, "a job is already running"
  end
  if resticPath == nil then
    return false, "restic is not installed"
  end
  if cfg.repository == "" then
    return false, "no repository configured"
  end
  -- envFile is the user's credentials file for cloud/remote backends; the runner sources it
  -- (single-quoted) before restic starts and never writes a secret into the generated script.
  local token, err, paths = jobs.start(argv, {
    pathPrefix = env.binDir(resticPath),
    envFile = cfg.envFile,
  })
  if token == nil then
    return false, err
  end
  local startedAt = nowSec()
  activeJob = {
    token = token,
    paths = paths,
    kind = kind,
    request = request,
    lastSize = nil,
    startedAt = startedAt,
    cancelRequested = false,
    timedOut = false,
    termAt = nil,
    killAt = nil,
    logPath = type(paths) == "table" and paths.log or nil,
  }
  status.jobStartedAt = startedAt
  status.job = { kind = kind, percent = 0 }
  status.error = ""
  publish()
  return true, nil
end

triggerBackup = function()
  if cfg.mode ~= "plugin" then
    noctalia.log("restic: refusing backup - plugin is in observe mode")
    return false, "the plugin is in observe mode"
  end
  if #cfg.paths == 0 then
    noctalia.log("restic: refusing backup - no backup paths configured")
    return false, "no backup paths configured"
  end
  return startJob("backup", restic.backupArgs(cfg, resticPath))
end

-- What happens when a job stops, whatever stopped it: the outcome record, the per-kind payload,
-- the re-armed schedule, the persisted state and the log the panel can show.
finishJob = function(job, exitCode, text)
  local at = nowSec()
  local kind = job.kind
  local cancelled = job.cancelRequested == true
  local timedOut = job.timedOut == true and not cancelled
  local code = tonumber(exitCode) or 0
  if timedOut then
    -- 124 whatever the process eventually exited with: the runner's exit code describes our
    -- kill, and a job that overran the ceiling the user configured is not a success.
    code = 124
  end
  local ok = code == 0 and not cancelled and not timedOut

  local logText = jobs.readLog(job.logPath)
  local raw = type(text) == "string" and text ~= "" and text or logText
  local objects = restic.parseJsonLines(raw)
  local summary = restic.lastSummary(objects)
  local request = type(job.request) == "table" and job.request or {}

  local errorMessage = ""
  if timedOut then
    errorMessage = "timed out"
  elseif not ok and not cancelled then
    errorMessage = describeFailure(failureMessage(
      logText ~= "" and logText or raw, kind .. " failed"))
  end

  lastRun = {
    kind = kind,
    at = at,
    ok = ok,
    cancelled = cancelled,
    exitCode = code,
    files = summary ~= nil and summary.total_files_processed or nil,
    bytes = summary ~= nil and summary.total_bytes_processed or nil,
    added = summary ~= nil and summary.data_added or nil,
    error = errorMessage ~= "" and errorMessage or nil,
  }

  -- A cancel is a user action, not a failure: it notifies once, as information, and leaves both
  -- status.error and lastSuccessAt alone so the widget does not go red and the last good backup
  -- is still the one that counts.
  if cancelled then
    noctalia.notify("Restic " .. kind .. " cancelled", "the run was stopped from the panel")
  elseif errorMessage ~= "" then
    if isInitError(errorMessage) then
      status.initNeeded = true
    end
    if timedOut then
      noctalia.notifyError("Restic " .. kind .. " timed out", errorMessage)
    else
      noctalia.notifyError("Restic " .. kind .. " failed", errorMessage)
    end
  end
  status.error = cancelled and status.error or errorMessage

  -- ── per-kind outcome ──
  if kind == "backup" then
    if ok then
      lastSuccessAt = at
      noctalia.notify("Restic backup complete", string.format(
        "%s files, %s processed", tostring(lastRun.files or "?"), restic.humanBytes(lastRun.bytes)))
    end
  elseif kind == "check" then
    lastCheckAt = at
    lastCheckOk = ok
    lastCheckErrors = summary ~= nil and tonumber(summary.num_errors) or nil
    status.checks = { lastAt = lastCheckAt, lastOk = lastCheckOk, numErrors = lastCheckErrors }
    if ok then
      noctalia.notify("Restic check complete", "no errors found")
    end
  elseif kind == "forget-dry" then
    local preview = restic.summariseForgetDry(objects, 50)
    noctalia.state.set(state.KEY_JOB, {
      kind = "forget-dry",
      at = at,
      ok = ok,
      keepCount = preview ~= nil and preview.keepCount or 0,
      removeCount = preview ~= nil and preview.removeCount or 0,
      remove = preview ~= nil and preview.remove or {},
      truncated = preview ~= nil and preview.truncated or false,
    })
  elseif kind == "forget" or kind == "forget-one" then
    if ok then
      noctalia.notify("Retention applied", "pruned per policy")
    end
  elseif kind == "restore-dry" then
    noctalia.state.set(state.KEY_JOB, {
      kind = "restore-dry",
      at = at,
      ok = ok,
      snapshot = request.snapshot,
      target = request.target,
      files = summary ~= nil and (tonumber(summary.files_restored) or tonumber(summary.total_files)) or nil,
    })
  elseif kind == "restore" then
    if ok then
      lastRestoreAt = at
      noctalia.notify("Restore complete", "restored into " .. tostring(request.target or cfg.restoreTarget))
    end
  elseif kind == "ls" then
    local parsed = restic.parseLs(raw, 200)
    noctalia.state.set(state.KEY_FILES, {
      snapshot = request.snapshot,
      entries = parsed.entries,
      truncated = parsed.truncated,
      at = at,
      ok = ok,
    })
  elseif kind == "diff" then
    local parsed = restic.parseDiff(raw, 200)
    noctalia.state.set(state.KEY_DIFF, {
      from = request.from,
      to = request.to,
      added = parsed ~= nil and parsed.added or 0,
      removed = parsed ~= nil and parsed.removed or 0,
      changed = parsed ~= nil and parsed.changed or 0,
      truncated = parsed ~= nil and parsed.truncated or false,
      at = at,
      ok = ok,
    })
  elseif kind == "init" then
    if ok then
      status.initNeeded = false
      noctalia.notify("Restic repository initialised", cfg.redactedRepository)
    end
  elseif kind == "unlock" then
    if ok and status.error:lower():find("locked", 1, true) ~= nil then
      status.error = ""
    end
  end

  -- The next run comes from the last success, never from "now", so a reload or a redraw cannot
  -- postpone it -- except after a cancel, which re-arms from now so the user's cancel is not
  -- immediately undone by a catch-up.
  if cfg ~= nil then
    local base = cancelled and at or (lastSuccessAt or at)
    nextRunAt = schedule.nextRun(nowSec(), cfg.intervalMinutes, base)
  end

  activeJob = nil
  status.job = nil
  status.jobStartedAt = nil

  local meta = {
    kind = kind,
    at = at,
    ok = ok,
    cancelled = cancelled,
    exitCode = code,
    truncated = false,
  }
  local lines, truncated = collectLogLines(job.logPath)
  meta.truncated = truncated
  noctalia.state.set(state.KEY_JOBLOG, {
    kind = kind,
    at = at,
    ok = ok,
    cancelled = cancelled,
    exitCode = code,
    lines = lines,
    truncated = truncated,
  })
  lastJobMeta = meta
  if type(job.logPath) == "string" and job.logPath ~= "" then
    lastLogPath = job.logPath
  end

  persist({
    lastRun = lastRun,
    lastSuccessAt = lastSuccessAt,
    nextRunAt = nextRunAt,
    lastLog = lastLogPath,
    lastJob = lastJobMeta,
    lastCheckAt = lastCheckAt,
    lastCheckOk = lastCheckOk,
    lastCheckErrors = lastCheckErrors,
    checkRotationIndex = checkRotationIndex,
    lastRestoreAt = lastRestoreAt,
  })

  publish()

  -- Anything that changes what is in the repository refreshes the snapshot list, so the count,
  -- the newest snapshot and therefore the staleness line follow the run that caused it.
  if ok and (kind == "backup" or kind == "forget" or kind == "forget-one"
      or kind == "init" or kind == "unlock") then
    refreshSnapshots()
  end
end

local function pollJob()
  local job = activeJob
  if job == nil then
    return
  end
  local polled = jobs.poll(job.token, job.paths, job.lastSize)
  if polled.changed and polled.text ~= "" then
    job.lastSize = polled.size
  end
  -- Progress comes from the runner's status file (0.2.0): the runner splits restic's output so
  -- status lines never reach the job log, and the old "re-parse the log for a status line" path
  -- saw nothing at all.
  local progress = polled.statusLine
  if type(progress) == "table" and (polled.changed or status.job == nil) then
    status.job = {
      kind = job.kind,
      percent = progress.percent_done,
      filesDone = progress.files_done,
      totalFiles = progress.total_files,
      bytesDone = progress.bytes_done,
      totalBytes = progress.total_bytes,
      currentFiles = progress.current_files,
    }
    publish()
  end

  if polled.done then
    finishJob(job, polled.exitCode, polled.text)
    return
  end

  -- Watchdog. Without it one hung restic blocked every future run forever (review finding #4).
  local now = nowSec()
  local ceiling = (tonumber(cfg.jobTimeoutMinutes) or 180) * 60
  local overrun = now - (tonumber(job.startedAt) or now) > ceiling
  if job.cancelRequested or overrun then
    if overrun and not job.cancelRequested and not job.timedOut then
      job.timedOut = true
      noctalia.log(string.format(
        "restic: %s job exceeded its %d minute ceiling; cancelling it",
        tostring(job.kind), tonumber(cfg.jobTimeoutMinutes) or 180))
    end
    if escalate(job, now) then
      -- SIGKILL could not be ignored and the runner never reported the exit: the process is
      -- gone, so the guard has to be released or no future run would ever fire.
      finishJob(job, nil, "")
    end
  end
end

-- ── scheduled checks ─────────────────────────────────────────────────────────

-- The denominator of check_subset ("1/100" -> 100): the rotation has to walk the same space the
-- user configured. A percentage subset ("5%") has no slots, so it is passed through unchanged
-- and the rotation index is left alone.
local function scheduledCheckSubset()
  local subset = tostring(cfg.checkSubset or "")
  local total = tonumber(subset:match("^%s*%d+%s*/%s*(%d+)%s*$"))
  if total == nil or total < 2 then
    return subset, false
  end
  return schedule.subsetForIndex(checkRotationIndex, total), true
end

local function startScheduledCheck()
  local subset, rotating = scheduledCheckSubset()
  local started, err = startJob("check", restic.checkArgs(cfg, resticPath, subset))
  if started then
    if rotating then
      -- Advance the series so consecutive checks read different parts of the repository; it is
      -- persisted with the result, so a restart resumes where the series stopped.
      checkRotationIndex = checkRotationIndex + 1
      persist({ checkRotationIndex = checkRotationIndex })
    end
    return true, nil
  end
  noctalia.log("restic: scheduled check did not start: " .. tostring(err))
  -- Re-arm rather than retry every tick: whatever stopped it needs the user.
  lastCheckAt = nowSec()
  persist({ lastCheckAt = lastCheckAt })
  return false, err
end

-- ── configuration ────────────────────────────────────────────────────────────

local function loadConfig()
  local function get(key)
    return noctalia.getConfig(key)
  end
  cfg = restic.config({
    restic_bin = get("restic_bin"),
    repository = get("repository"),
    password_file = get("password_file"),
    backup_paths = get("backup_paths"),
    backup_tags = get("backup_tags"),
    exclude_file = get("exclude_file"),
    env_file = get("env_file"),
    mode = get("mode"),
    interval_minutes = get("interval_minutes"),
    job_timeout_minutes = get("job_timeout_minutes"),
    check_interval_hours = get("check_interval_hours"),
    stale_after_hours = get("stale_after_hours"),
    keep_last = get("keep_last"),
    keep_daily = get("keep_daily"),
    keep_weekly = get("keep_weekly"),
    keep_monthly = get("keep_monthly"),
    restore_target = get("restore_target"),
    restore_allow_roots = get("restore_allow_roots"),
    check_subset = get("check_subset"),
  })
end

local function resolveRestic()
  resticPath = env.resolveBinary(cfg.bin)
  status.available = resticPath ~= nil
  if resticPath == nil then
    status.version = ""
    return
  end
  noctalia.runAsync({ resticPath, "version" }, function(result)
    if result ~= nil and result.exitCode == 0 then
      status.version = (result.stdout or ""):match("restic%s+([%w%.%-]+)") or ""
      publish()
    end
  end, 10000)
end

-- ── persistence ──────────────────────────────────────────────────────────────

-- Load the persisted record once per service instance. Everything in it is a *hint* from a
-- previous incarnation, so each field is type-checked before it is believed.
local function hydrate()
  if hydrated then
    return
  end
  hydrated = true
  local record = store.load()
  if type(record) ~= "table" then
    record = {}
  end
  if type(record.lastRun) == "table" then
    lastRun = record.lastRun
  end
  lastSuccessAt = tonumber(record.lastSuccessAt)
  lastCheckAt = tonumber(record.lastCheckAt)
  lastCheckOk = type(record.lastCheckOk) == "boolean" and record.lastCheckOk or nil
  lastCheckErrors = tonumber(record.lastCheckErrors)
  checkRotationIndex = math.max(0, math.floor(tonumber(record.checkRotationIndex) or 0))
  lastRestoreAt = tonumber(record.lastRestoreAt)
  if type(record.lastLog) == "string" and record.lastLog ~= "" then
    lastLogPath = record.lastLog
  end
  if type(record.lastJob) == "table" then
    lastJobMeta = record.lastJob
  end
  storedNextRunAt = tonumber(record.nextRunAt)
  status.snapshotCount = math.max(0, math.floor(tonumber(record.snapshotCount) or 0))
  status.newestSnapshotAt = tonumber(record.newestSnapshotAt)
  status.stale = record.stale == true
  -- A repository already known to be stale must not be announced twice: the user was told in the
  -- previous incarnation, and only a recovery (or a fresh stale transition) is news.
  staleNotified = record.stale == true
  if lastCheckAt ~= nil then
    status.checks = { lastAt = lastCheckAt, lastOk = lastCheckOk, numErrors = lastCheckErrors }
  end
end

-- Arm the schedule from what is on disk. A stored nextRunAt already in the past means the run
-- was missed while the shell was off: catch up within about a minute instead of adding a whole
-- interval, which is what used to push a backup forward forever after every restart.
local function armSchedule()
  local now = nowSec()
  local candidate = nil
  if storedNextRunAt ~= nil then
    candidate = storedNextRunAt
    storedNextRunAt = nil
    if candidate <= now then
      candidate = now + CATCHUP_DELAY_SECONDS
    end
  else
    local intervalChanged = armedInterval ~= nil and armedInterval ~= cfg.intervalMinutes
    if not intervalChanged and nextRunAt ~= nil then
      -- Nothing to re-derive: keep the pending run across an unrelated settings edit.
      candidate = nextRunAt
    else
      -- Derive it from the last success, never from "now", so a settings edit or the first run
      -- after an upgrade cannot postpone an overdue backup either.
      candidate = schedule.nextRun(now, cfg.intervalMinutes, lastSuccessAt or now)
    end
  end
  local changed = candidate ~= nextRunAt
  nextRunAt = candidate
  status.nextRun = nextRunAt
  armedInterval = cfg.intervalMinutes
  if changed then
    persist({ nextRunAt = nextRunAt })
  end
end

-- ── IPC ──────────────────────────────────────────────────────────────────────

local function decodePayload(payload)
  if type(payload) == "table" then
    return payload
  end
  if type(payload) == "string" then
    local ok, decoded = pcall(noctalia.json.decode, payload)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return nil
end

-- The payload for an event that names one snapshot: either a table or a bare snapshot id.
local function snapshotRequest(payload)
  local request = decodePayload(payload)
  if type(request) == "table" then
    return request
  end
  if type(payload) == "string" and restic.validSnapshotId(payload) then
    return { snapshot = payload }
  end
  return nil
end

local function reject(reason)
  -- Logged as well as notified: the notification carries the reason in its body, which the log
  -- does not keep, and a rejected IPC request is exactly what a bug report needs to show.
  noctalia.log("restic: rejected " .. tostring(reason))
  noctalia.notifyError("Restic", tostring(reason))
  return false, reason
end

-- The one place a restore destination is accepted from IPC. `restic.validRestoreTarget` owns the
-- allow-list (restore target, allow-listed roots, never /, never $HOME, never a backup source,
-- never over a file), and it is applied to the dry run as well: a preview that promises a
-- restore the real run would then refuse is worse than no preview.
local function restoreTargetFor(request)
  local requested = cfg.restoreTarget
  if request ~= nil and type(request.target) == "string" and trim(request.target) ~= "" then
    requested = request.target
  end
  local ok, err = restic.validRestoreTarget(cfg, requested)
  if not ok then
    return nil, err
  end
  return requested, nil
end

local function handleForgetOne(payload)
  local request = snapshotRequest(payload)
  if request == nil or not restic.validSnapshotId(request.snapshot) then
    return reject("forget-one needs a snapshot id")
  end
  local argv, err = restic.forgetOneArgs(cfg, resticPath, request.snapshot)
  return startJob("forget-one", argv, { snapshot = request.snapshot }, err)
end

local function handleRestore(payload, dryRun)
  local request = snapshotRequest(payload)
  if request == nil or not restic.validSnapshotId(request.snapshot) then
    return reject(dryRun and "restore preview needs a snapshot id" or "restore needs a snapshot id")
  end
  local target, terr = restoreTargetFor(request)
  if target == nil then
    return reject(terr)
  end
  local argv, err = restic.restoreArgs(cfg, resticPath, request.snapshot, target, request.include,
    { dryRun = dryRun })
  return startJob(dryRun and "restore-dry" or "restore", argv,
    { snapshot = request.snapshot, target = target }, err)
end

local function handleLs(payload)
  local request = snapshotRequest(payload)
  if request == nil or not restic.validSnapshotId(request.snapshot) then
    return reject("a file listing needs a snapshot id")
  end
  local argv, err = restic.lsArgs(cfg, resticPath, request.snapshot)
  return startJob("ls", argv, { snapshot = request.snapshot }, err)
end

local function handleDiff(payload)
  local request = decodePayload(payload)
  if type(request) ~= "table" then
    return reject("diff needs two snapshot ids")
  end
  if not restic.validSnapshotId(request.from) or not restic.validSnapshotId(request.to) then
    return reject("diff needs two valid snapshot ids")
  end
  local argv, err = restic.diffArgs(cfg, resticPath, request.from, request.to)
  return startJob("diff", argv, { from = request.from, to = request.to }, err)
end

function onIpc(event, payload)
  local ok, err = pcall(function()
    if event == state.EVENT_REFRESH then
      local request = decodePayload(payload)
      local filter = type(request) == "table" and sanitiseFilter(request.filter) or nil
      local started, serr = refreshSnapshots(filter)
      if not started then
        reject(serr)
      end
    elseif event == state.EVENT_BACKUP then
      local started, serr = triggerBackup()
      if not started then
        reject(serr)
      end
    elseif event == state.EVENT_CHECK then
      -- The manual check uses the configured subset (settings.check_subset, "1/100" or "5%"):
      -- the rotation belongs to the scheduled series, so a manual check does not consume a slot.
      local started, serr = startJob("check", restic.checkArgs(cfg, resticPath))
      if not started then
        reject(serr)
      end
    elseif event == state.EVENT_FORGET_DRY then
      if not restic.hasPolicy(cfg) then
        reject("set at least one keep-* rule first")
      else
        local started, serr = startJob("forget-dry", restic.forgetArgs(cfg, resticPath, true))
        if not started then
          reject(serr)
        end
      end
    elseif event == state.EVENT_FORGET then
      if not restic.hasPolicy(cfg) then
        reject("set at least one keep-* rule first")
      else
        local started, serr = startJob("forget", restic.forgetArgs(cfg, resticPath, false))
        if not started then
          reject(serr)
        end
      end
    elseif event == state.EVENT_FORGET_ONE then
      handleForgetOne(payload)
    elseif event == state.EVENT_RESTORE_DRY then
      handleRestore(payload, true)
    elseif event == state.EVENT_RESTORE then
      handleRestore(payload, false)
    elseif event == state.EVENT_CANCEL then
      if activeJob == nil then
        noctalia.log("restic: cancel requested with no job running")
      else
        -- The flag goes up *before* the signal: whatever ends the process, the completion path
        -- has to know this was the user and not a failure.
        activeJob.cancelRequested = true
        escalate(activeJob, nowSec())
        publish()
      end
    elseif event == state.EVENT_STATS then
      local started, serr = refreshStats()
      if not started then
        reject(serr)
      end
    elseif event == state.EVENT_LS then
      handleLs(payload)
    elseif event == state.EVENT_DIFF then
      handleDiff(payload)
    elseif event == state.EVENT_INIT then
      local started, serr = startJob("init", restic.initArgs(cfg, resticPath))
      if not started then
        reject(serr)
      end
    elseif event == state.EVENT_UNLOCK then
      local started, serr = startJob("unlock", restic.unlockArgs(cfg, resticPath))
      if not started then
        reject(serr)
      end
    elseif event == state.EVENT_LOGS then
      local republished, lerr = republishJobLog()
      if not republished then
        noctalia.log("restic: " .. tostring(lerr))
        noctalia.notify("Restic", tostring(lerr))
      end
    else
      noctalia.log("restic: ignoring unknown event " .. tostring(event))
    end
  end)
  if not ok then
    noctalia.log("restic ipc error: " .. tostring(err))
    noctalia.notifyError("Restic", tostring(err))
  end
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

local function probeLoginPath()
  noctalia.runAsync({ "sh", "-lc", 'printf %s "$PATH"' }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    local value = (result.stdout or ""):gsub("%s+$", "")
    if value == "" then
      return
    end
    env.setSearchPath(value)
    resolveRestic()
    publish()
    refreshSnapshots()
  end, 10000)
end

local function initialise()
  loadConfig()
  hydrate()
  resolveRestic()
  armSchedule()
  publish()
  if resticPath ~= nil and cfg.repository ~= "" then
    -- Also re-publishes the persisted job log, so the Log tab is not empty after a restart.
    republishJobLog()
    refreshSnapshots()
  end
end

function update()
  pollJob()
  -- Hourly sweep on top of the enable/exit sweep: finished jobs age out on their own, and a
  -- job whose script died before writing its exit file stops leaking its files forever.
  local now = nowSec()
  if lastSweepAt == nil or now - lastSweepAt >= SWEEP_INTERVAL_SECONDS then
    lastSweepAt = now
    jobs.sweep()
  end
  -- Free: keeps the staleness line honest between refreshes (a shell that slept through the
  -- threshold notices as soon as it wakes, not at the next backup).
  applyStaleness(true)
  if cfg == nil then
    return
  end

  if cfg.mode == "plugin" and activeJob == nil and resticPath ~= nil
      and cfg.repository ~= "" and #cfg.paths > 0
      and schedule.due(nowSec(), nextRunAt) then
    local started, serr = triggerBackup()
    if not started then
      -- Re-arm so a misconfiguration does not retry every tick.
      noctalia.log("restic: scheduled backup did not start: " .. tostring(serr))
      nextRunAt = schedule.nextRun(nowSec(), cfg.intervalMinutes, nowSec())
      persist({ nextRunAt = nextRunAt })
      publish()
    end
  end

  if activeJob == nil and resticPath ~= nil and cfg.repository ~= ""
      and schedule.checkDue(nowSec(), lastCheckAt, cfg.checkIntervalHours) then
    startScheduledCheck()
  end
end

function onEnable()
  initialise()
  probeLoginPath()
  jobs.sweep()
end

function onConfigChanged()
  initialise()
end

function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    if activeJob ~= nil then
      jobs.cancel(activeJob.paths)
      activeJob = nil
    end
    jobs.sweep()
  end
end

initialise()
probeLoginPath()
noctalia.setUpdateInterval(2000)
