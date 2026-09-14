--!nonstrict
-- Prometheus textfile export (contracts doc 5.4).
--
-- The plugin knows things a monitoring stack cannot get anywhere else: when the last backup really
-- succeeded, how old the newest snapshot is, whether the repository still matches what the machine
-- holds. This renders those as an exposition-format file a node_exporter textfile collector (or any
-- scraper reading a directory) picks up.
--
-- Two properties matter more than the field list:
--   * A value the plugin does not know is OMITTED, never emitted as 0. "No backup ever recorded"
--     and "a backup succeeded at the unix epoch" are different statements, and a graph that cannot
--     tell them apart is worse than no graph.
--   * The write is atomic (temp file + renameFile), because a collector may read the file at any
--     moment: a half-written exposition file is a scrape error. The renameFile call is verified
--     against the host API (noctalia.d.luau:239) rather than assumed.
--
-- Everything here is pure except M.write, so the format is unit-testable without a shell.

local M = {}

M.FILENAME = "restic_snapshots.prom"

-- Metric name prefixes, all on one line each in the output.
local PREFIX = "restic_snapshots_"

-- Escape a label value per the exposition format: backslash, double quote and newline.
local function escapeLabel(value)
  local text = tostring(value)
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  return text
end

-- A metric value must be a finite number. Anything else (nil, a string, an infinity) means "not
-- known" and is omitted by the caller; this returns nil for those so the caller can decide.
local function num(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  if n ~= n or n == math.huge or n == -math.huge then
    return nil
  end
  return n
end

local function int(value)
  local n = num(value)
  if n == nil then
    return nil
  end
  return string.format("%d", math.floor(n))
end

-- One metric: HELP, TYPE, then the sample. `value == nil` emits nothing at all (head included), so
-- an unknown metric is absent rather than zero. `labels` is an optional string already escaped.
local function emit(out, name, kind, help, value, labels)
  local rendered = kind == "gauge" and int(value) or nil
  if rendered == nil then
    return false
  end
  local full = PREFIX .. name
  table.insert(out, "# HELP " .. full .. " " .. help)
  table.insert(out, "# TYPE " .. full .. " " .. kind)
  table.insert(out, full .. (labels and ("{" .. labels .. "}") or "") .. " " .. rendered)
  return true
end

-- values = {
--   lastSuccessAt     epoch seconds of the last successful backup
--   snapshotCount     number of snapshots in the repository
--   newestSnapshotAt  epoch seconds of the newest snapshot (age is computed here, from `now`)
--   stale             true when the newest snapshot is older than the staleness threshold
--   repoBytes         total bytes restic reports for the repository
--   repoFiles         total file count restic reports
--   jobKind           kind of the last finished job ("backup", "check", ...), for the label
--   jobExitCode       its exit code
--   lastCheckErrors   errors reported by the last integrity check
--   verifyOk          true/false result of the last restore verification
--   verifyMatched     files that matched the live copy in it
--   verifyFailed      files that disagreed with the live copy in it
-- }
-- Any missing field is omitted from the output.
function M.render(now, values)
  local out = {}
  local v = type(values) == "table" and values or {}
  local at = num(now)

  emit(out, "last_success_timestamp_seconds", "gauge",
    "Unix time of the last successful backup.", v.lastSuccessAt)

  emit(out, "count", "gauge",
    "Snapshots in the repository.", v.snapshotCount)

  local newest = num(v.newestSnapshotAt)
  if newest ~= nil and at ~= nil then
    -- Never negative: clock skew (or a snapshot timestamped a moment in the future) must not draw a
    -- graph that says the backup is from before it was taken.
    local age = at - newest
    if age < 0 then
      age = 0
    end
    emit(out, "newest_age_seconds", "gauge",
      "Age of the newest snapshot in the repository.", age)
  end

  if type(v.stale) == "boolean" then
    emit(out, "stale", "gauge",
      "1 when the newest snapshot is older than the staleness threshold.", v.stale and 1 or 0)
  end

  emit(out, "repo_bytes", "gauge",
    "Bytes stored in the repository, as reported by restic stats.", v.repoBytes)
  emit(out, "repo_files", "gauge",
    "Files in the repository, as reported by restic stats.", v.repoFiles)

  if type(v.jobKind) == "string" and v.jobKind ~= "" then
    emit(out, "last_job_exit_code", "gauge",
      "Exit code of the last finished job.",
      v.jobExitCode, 'kind="' .. escapeLabel(v.jobKind) .. '"')
  end
  emit(out, "last_check_errors", "gauge",
    "Errors reported by the last repository integrity check.", v.lastCheckErrors)

  if type(v.verifyOk) == "boolean" then
    emit(out, "last_verify_ok", "gauge",
      "1 when the last restore verification matched every comparable file.", v.verifyOk and 1 or 0)
  end
  emit(out, "last_verify_matched", "gauge",
    "Files that matched the live copy in the last restore verification.", v.verifyMatched)
  emit(out, "last_verify_failed", "gauge",
    "Files that disagreed with the live copy in the last restore verification.", v.verifyFailed)

  -- Always last, and always present when we could write at all: it dates the file itself, so a
  -- scraper can tell a fresh export from a stale one even if every other value is unknown.
  if at ~= nil then
    emit(out, "export_timestamp_seconds", "gauge",
      "Unix time this export was written.", at)
  end

  if #out == 0 then
    return ""
  end
  return table.concat(out, "\n") .. "\n"
end

-- Write the exposition file into `dir` (created if missing) atomically.
-- Returns (true, path) or (false, reason). An unset directory is not an error the caller must
-- report: the feature is off.
function M.write(dir, text)
  if type(dir) ~= "string" or dir == "" then
    return false, "no metrics directory configured"
  end
  if type(text) ~= "string" or text == "" then
    return false, "nothing to write"
  end
  local root = dir:gsub("/+$", "")
  if root == "" then
    return false, "no metrics directory configured"
  end

  local ok, err = noctalia.mkdirAll(root)
  if ok ~= true then
    return false, "cannot create " .. root .. ": " .. tostring(err or "unknown error")
  end

  local path = root .. "/" .. M.FILENAME
  local tmp = path .. ".tmp"
  local wrote, werr = noctalia.writeFile(tmp, text)
  if wrote ~= true then
    return false, "cannot write " .. tmp .. ": " .. tostring(werr or "unknown error")
  end
  -- Atomic publish: a collector reading the directory never sees a partial file.
  local moved, merr = noctalia.renameFile(tmp, path)
  if moved ~= true then
    noctalia.removeFile(tmp)
    return false, "cannot publish " .. path .. ": " .. tostring(merr or "unknown error")
  end
  return true, path
end

return M
