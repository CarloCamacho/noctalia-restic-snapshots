--!nonstrict
-- Restic Snapshots service.
--
-- Owns the schedule, the single in-flight job, snapshot state, and every restic invocation.
-- Long operations (backup, check, forget, restore) run as detached jobs (see lib/jobs.luau);
-- short read-only ones (snapshots, version) use a bounded runAsync callback.

local restic = require("./lib/restic.luau")
local jobs = require("./lib/jobs.luau")
local env = require("./lib/env.luau")
local schedule = require("./lib/schedule.luau")
local state = require("./lib/state.luau")

local status = state.emptyStatus()
local cfg = nil
local resticPath = nil
local activeJob = nil
local lastRun = nil
local nextRunAt = nil

local function nowSec()
  return math.floor(noctalia.nowMs() / 1000)
end

local function publish()
  status.schema = state.SCHEMA
  status.updatedAt = nowSec()
  status.busy = activeJob ~= nil
  status.phase = activeJob ~= nil and "running" or (status.error ~= "" and "error" or "idle")
  status.mode = cfg ~= nil and cfg.mode or "plugin"
  status.repository = cfg ~= nil and cfg.repository or ""
  status.repoConfigured = cfg ~= nil and cfg.repository ~= "" and cfg.passwordFile ~= ""
  status.lastRun = lastRun
  status.nextRun = nextRunAt
  noctalia.state.set(state.KEY_STATUS, status)
end

local function setError(message)
  status.error = tostring(message or "")
  noctalia.log("restic: " .. status.error)
  publish()
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
    mode = get("mode"),
    interval_minutes = get("interval_minutes"),
    keep_last = get("keep_last"),
    keep_daily = get("keep_daily"),
    keep_weekly = get("keep_weekly"),
    keep_monthly = get("keep_monthly"),
    restore_target = get("restore_target"),
    check_subset = get("check_subset"),
  })
  cfg.restoreTarget = env.expandPath(cfg.restoreTarget)
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

-- ── snapshots ────────────────────────────────────────────────────────────────

local function refreshSnapshots()
  if resticPath == nil or cfg.repository == "" then
    return
  end
  noctalia.runAsync(restic.snapshotsArgs(cfg, resticPath), function(result)
    if result == nil then
      setError("snapshots: no result")
      return
    end
    if result.exitCode ~= 0 then
      setError("snapshots failed: " .. tostring(result.stderr or ""))
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
    while #rows > 200 do
      table.remove(rows)
    end
    status.snapshotCount = #rows
    status.error = ""
    noctalia.state.set(state.KEY_SNAPSHOTS, {
      schema = state.SCHEMA,
      updatedAt = nowSec(),
      snapshots = rows,
    })
    publish()
  end, 30000)
end

-- ── jobs ─────────────────────────────────────────────────────────────────────

local function finishJob(kind, exitCode, text)
  local objects = restic.parseJsonLines(text)
  local summary = restic.lastSummary(objects)
  local ok = exitCode == 0

  if kind == "backup" then
    lastRun = {
      at = nowSec(),
      ok = ok,
      files = summary ~= nil and summary.total_files_processed or nil,
      bytes = summary ~= nil and summary.total_bytes_processed or nil,
      added = summary ~= nil and summary.data_added or nil,
    }
    nextRunAt = schedule.nextRun(nowSec(), cfg.intervalMinutes, lastRun.at)
    if ok then
      noctalia.notify("Restic backup complete", string.format(
        "%s files, %s processed",
        tostring(lastRun.files or "?"), restic.humanBytes(lastRun.bytes)
      ))
      refreshSnapshots()
    else
      noctalia.notifyError("Restic backup failed", "see the job log in the panel")
    end
  elseif kind == "check" then
    if ok then
      noctalia.notify("Restic check", string.format("no errors (%s packs checked)", tostring(summary and summary.num_errors or 0)))
    else
      noctalia.notifyError("Restic check failed", "see the job log in the panel")
    end
  elseif kind == "forget-dry" then
    noctalia.state.set(state.KEY_JOB, {
      kind = "forget-dry",
      at = nowSec(),
      ok = ok,
      groups = restic.parseObject(text),
    })
  elseif kind == "forget" then
    if ok then
      noctalia.notify("Retention applied", "pruned per policy")
      refreshSnapshots()
    else
      noctalia.notifyError("Retention failed", "see the job log in the panel")
    end
  elseif kind == "restore" then
    if ok then
      noctalia.notify("Restore complete", "restored into " .. cfg.restoreTarget)
    else
      noctalia.notifyError("Restore failed", "see the job log in the panel")
    end
  end

  activeJob = nil
  publish()
end

local function pollJob()
  if activeJob == nil then
    return
  end
  local polled = jobs.poll(activeJob.token, activeJob.paths, activeJob.lastSize)
  if polled.changed and polled.text ~= "" then
    activeJob.lastSize = polled.size
    local objects = restic.parseJsonLines(polled.text)
    local progress = restic.lastStatus(objects)
    if progress ~= nil then
      status.job = {
        kind = activeJob.kind,
        percent = progress.percent_done,
        filesDone = progress.files_done,
        totalFiles = progress.total_files,
        bytesDone = progress.bytes_done,
        totalBytes = progress.total_bytes,
        currentFiles = progress.current_files,
      }
      publish()
    end
  end
  if polled.done then
    local job = activeJob
    activeJob = nil
    status.job = nil
    finishJob(job.kind, polled.exitCode, polled.text)
  end
end

local function startJob(kind, argv)
  if activeJob ~= nil then
    return false, "a job is already running"
  end
  if resticPath == nil then
    return false, "restic is not installed"
  end
  if cfg.repository == "" then
    return false, "no repository configured"
  end
  local token, err, paths = jobs.start(argv, { pathPrefix = env.binDir(resticPath) })
  if token == nil then
    return false, err
  end
  activeJob = { token = token, paths = paths, kind = kind, lastSize = nil }
  status.error = ""
  status.job = { kind = kind, percent = 0 }
  publish()
  return true, nil
end

local function triggerBackup()
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

local function handleRestore(req)
  if type(req) ~= "table" or type(req.snapshot) ~= "string" or req.snapshot == "" then
    return false, "restore needs a snapshot id"
  end
  local target = type(req.target) == "string" and req.target ~= "" and req.target or cfg.restoreTarget
  target = env.expandPath(target)
  local argv = restic.restoreArgs(cfg, resticPath, req.snapshot, target, req.include)
  return startJob("restore", argv)
end

function onIpc(event, payload)
  local ok, err = pcall(function()
    if event == state.EVENT_REFRESH then
      refreshSnapshots()
    elseif event == state.EVENT_BACKUP then
      local started, serr = triggerBackup()
      if not started then
        noctalia.notifyError("Restic", tostring(serr))
      end
    elseif event == state.EVENT_CHECK then
      local started, serr = startJob("check", restic.checkArgs(cfg, resticPath))
      if not started then
        noctalia.notifyError("Restic", tostring(serr))
      end
    elseif event == state.EVENT_FORGET_DRY then
      if not restic.hasPolicy(cfg) then
        noctalia.notifyError("Restic", "set at least one keep-* rule first")
      else
        local started, serr = startJob("forget-dry", restic.forgetArgs(cfg, resticPath, true))
        if not started then
          noctalia.notifyError("Restic", tostring(serr))
        end
      end
    elseif event == state.EVENT_FORGET then
      if not restic.hasPolicy(cfg) then
        noctalia.notifyError("Restic", "set at least one keep-* rule first")
      else
        local started, serr = startJob("forget", restic.forgetArgs(cfg, resticPath, false))
        if not started then
          noctalia.notifyError("Restic", tostring(serr))
        end
      end
    elseif event == state.EVENT_RESTORE then
      local started, serr = handleRestore(decodePayload(payload))
      if not started then
        noctalia.notifyError("Restic", tostring(serr))
      end
    elseif event == state.EVENT_CANCEL then
      if activeJob ~= nil then
        jobs.cancel(activeJob.paths)
      end
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
  resolveRestic()
  if lastRun == nil then
    nextRunAt = schedule.nextRun(nowSec(), cfg.intervalMinutes, nowSec())
  end
  publish()
  if resticPath ~= nil and cfg.repository ~= "" then
    refreshSnapshots()
  end
end

function update()
  pollJob()
  if cfg ~= nil and cfg.mode == "plugin" and activeJob == nil
      and cfg.repository ~= "" and #cfg.paths > 0
      and schedule.due(nowSec(), nextRunAt) then
    local started = triggerBackup()
    if not started then
      -- Re-arm so a misconfiguration does not retry every tick.
      nextRunAt = schedule.nextRun(nowSec(), cfg.intervalMinutes, nowSec())
      publish()
    end
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
