--!nonstrict
-- Tests for lib/metrics.luau: the Prometheus textfile export.
--
-- The properties under test are the ones a graph depends on: an unknown value is ABSENT (never a
-- confident 0), the file is valid exposition format (every HELP has a TYPE, every sample a value),
-- and the write is atomic (temp + rename, so a scraper never reads half a file).
local here = (debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/lua/")
local harness = dofile(here .. "/tests/lua/harness.lua")
local H = harness.new()
local metrics = require(here .. "/lib/metrics.luau")

local checks = 0
local failures = 0
local function ok(cond, label)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local function lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, line)
  end
  -- Drop the trailing empty element the concat above produces.
  if #out > 0 and out[#out] == "" then
    table.remove(out)
  end
  return out
end

local function find(text, name)
  for _, line in ipairs(lines(text)) do
    if line:sub(1, #name) == name and (line:sub(#name + 1, #name + 1) == " " or line:sub(#name + 1, #name + 1) == "{") then
      return line
    end
  end
  return nil
end

-- ── a full set of known values ───────────────────────────────────────────────
H.reset()
local text = metrics.render(1789397000, {
  lastSuccessAt = 1789396641,
  snapshotCount = 2,
  newestSnapshotAt = 1789396641,
  stale = false,
  repoBytes = 860367,
  repoFiles = 260,
  jobKind = "backup",
  jobExitCode = 0,
  lastCheckErrors = 0,
  verifyOk = true,
  verifyMatched = 3,
  verifyFailed = 0,
})

ok(find(text, "restic_snapshots_last_success_timestamp_seconds") ==
  "restic_snapshots_last_success_timestamp_seconds 1789396641",
  "last success is exposed in epoch seconds")
ok(find(text, "restic_snapshots_count") == "restic_snapshots_count 2", "snapshot count")
ok(find(text, "restic_snapshots_newest_age_seconds") == "restic_snapshots_newest_age_seconds 359",
  "newest age is computed from now")
ok(find(text, "restic_snapshots_stale") == "restic_snapshots_stale 0", "stale is a 0/1 gauge")
ok(find(text, "restic_snapshots_repo_bytes") == "restic_snapshots_repo_bytes 860367", "repo bytes")
ok(find(text, "restic_snapshots_repo_files") == "restic_snapshots_repo_files 260", "repo files")
ok(find(text, 'restic_snapshots_last_job_exit_code{kind="backup"}') ==
  'restic_snapshots_last_job_exit_code{kind="backup"} 0', "exit code carries the job kind")
ok(find(text, "restic_snapshots_last_check_errors") == "restic_snapshots_last_check_errors 0",
  "check errors")
ok(find(text, "restic_snapshots_last_verify_ok") == "restic_snapshots_last_verify_ok 1",
  "verify ok is a 0/1 gauge")
ok(find(text, "restic_snapshots_last_verify_matched") == "restic_snapshots_last_verify_matched 3",
  "verified matches")
ok(find(text, "restic_snapshots_export_timestamp_seconds") ==
  "restic_snapshots_export_timestamp_seconds 1789397000", "the file dates itself")

-- Format validity: every sample line has a value, every HELP has a TYPE.
local helpCount, typeCount = 0, 0
for _, line in ipairs(lines(text)) do
  if line:sub(1, 7) == "# HELP " then
    helpCount = helpCount + 1
  elseif line:sub(1, 7) == "# TYPE " then
    typeCount = typeCount + 1
  elseif line ~= "" then
    local tail = line:match("%s(%-?[%d%.eE+]+)$")
    ok(tail ~= nil, "sample has a numeric value: " .. line)
    ok(not line:find("nil", 1, true) and not line:find("NaN", 1, true), "no nil/NaN leaks: " .. line)
  end
end
ok(helpCount == typeCount, "every HELP has a matching TYPE")
ok(#lines(text) == helpCount + typeCount + (helpCount - 1), "one sample per HELP block")

-- ── unknown values are absent, not zero ─────────────────────────────────────
local bare = metrics.render(1789397000, {})
ok(bare:find("restic_snapshots_last_success_timestamp_seconds", 1, true) == nil,
  "an unknown last-success is omitted, not written as 0")
ok(bare:find("restic_snapshots_count", 1, true) == nil, "an unknown count is omitted")
ok(bare:find("restic_snapshots_stale", 1, true) == nil, "an unknown staleness is omitted")
ok(bare:find("restic_snapshots_last_verify_ok", 1, true) == nil, "an unknown verify result is omitted")
ok(bare:find("restic_snapshots_export_timestamp_seconds", 1, true) ~= nil,
  "the export timestamp is always present")
ok(metrics.render(1789397000, nil):find("restic_snapshots_export_timestamp_seconds", 1, true) ~= nil,
  "a nil values table still renders the export timestamp")

-- A real zero is a real zero, and must not be confused with "unknown".
local zero = metrics.render(1789397000, { snapshotCount = 0, jobExitCode = 0, jobKind = "check",
  verifyOk = false, lastCheckErrors = 7 })
ok(find(zero, "restic_snapshots_count") == "restic_snapshots_count 0", "a real zero count is exposed")
ok(find(zero, "restic_snapshots_last_verify_ok") == "restic_snapshots_last_verify_ok 0",
  "a failed verification is a real 0")
ok(find(zero, "restic_snapshots_last_check_errors") == "restic_snapshots_last_check_errors 7",
  "check errors pass through")

-- Hostile / odd inputs must not produce a corrupt file.
local nasty = metrics.render(1789397000, {
  jobKind = 'back\\up"now\nrm -rf',
  lastSuccessAt = 0,
  repoBytes = -1,
  snapshotCount = "12",
  stale = "yes",          -- a string where a boolean belongs is not a boolean
  verifyMatched = math.huge,
})
ok(find(nasty, 'restic_snapshots_last_job_exit_code{kind="back\\\\up\\"now\\nrm -rf"}') ~= nil,
  "label values are escaped, so no newline can break the line")
ok(find(nasty, "restic_snapshots_last_success_timestamp_seconds") ==
  "restic_snapshots_last_success_timestamp_seconds 0",
  "the unix epoch is a real value, not a missing one")
ok(find(nasty, "restic_snapshots_repo_bytes") == "restic_snapshots_repo_bytes -1",
  "a negative gauge is passed through rather than invented away")
ok(find(nasty, "restic_snapshots_count") == "restic_snapshots_count 12",
  "a numeric string is accepted")
ok(find(nasty, "restic_snapshots_stale") == nil, "a non-boolean staleness is omitted")
ok(find(nasty, "restic_snapshots_last_verify_matched") == nil, "an infinity is omitted, not printed")
for _, line in ipairs(lines(nasty)) do
  ok(line:sub(1, 1) == "#" or line:match("%s") ~= nil, "no malformed line: " .. line)
end

-- Clock skew must not produce a negative age.
local skewed = metrics.render(1789397000, { newestSnapshotAt = 1789397999 })
ok(find(skewed, "restic_snapshots_newest_age_seconds") ==
  "restic_snapshots_newest_age_seconds 0", "a future snapshot timestamp clamps the age to 0")

-- ── M.write is atomic and off by default ────────────────────────────────────
H.reset()
local written, reason = metrics.write("", "x")
ok(written == false and type(reason) == "string", "an unset directory is a soft refusal")
ok(#H.commands == 0, "the export spawns no process")

H.reset()
local okw, path = metrics.write("/home/tester/metrics", text)
ok(okw == true, "a configured directory is written")
ok(path == "/home/tester/metrics/restic_snapshots.prom", "the file name is fixed")
local madeDir = false
local wroteTmp = false
local moved = false
for _, call in ipairs(H.fsCalls or {}) do
  if call.name == "mkdirAll" and call.path == "/home/tester/metrics" then madeDir = true end
  if call.name == "writeFile" and call.path == "/home/tester/metrics/restic_snapshots.prom.tmp" then
    wroteTmp = true
    ok(call.text == text, "the temp file holds exactly the rendered text")
  end
  if call.name == "renameFile" and call.from == "/home/tester/metrics/restic_snapshots.prom.tmp"
     and call.to == "/home/tester/metrics/restic_snapshots.prom" then moved = true end
end
ok(madeDir, "the directory is created before writing")
ok(wroteTmp, "the text is written to the temp path first")
ok(moved, "the temp file is renamed onto the final path (atomic publish)")

-- A trailing slash in the setting must not double up.
H.reset()
local okSlash, slashPath = metrics.write("/home/tester/metrics/", text)
ok(okSlash == true and slashPath == "/home/tester/metrics/restic_snapshots.prom",
  "a trailing slash is tolerated")

-- Nothing to write is a refusal, not an empty file.
H.reset()
local okEmpty = metrics.write("/home/tester/metrics", "")
ok(okEmpty == false, "an empty render is not published")

-- A failing rename must not leave the temp file behind claiming to be current.
H.reset()
H.failCalls = { renameFile = true }
local okFail, failReason = metrics.write("/home/tester/metrics", text)
ok(okFail == false and type(failReason) == "string", "a failed publish is reported")
ok(H.files["/home/tester/metrics/restic_snapshots.prom.tmp"] == nil,
  "the temp file is cleaned up when the publish fails")
local cleaned = false
for _, call in ipairs(H.fsCalls) do
  if call.name == "removeFile" and call.path == "/home/tester/metrics/restic_snapshots.prom.tmp" then
    cleaned = true
  end
end
ok(cleaned, "the cleanup is an explicit removeFile")
ok(H.files["/home/tester/metrics/restic_snapshots.prom"] == nil,
  "a failed publish never leaves a file claiming to be current")

print(string.format("metrics_test: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
  os.exit(1)
end
print("ALL PASS -- 0 failure(s)")
