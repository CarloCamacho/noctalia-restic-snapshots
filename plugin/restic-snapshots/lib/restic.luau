--!nonstrict
-- Restic command construction and output parsing. Pure functions only: no I/O, so the argv
-- builders and parsers are unit-testable outside Noctalia.

local M = {}

-- ── quoting ──────────────────────────────────────────────────────────────────

function M.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.shellArgv(argv)
  local out = {}
  for _, value in ipairs(argv) do
    table.insert(out, M.shellQuote(value))
  end
  return table.concat(out, " ")
end

-- ── configuration ────────────────────────────────────────────────────────────

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function asList(value)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

-- Normalise the effective settings into one table the rest of the code uses.
function M.config(settings)
  settings = settings or {}
  return {
    bin = trim(settings.restic_bin) ~= "" and trim(settings.restic_bin) or "restic",
    repository = trim(settings.repository),
    passwordFile = trim(settings.password_file),
    paths = asList(settings.backup_paths),
    tags = asList(settings.backup_tags),
    excludeFile = trim(settings.exclude_file),
    mode = trim(settings.mode) ~= "" and trim(settings.mode) or "plugin",
    intervalMinutes = tonumber(settings.interval_minutes) or 60,
    keepLast = tonumber(settings.keep_last) or 0,
    keepDaily = tonumber(settings.keep_daily) or 0,
    keepWeekly = tonumber(settings.keep_weekly) or 0,
    keepMonthly = tonumber(settings.keep_monthly) or 0,
    restoreTarget = trim(settings.restore_target) ~= "" and trim(settings.restore_target) or "~/restore",
    checkSubset = trim(settings.check_subset) ~= "" and trim(settings.check_subset) or "1/100",
  }
end

-- Global flags every command needs. `--password-file` avoids putting the secret in the
-- environment and is a restic flag, not a shell assignment.
function M.baseArgs(cfg, binPath)
  local argv = { binPath or cfg.bin }
  if cfg.passwordFile ~= "" then
    table.insert(argv, "--password-file")
    table.insert(argv, cfg.passwordFile)
  end
  table.insert(argv, "-r")
  table.insert(argv, cfg.repository)
  return argv
end

-- ── argv builders ────────────────────────────────────────────────────────────

function M.backupArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "backup")
  for _, path in ipairs(cfg.paths) do
    table.insert(argv, path)
  end
  table.insert(argv, "--json")
  for _, tag in ipairs(cfg.tags) do
    table.insert(argv, "--tag")
    table.insert(argv, tag)
  end
  if cfg.excludeFile ~= "" then
    table.insert(argv, "--exclude-file")
    table.insert(argv, cfg.excludeFile)
  end
  return argv
end

function M.snapshotsArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "snapshots")
  table.insert(argv, "--json")
  return argv
end

function M.statsArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "stats")
  table.insert(argv, "--json")
  return argv
end

function M.checkArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "check")
  table.insert(argv, "--json")
  if cfg.checkSubset ~= "" then
    table.insert(argv, "--read-data-subset=" .. cfg.checkSubset)
  end
  return argv
end

-- Retention policy as restic flags. At least one keep-* rule must be present, or restic would
-- be asked to delete everything.
function M.policyArgs(cfg)
  local argv = {}
  local pairs_ = {
    { cfg.keepLast, "--keep-last" },
    { cfg.keepDaily, "--keep-daily" },
    { cfg.keepWeekly, "--keep-weekly" },
    { cfg.keepMonthly, "--keep-monthly" },
  }
  for _, entry in ipairs(pairs_) do
    if entry[1] and entry[1] > 0 then
      table.insert(argv, entry[2])
      table.insert(argv, tostring(math.floor(entry[1])))
    end
  end
  return argv
end

function M.hasPolicy(cfg)
  return #M.policyArgs(cfg) > 0
end

function M.forgetArgs(cfg, binPath, dryRun)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "forget")
  for _, value in ipairs(M.policyArgs(cfg)) do
    table.insert(argv, value)
  end
  if dryRun then
    table.insert(argv, "--dry-run")
  else
    table.insert(argv, "--prune")
  end
  table.insert(argv, "--json")
  return argv
end

function M.restoreArgs(cfg, binPath, snapshot, target, includes)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "restore")
  table.insert(argv, snapshot)
  table.insert(argv, "--target")
  table.insert(argv, target)
  for _, pattern in ipairs(asList(includes)) do
    table.insert(argv, "--include")
    table.insert(argv, pattern)
  end
  table.insert(argv, "--json")
  return argv
end

function M.lsArgs(cfg, binPath, snapshot)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "ls")
  table.insert(argv, snapshot)
  table.insert(argv, "--json")
  return argv
end

-- ── parsing ──────────────────────────────────────────────────────────────────

-- Decode a JSONL stream (restic --json progress + summary), skipping malformed lines.
function M.parseJsonLines(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  for line in text:gmatch("[^\n]+") do
    local ok, decoded = pcall(noctalia.json.decode, line)
    if ok and type(decoded) == "table" then
      table.insert(out, decoded)
    end
  end
  return out
end

function M.lastSummary(objects)
  for i = #objects, 1, -1 do
    if objects[i].message_type == "summary" then
      return objects[i]
    end
  end
  return nil
end

-- The newest status line (backup progress) or nil.
function M.lastStatus(objects)
  for i = #objects, 1, -1 do
    if objects[i].message_type == "status" then
      return objects[i]
    end
  end
  return nil
end

-- snapshots --json returns a single JSON array.
function M.parseSnapshots(text)
  if type(text) ~= "string" or text == "" then
    return {}
  end
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

function M.parseObject(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

-- Compact one snapshot for state/UI. Bounded fields only.
function M.snapshotRow(snapshot)
  local summary = snapshot.summary or {}
  return {
    id = snapshot.id,
    shortId = snapshot.short_id,
    time = snapshot.time,
    hostname = snapshot.hostname,
    tags = snapshot.tags or {},
    paths = snapshot.paths or {},
    filesProcessed = summary.total_files_processed,
    bytesProcessed = summary.total_bytes_processed,
    dataAdded = summary.data_added,
  }
end

function M.humanBytes(value)
  local n = tonumber(value)
  if n == nil then
    return "—"
  end
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local index = 1
  while n >= 1024 and index < #units do
    n = n / 1024
    index = index + 1
  end
  if index == 1 then
    return string.format("%d %s", n, units[index])
  end
  return string.format("%.1f %s", n, units[index])
end

function M.ageLabel(seconds)
  local s = tonumber(seconds) or 0
  if s < 60 then
    return string.format("%ds", s)
  end
  if s < 3600 then
    return string.format("%dm", math.floor(s / 60))
  end
  if s < 86400 then
    return string.format("%dh", math.floor(s / 3600))
  end
  return string.format("%dd", math.floor(s / 86400))
end

return M
