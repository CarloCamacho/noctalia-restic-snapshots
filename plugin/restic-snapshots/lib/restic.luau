--!nonstrict
-- Restic command construction and output parsing. Pure functions only: no I/O, so the argv
-- builders and parsers are unit-testable outside Noctalia. The only host reads are the guarded
-- `noctalia.getenv("HOME")` used to expand a leading `~`, and the guarded `noctalia.fileInfo`
-- used by validRestoreTarget to see whether a target is already occupied.

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

-- ── small helpers ────────────────────────────────────────────────────────────

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function asList(value)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function homeDir()
  if type(noctalia) == "table" and type(noctalia.getenv) == "function" then
    return tostring(noctalia.getenv("HOME") or "")
  end
  return ""
end

-- Expand a leading `~`. A value we cannot expand is returned unchanged and will fail the
-- absolute-path checks downstream -- failing closed is the safe direction for a restore target.
local function expandPath(path)
  local value = trim(path)
  if value == "~" then
    return homeDir()
  end
  if value:sub(1, 2) == "~/" then
    return homeDir() .. value:sub(2)
  end
  return value
end

-- Lexical normalisation: collapse `//`, drop `.`, resolve `..`. Pure code cannot call realpath,
-- so symlinks are deliberately NOT resolved here (the service re-checks the resolved path before
-- a restore); `..` is resolved so it can never be used to walk out of an allowed root.
local function normalisePath(path)
  local value = expandPath(path)
  local absolute = value:sub(1, 1) == "/"
  local parts = {}
  for segment in value:gmatch("[^/]+") do
    if segment == "." then
      -- current directory: nothing to keep
    elseif segment == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      elseif not absolute then
        table.insert(parts, "..")
      end
    else
      table.insert(parts, segment)
    end
  end
  local joined = table.concat(parts, "/")
  if absolute then
    return "/" .. joined
  end
  return joined
end

-- True when `child` is `parent` or a path below it. Compares whole segments, so `/tmp/data`
-- never matches `/tmp/database`.
local function isInside(parent, child)
  if parent == "" or child == "" then
    return false
  end
  if parent == "/" then
    return child:sub(1, 1) == "/"
  end
  if child == parent then
    return true
  end
  return child:sub(1, #parent + 1) == parent .. "/"
end

local function decodeObject(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, value = pcall(noctalia.json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil
  end
  return value
end

-- Default bound for the list-shaped parse results. The panel shows a handful of rows and the
-- widget a count, so every list crosses the IPC boundary bounded.
local DEFAULT_LIMIT = 200

local function bound(limit, fallback)
  local value = tonumber(limit)
  if value == nil or value <= 0 then
    return fallback or DEFAULT_LIMIT
  end
  return math.floor(value)
end

-- ── restore verification bounds (0.3.0) ──────────────────────────────────────

-- The largest file one verification reads whole. Comparing two copies means holding both in
-- memory, and the host's readFile reads a whole file with no bound of its own, so anything bigger
-- is skipped -- reported as skipped, never as matched.
M.VERIFY_MAX_BYTES = 4 * 1024 * 1024

-- The range `verify_file_count` is declared with in plugin.toml (min 1, max 25, default 3).
M.VERIFY_FILES_MIN = 1
M.VERIFY_FILES_MAX = 25
M.VERIFY_FILES_DEFAULT = 3

-- Clamp `verify_file_count` into that range, so a hand-edited settings file cannot turn one
-- verification into a full-snapshot restore.
local function verifyFileCount(value)
  local count = math.floor(tonumber(value) or 0)
  if count < M.VERIFY_FILES_MIN then
    return M.VERIFY_FILES_DEFAULT
  end
  if count > M.VERIFY_FILES_MAX then
    return M.VERIFY_FILES_MAX
  end
  return count
end

-- ── redaction ────────────────────────────────────────────────────────────────

-- Query parameters whose value is a credential.
local SECRET_KEYS = {
  password = true, passwd = true, pass = true, pwd = true, secret = true,
  client_secret = true, token = true, access_token = true, auth = true,
  authorization = true, api_key = true, apikey = true, access_key = true,
  accesskey = true, credential = true, credentials = true, sig = true,
  signature = true, sas = true, sastoken = true, key = true,
}

-- A path segment that is an opaque credential rather than a name: a long hex blob (SHA-256,
-- key id, repository id), a long base64 blob (signed token), or an AWS access-key id.
local function looksLikeToken(segment)
  if #segment < 32 then
    return false
  end
  if segment:match("^%x+$") then
    return true
  end
  if segment:match("^[A-Za-z0-9%+/=_%-]+$") and segment:match("[%+/=]") then
    return true
  end
  return false
end

-- A plain filesystem path is never redacted: it carries no credentials, and mangling it would
-- hide which repository the user configured. Remotes are recognised by a `scheme:` prefix.
local function looksLikeRemote(text)
  local first = text:sub(1, 1)
  if first == "/" or first == "~" or first == "." then
    return false
  end
  if text:find("//", 1, true) then
    return true
  end
  return text:match("^[%a][%w%+%-%.]*:") ~= nil
end

local function redactSegment(segment)
  local key, value = segment:match("^([%w_%-%.]+)=(.*)$")
  if key ~= nil and SECRET_KEYS[key:lower()] and value ~= "***" then
    return key .. "=***"
  end
  if looksLikeToken(segment) then
    return "***"
  end
  return segment
end

-- Strip `user:password@` userinfo, credential query parameters and token-looking segments so a
-- repository string can be shown in the panel header and the widget tooltip.
function M.redactRepository(value)
  if value == nil then
    return ""
  end
  local text = tostring(value)
  if text == "" or not looksLikeRemote(text) then
    return text
  end
  -- `sftp://user:pass@host:/path` and `s3:https://KEY:SECRET@host/bucket`
  text = text:gsub("(//)([^/@]+)@", "%1***@")
  -- `sftp:user@host:/path` (scp-style userinfo, no `//`)
  text = text:gsub("^(%a[%w%+%-%.]*:)([^/]-)@", "%1***@")
  -- `rest:https://host/repo?token=abc&user=ian`
  text = text:gsub("([?&])([%w_%-%.]*)(=)([^&]*)", function(separator, key, equals, param)
    if SECRET_KEYS[key:lower()] and param ~= "" and param ~= "***" then
      return separator .. key .. equals .. "***"
    end
    return separator .. key .. equals .. param
  end)
  -- opaque blobs used as a path segment
  text = text:gsub("[^/:]+", redactSegment)
  return text
end

-- ── configuration ────────────────────────────────────────────────────────────

-- Normalise the effective settings into one table the rest of the code uses. Every key is always
-- present, so consumers never need a nil check.
function M.config(settings)
  settings = settings or {}
  local repository = trim(settings.repository)
  local restoreTarget = expandPath(settings.restore_target)
  if restoreTarget == "" then
    restoreTarget = expandPath("~/restore")
  end
  -- Only absolute entries become allow-roots: a relative one would be ambiguous and could not be
  -- compared safely against a concrete target, so it is dropped (dropping can only deny a
  -- restore, never permit one).
  local allowRoots = {}
  for _, root in ipairs(asList(settings.restore_allow_roots)) do
    local value = expandPath(root)
    if value ~= "" and value:sub(1, 1) == "/" then
      table.insert(allowRoots, value)
    end
  end
  -- A non-positive watchdog ceiling would cancel every job the moment it starts, so it is
  -- treated as "unset" and the default applies.
  local jobTimeout = tonumber(settings.job_timeout_minutes) or 180
  if jobTimeout <= 0 then
    jobTimeout = 180
  end
  return {
    bin = trim(settings.restic_bin) ~= "" and trim(settings.restic_bin) or "restic",
    repository = repository,
    redactedRepository = M.redactRepository(repository),
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
    restoreTarget = restoreTarget,
    restoreAllowRoots = allowRoots,
    checkSubset = trim(settings.check_subset) ~= "" and trim(settings.check_subset) or "1/100",
    checkIntervalHours = math.max(0, tonumber(settings.check_interval_hours) or 0),
    -- Restore verification (0.3.0). 0 hours means off, which is the manifest's default.
    verifyIntervalHours = math.max(0, tonumber(settings.verify_interval_hours) or 0),
    verifyFileCount = verifyFileCount(settings.verify_file_count),
    staleAfterHours = math.max(0, tonumber(settings.stale_after_hours) or 0),
    jobTimeoutMinutes = jobTimeout,
    envFile = trim(settings.env_file),
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

-- Read-only commands carry `--no-lock`: the service skips refreshes while a job holds the lock,
-- but a stale lock left by a crashed restic must not blank the panel.
local function readOnlyArgs(cfg, binPath, command)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "--no-lock")
  table.insert(argv, command)
  return argv
end

function M.backupArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "backup")
  for _, path in ipairs(cfg.paths) do
    table.insert(argv, path)
  end
  table.insert(argv, "--json")
  -- [0.6.0] One verbose_status record per file and per directory. Without it `backup --json` writes
  -- a SINGLE summary object for a run that copies nothing -- 473 bytes, identical every hour -- so
  -- the Log tab had nothing to show and nothing anywhere named a file. The job script drops the
  -- `unchanged` records, so the log keeps the short list of what this run actually did. Only backup
  -- asks for it: it is the only command with per-file actions worth recording.
  table.insert(argv, "--verbose")
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
  local argv = readOnlyArgs(cfg, binPath, "snapshots")
  table.insert(argv, "--json")
  return argv
end

function M.statsArgs(cfg, binPath)
  local argv = readOnlyArgs(cfg, binPath, "stats")
  table.insert(argv, "--json")
  return argv
end

-- `check` is not read-only in restic's locking model, so it keeps the lock -- and therefore never
-- carries `--no-lock`. The rotating subset comes from the settings unless a caller overrides it.
function M.checkArgs(cfg, binPath, subsetOverride)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "check")
  table.insert(argv, "--json")
  local subset = trim(subsetOverride)
  if subset == "" then
    subset = cfg.checkSubset
  end
  if subset ~= "" then
    table.insert(argv, "--read-data-subset=" .. subset)
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

-- Forget exactly one snapshot. Never `--prune`: rewriting the repository is a separate, explicit
-- step (retention preview -> forgetArgs), and a single-snapshot prune deletes unreferenced data
-- that other snapshots may still share.
-- Returns nil, err for an id that is not a hex snapshot id, so an untrusted id can never reach
-- restic in the positional argument slot.
function M.forgetOneArgs(cfg, binPath, snapshotId)
  if not M.validSnapshotId(snapshotId) then
    return nil, "invalid snapshot id"
  end
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "forget")
  table.insert(argv, snapshotId)
  table.insert(argv, "--json")
  return argv
end

-- The destination itself is vetted by the service with validRestoreTarget (the allow-list needs the
-- whole config); here we only refuse a destination restic would resolve relative to its own working
-- directory, and refuse an id that could be read as a flag.
function M.restoreArgs(cfg, binPath, snapshot, target, includes, opts)
  if not M.validSnapshotId(snapshot) then
    return nil, "invalid snapshot id"
  end
  local destination = expandPath(target)
  if destination == "" or destination:sub(1, 1) ~= "/" then
    return nil, "restore target must be an absolute path"
  end
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "restore")
  table.insert(argv, snapshot)
  table.insert(argv, "--target")
  table.insert(argv, destination)
  for _, pattern in ipairs(asList(includes)) do
    if type(pattern) == "string" and pattern ~= "" then
      table.insert(argv, "--include")
      table.insert(argv, pattern)
    end
  end
  if type(opts) == "table" and opts.dryRun then
    table.insert(argv, "--dry-run")
  end
  table.insert(argv, "--json")
  return argv
end

-- `ls`/`diff` take their snapshot ids positionally, so an untrusted id from IPC is validated here
-- before it can be read as a flag. Both are read-only and therefore also carry `--no-lock`.
function M.lsArgs(cfg, binPath, snapshot)
  if not M.validSnapshotId(snapshot) then
    return nil, "invalid snapshot id"
  end
  local argv = readOnlyArgs(cfg, binPath, "ls")
  table.insert(argv, snapshot)
  table.insert(argv, "--json")
  return argv
end

function M.diffArgs(cfg, binPath, fromId, toId)
  if not M.validSnapshotId(fromId) or not M.validSnapshotId(toId) then
    return nil, "invalid snapshot id"
  end
  local argv = readOnlyArgs(cfg, binPath, "diff")
  table.insert(argv, fromId)
  table.insert(argv, toId)
  table.insert(argv, "--json")
  return argv
end

function M.initArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "init")
  table.insert(argv, "--json")
  return argv
end

-- `unlock` must NOT carry `--no-lock`: removing a stale lock is the whole point, and `--no-lock`
-- would make restic ignore the very lock file the command exists to delete.
function M.unlockArgs(cfg, binPath)
  local argv = M.baseArgs(cfg, binPath)
  table.insert(argv, "unlock")
  table.insert(argv, "--remove-all")
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

-- One status object from the `.status` file, which the job script overwrites in place. The last
-- line is preferred, but a torn trailing line falls back to the previous complete one.
function M.lastStatusLine(text)
  if type(text) ~= "string" then
    return nil
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  for i = #lines, 1, -1 do
    local decoded = decodeObject(lines[i])
    if decoded ~= nil then
      return decoded
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
  return decodeObject(text)
end

-- stats --json returns one object: {"total_size":..,"total_file_count":..,"snapshots_count":..}.
-- Returns nil when the text is not a stats payload, so a caller cannot render a bogus card.
function M.parseStats(text)
  local decoded = decodeObject(text)
  if decoded == nil then
    return nil
  end
  if decoded.total_size == nil and decoded.total_file_count == nil and decoded.snapshots_count == nil then
    return nil
  end
  return {
    totalBytes = tonumber(decoded.total_size) or 0,
    totalFileCount = tonumber(decoded.total_file_count) or 0,
    snapshotsCount = tonumber(decoded.snapshots_count) or 0,
  }
end

-- ls --json is a JSONL stream: one `snapshot` record, then one `node` record per entry. Directories
-- and symlinks carry no `size`. Entries are bounded; `count` still reports the true total.
function M.parseLs(text, limit)
  local max = bound(limit)
  local entries = {}
  local count = 0
  local truncated = false
  if type(text) ~= "string" then
    return { entries = entries, truncated = false, count = 0 }
  end
  for line in text:gmatch("[^\n]+") do
    local node = decodeObject(line)
    if node ~= nil and node.message_type ~= "snapshot" then
      count = count + 1
      if #entries < max then
        table.insert(entries, {
          name = node.name,
          type = node.type,
          path = node.path,
          size = tonumber(node.size),
        })
      else
        truncated = true
      end
    end
  end
  return { entries = entries, truncated = truncated, count = count }
end

-- diff --json is a JSONL stream of `change` records plus one final `statistics` record. Counts come
-- from the change records ('-' removed, '+' added, 'M' changed, 'T' type-changed, which is a
-- change); an unchanged pair emits only the statistics record, so the counts fall back to it.
-- Path lists are bounded, the counts are not.
function M.parseDiff(text, limit)
  local max = bound(limit)
  local result = {
    added = 0,
    removed = 0,
    changed = 0,
    truncated = false,
    addedPaths = {},
    removedPaths = {},
    changedPaths = {},
  }
  local statistics = nil
  local changes = 0
  if type(text) ~= "string" then
    return nil
  end
  for line in text:gmatch("[^\n]+") do
    local record = decodeObject(line)
    if record ~= nil and record.message_type == "change" then
      changes = changes + 1
      local list = nil
      if record.modifier == "-" then
        result.removed = result.removed + 1
        list = result.removedPaths
      elseif record.modifier == "+" then
        result.added = result.added + 1
        list = result.addedPaths
      else
        result.changed = result.changed + 1
        list = result.changedPaths
      end
      if #list < max then
        table.insert(list, record.path)
      else
        result.truncated = true
      end
    elseif record ~= nil and record.message_type == "statistics" then
      statistics = record
    end
  end
  if changes == 0 and statistics ~= nil then
    local added = statistics.added or {}
    local removed = statistics.removed or {}
    result.added = tonumber(added.files) or 0
    result.removed = tonumber(removed.files) or 0
    result.changed = tonumber(statistics.changed_files) or 0
  end
  if changes == 0 and statistics == nil then
    return nil
  end
  return result
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

-- ── forget preview ───────────────────────────────────────────────────────────

-- A forget --json group always carries at least one of these. It is what tells a real group record
-- apart from a decoded *array* of groups, which is also a table and would otherwise pass the same
-- test -- the confusion that produced the defect fixed below.
local function isForgetGroup(value)
  return type(value) == "table"
    and (value.keep ~= nil or value.remove ~= nil or value.paths ~= nil or value.host ~= nil)
end

-- `forget --dry-run --json` returns one record per group (host+paths) with `keep`, `remove` and
-- `reasons`. `reasons` lists every snapshot with the rule it matched, including kept ones, so the
-- removed set is read from `remove` only (which is `null` when the group loses nothing).
-- The removed snapshots are listed -- bounded -- because the panel shows exactly what a
-- destructive prune would delete before the user confirms it.
function M.summariseForgetDry(objects, limit)
  if type(objects) ~= "table" then
    return nil
  end
  local max = bound(limit, 50)

  -- The caller does NOT hand us the array: it hands us what parseJsonLines produced, which wraps
  -- each decoded LINE in a table. restic writes the whole forget array on a single line, so the
  -- service passes { array } and, without this unwrap, the group test below is satisfied by the
  -- WRAPPER: every "group" is really the array, group.keep is nil, and this function returns a
  -- confident keepCount 0 / removeCount 0 for a repository with plenty to keep and to remove.
  -- That is a destructive gate reporting "nothing to do" from an unreadable payload.
  if #objects == 1 and type(objects[1]) == "table"
    and (type(objects[1][1]) == "table" or next(objects[1]) == nil) then
    objects = objects[1]
  end

  local groups
  if isForgetGroup(objects[1]) then
    groups = objects
  elseif isForgetGroup(objects) then
    groups = { objects }
  elseif next(objects) == nil then
    -- An empty payload is restic saying "nothing matched", which is a real zero. It must stay a
    -- zero: the panel renders it, and it is the honest answer.
    groups = {}
  else
    -- Non-empty, but neither a group nor a list of groups. Returning zeroes here would tell the
    -- user there is nothing to prune; nil makes the caller report a failure instead.
    return nil
  end
  local keepCount = 0
  local removeCount = 0
  local remove = {}
  local truncated = false
  for _, group in ipairs(groups) do
    if type(group) == "table" then
      keepCount = keepCount + #asList(group.keep)
      for _, snapshot in ipairs(asList(group.remove)) do
        removeCount = removeCount + 1
        if type(snapshot) == "table" and #remove < max then
          table.insert(remove, {
            id = snapshot.id,
            shortId = snapshot.short_id,
            time = snapshot.time,
          })
        else
          truncated = true
        end
      end
    end
  end
  return { keepCount = keepCount, removeCount = removeCount, remove = remove, truncated = truncated }
end

-- ── snapshot summaries and filtering ─────────────────────────────────────────

local function daysFromCivil(year, month, day)
  local y = year
  if month <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (month + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- RFC3339 -> epoch seconds with pure arithmetic.
-- ASSUMPTION: restic always emits an explicit numeric offset -- verified on 0.19.1, e.g.
-- "2026-09-14T21:20:42.108154635+08:00" -- so no timezone database is needed and `os.time` (which
-- interprets a table in the local zone) is deliberately avoided: it would be wrong on a box whose
-- TZ differs from the snapshot offset. A timestamp without an offset is refused rather than
-- guessed. Sub-second digits are floored: staleness is compared in whole seconds.
function M.epochFromRfc3339(value)
  if type(value) ~= "string" then
    return nil
  end
  local text = value:match("^%s*(.-)%s*$")
  local numeric = tonumber(text)
  if numeric ~= nil then
    return math.floor(numeric)
  end
  local year, month, day, hour, minute, second, rest =
    text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
  if year == nil then
    return nil
  end
  local body = rest:gsub("^%.%d+", "")
  local offset = 0
  if body:match("^[Zz]$") then
    offset = 0
  else
    local sign, offsetHours, offsetMinutes = body:match("^([%+%-])(%d%d):?(%d%d)$")
    if sign == nil then
      return nil
    end
    offset = tonumber(offsetHours) * 3600 + tonumber(offsetMinutes) * 60
    if sign == "-" then
      offset = -offset
    end
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60 then
    return nil
  end
  return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset
end

-- The single source of truth for "how old is the newest snapshot", so the service, the panel and
-- the widget cannot disagree. `newestAt` is nil when no row carries a readable time.
function M.snapshotSummary(rows)
  local count = 0
  local newestAt = nil
  for _, row in ipairs(asList(rows)) do
    if type(row) == "table" then
      count = count + 1
      local at = M.epochFromRfc3339(row.time)
      if at ~= nil and (newestAt == nil or at > newestAt) then
        newestAt = at
      end
    end
  end
  return { count = count, newestAt = newestAt }
end

-- filter = { host = exact hostname, tag = exact tag, text = case-insensitive substring }.
-- Every supplied filter must match; an empty filter returns every row.
function M.filterSnapshots(rows, filter)
  local out = {}
  if type(rows) ~= "table" then
    return out
  end
  if type(filter) ~= "table" then
    filter = {}
  end
  local host = trim(filter.host)
  local tag = trim(filter.tag)
  local text = trim(filter.text):lower()
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local matches = true
      if host ~= "" and tostring(row.hostname or "") ~= host then
        matches = false
      end
      if matches and tag ~= "" then
        local tagged = false
        for _, value in ipairs(asList(row.tags)) do
          if tostring(value) == tag then
            tagged = true
          end
        end
        matches = tagged
      end
      if matches and text ~= "" then
        local haystack = table.concat({
          tostring(row.time or ""),
          tostring(row.hostname or ""),
          tostring(row.shortId or ""),
          tostring(row.id or ""),
          table.concat(asList(row.tags), " "),
          table.concat(asList(row.paths), " "),
        }, " "):lower()
        if haystack:find(text, 1, true) == nil then
          matches = false
        end
      end
      if matches then
        table.insert(out, row)
      end
    end
  end
  return out
end

-- ── validators ───────────────────────────────────────────────────────────────

-- A restic snapshot id is hex; "latest" and anything flag-shaped must never reach the positional
-- argument slot, so only the documented 4-64 hex range is accepted.
function M.validSnapshotId(id)
  if type(id) ~= "string" then
    return false
  end
  if #id < 4 or #id > 64 then
    return false
  end
  return id:match("^[0-9a-fA-F]+$") ~= nil
end

local function rootsLabel(cfg)
  local parts = {}
  if cfg ~= nil then
    local target = normalisePath(cfg.restoreTarget)
    if target ~= "" then
      table.insert(parts, target)
    end
    for _, root in ipairs(asList(cfg.restoreAllowRoots)) do
      local value = normalisePath(root)
      if value ~= "" then
        table.insert(parts, value)
      end
    end
  end
  if #parts == 0 then
    return "a configured restore target"
  end
  return table.concat(parts, ", ")
end

-- The destination allow-list. Order matters: the first failing rule names the reason the user
-- sees, and every rule fails closed.
function M.validRestoreTarget(cfg, path)
  if type(path) ~= "string" or trim(path) == "" then
    return false, "restore target is required"
  end
  local target = normalisePath(path)
  if target:sub(1, 1) ~= "/" then
    return false, "restore target must be an absolute path"
  end
  if target == "/" then
    return false, "refusing to restore over the filesystem root"
  end
  local home = normalisePath("~")
  if home ~= "" and target == home then
    return false, "refusing to restore over the home directory"
  end
  -- Restoring inside a backup source would write the staging copy into the tree the next backup
  -- captures, and could overwrite the live files being protected.
  for _, source in ipairs(asList(cfg ~= nil and cfg.paths or nil)) do
    local sourcePath = normalisePath(source)
    if sourcePath ~= "" and sourcePath ~= "/" and isInside(sourcePath, target) then
      return false, "restore target is inside a backup source (" .. sourcePath .. ")"
    end
  end
  local permitted = false
  if cfg ~= nil then
    if isInside(normalisePath(cfg.restoreTarget), target) then
      permitted = true
    end
    if not permitted then
      for _, root in ipairs(asList(cfg.restoreAllowRoots)) do
        if isInside(normalisePath(root), target) then
          permitted = true
        end
      end
    end
  end
  if not permitted then
    return false, "restore target must be inside " .. rootsLabel(cfg)
  end
  -- A target that already exists as a file (or symlink, socket, ...) must not be clobbered.
  if type(noctalia) == "table" and type(noctalia.fileInfo) == "function" then
    local info = noctalia.fileInfo(target)
    if info ~= nil and info.isDir == false then
      return false, "restore target exists and is not a directory"
    end
  end
  return true
end

-- ── formatting ───────────────────────────────────────────────────────────────

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

-- ── restore verification (0.3.0) ─────────────────────────────────────────────
-- A verification restores a few files out of the newest snapshot and compares them with the live
-- files. Everything in this section is pure: WHICH files are chosen, where the scratch copy goes,
-- and the judgement of one comparison. The I/O stays in service.luau, so the part that decides
-- "the backup restores" -- the part that must not be self-deceiving -- is testable on its own.

-- A timestamp in epoch seconds. The host reports mtime in seconds (a double, verified in
-- src/scripting/luau_host.cpp), but a millisecond value is accepted too: the two are told apart by
-- magnitude (1e11 seconds is the year 5138; 1e11 milliseconds is 1973), so an mtime is never
-- silently compared against the wrong unit and a changed file is never mistaken for a match.
function M.mtimeSeconds(value)
  local n = tonumber(value)
  if n == nil or n <= 0 then
    return nil
  end
  if n >= 1e11 then
    return math.floor(n / 1000)
  end
  return math.floor(n)
end

-- The newest snapshot in a list of rows, with its time as epoch seconds. Rows whose time cannot be
-- read, or whose id is not a real snapshot id, are never chosen: verifying against a snapshot
-- whose age is unknown would make every "modified after the snapshot" comparison meaningless.
function M.newestSnapshot(rows)
  local best = nil
  local bestAt = nil
  for _, row in ipairs(asList(rows)) do
    if type(row) == "table" and M.validSnapshotId(row.id) then
      local at = M.epochFromRfc3339(row.time)
      if at ~= nil and (bestAt == nil or at > bestAt) then
        best = row
        bestAt = at
      end
    end
  end
  if best == nil then
    return nil
  end
  return { id = best.id, time = best.time, at = bestAt, shortId = best.shortId }
end

-- The scratch directory one verification writes into. Kept inside the configured restore target so
-- the existing allow-list (validRestoreTarget) still owns every write path, and epoch-stamped so
-- two verifications can never collide -- an earlier run's leftovers (see the cleanup note in
-- service.luau: the host cannot remove directories) cannot make the next one fail.
-- A trailing slash (a user typing it into the settings) is dropped so the path restic is handed is
-- a clean one; a base that reduces to nothing is refused rather than guessed at.
function M.verifyTarget(base, at)
  local root = expandPath(base):gsub("/+$", "")
  local stamp = math.floor(tonumber(at) or 0)
  if root == "" or stamp <= 0 then
    return nil
  end
  return root .. "/.verify/" .. tostring(stamp)
end

-- Choose the files to verify out of what `restic ls --json` returned (post-parseLs entries).
--
-- * regular files only (`type == "file"`): a directory or a symlink has nothing to compare;
-- * nothing larger than maxBytes, because the comparison reads both copies whole;
-- * files with content are preferred -- comparing two zero-byte files proves nothing -- but a
--   snapshot of only empty files still verifies rather than reporting "no usable files";
-- * deterministic for a given listing, and spread across it: the picks are evenly spaced, so the
--   same snapshot always verifies the same files and consecutive verifications of a growing
--   snapshot do not all land on the first few paths.
--
-- Returns { files = { { path, size }, ... }, wanted, available, skippedEmpty, skippedLarge }.
-- `available` counts the regular files the listing offered, so a caller can tell "the snapshot has
-- three files and we checked three" from "the snapshot has 4000 files and we checked three".
function M.selectVerifyFiles(entries, count, maxBytes)
  local want = verifyFileCount(count)
  local limit = tonumber(maxBytes)
  if limit == nil or limit <= 0 then
    limit = M.VERIFY_MAX_BYTES
  end
  local usable = {}
  local withContent = {}
  local skippedEmpty = 0
  local skippedLarge = 0
  for _, entry in ipairs(asList(entries)) do
    if type(entry) == "table" and entry.type == "file" then
      local path = entry.path
      local bytes = tonumber(entry.size)
      -- An absolute path is the only kind that can be compared with a live file; a flag-shaped or
      -- relative one is not a path restic will restore where we would look for it.
      if type(path) == "string" and path:sub(1, 1) == "/" and bytes ~= nil then
        if bytes <= 0 then
          skippedEmpty = skippedEmpty + 1
          table.insert(usable, { path = path, size = bytes })
        elseif bytes > limit then
          skippedLarge = skippedLarge + 1
        else
          table.insert(usable, { path = path, size = bytes })
          table.insert(withContent, { path = path, size = bytes })
        end
      end
    end
  end
  -- Prefer files that have content, but never refuse to verify just because a snapshot holds only
  -- empty ones.
  local pool = #withContent >= want and withContent or usable
  local total = #pool
  local picks = want < total and want or total
  local files = {}
  for i = 1, picks do
    local index = math.floor((i - 0.5) * total / picks) + 1
    table.insert(files, pool[index])
  end
  return {
    files = files,
    wanted = want,
    available = total,
    skippedEmpty = skippedEmpty,
    skippedLarge = skippedLarge,
  }
end

-- The `--include` patterns for a verification: one per chosen file, absolute only, bounded. A
-- relative entry is dropped rather than guessed at (dropping can only verify less, never more).
-- NOTE: restic matches these as patterns. A path containing glob metacharacters can therefore
-- over- or under-match, which fails closed here: the restore produces no copy for that file and
-- the verification reports it as a failure instead of a match.
function M.verifyIncludes(files)
  local out = {}
  for _, entry in ipairs(asList(files)) do
    local path = type(entry) == "table" and entry.path or entry
    if type(path) == "string" and path:sub(1, 1) == "/" and #out < M.VERIFY_FILES_MAX then
      table.insert(out, path)
    end
  end
  return out
end

-- The argv for the restore half of a verification. It delegates to restoreArgs so the argv order
-- and the id/target validation cannot drift from the user-facing restore, and refuses an empty
-- file set: a "restore" of nothing would publish a meaningless success.
function M.verifyRestoreArgs(cfg, binPath, snapshot, target, files)
  local includes = M.verifyIncludes(files)
  if #includes == 0 then
    return nil, "no files to verify"
  end
  return M.restoreArgs(cfg, binPath, snapshot, target, includes, { dryRun = false })
end

-- The judgement for one file: what the restore wrote against what is live now.
--
--   restored = { read = <bool>, text = <string|nil> }   the copy restic restored
--   live     = { exists, isFile, read, text, mtime, size }  the live file, as observed
--   opts     = { snapshotAt = <epoch|nil>, maxBytes = <n> }
--
-- Outcomes, and why each one is honest:
--   "matched"  the live file exists and holds exactly the restored bytes.
--   "failed"   the live file exists, differs, and could not legitimately have changed since the
--              snapshot: the backup disagrees with reality. A restore that produced no readable
--              copy is a failure too -- "we could not read the archive back" is the exact thing
--              this feature exists to detect, and calling it a skip would be self-deception.
--   "skipped"  nothing can be proven about this file for a reason that is not the backup's fault:
--              the live file is gone, it was legitimately modified after the snapshot, it is too
--              large to compare in this runtime, or it could not be read.
--
-- An unknown snapshot time (snapshotAt == nil) deliberately excuses nothing: with no timestamp to
-- compare against, a difference is reported rather than explained away.
function M.verifyOutcome(restored, live, opts)
  restored = restored or {}
  live = live or {}
  opts = opts or {}
  if restored.read ~= true or type(restored.text) ~= "string" then
    return { status = "failed", reason = "the restore produced no readable copy" }
  end
  if live.exists ~= true or live.isFile ~= true then
    return { status = "skipped", reason = "the live file is gone" }
  end
  local snapshotAt = tonumber(opts.snapshotAt)
  local mtime = tonumber(live.mtime)
  if snapshotAt ~= nil and mtime ~= nil and mtime > snapshotAt then
    return { status = "skipped", reason = "the live file changed after the snapshot" }
  end
  local maxBytes = tonumber(opts.maxBytes) or M.VERIFY_MAX_BYTES
  local size = tonumber(live.size)
  if size ~= nil and size > maxBytes then
    return { status = "skipped", reason = "the live file is too large to compare" }
  end
  if live.read ~= true or type(live.text) ~= "string" then
    return { status = "skipped", reason = "the live file could not be read" }
  end
  if live.text == restored.text then
    return { status = "matched" }
  end
  return { status = "failed", reason = "the backup does not match the live file" }
end

return M
