--!nonstrict
-- Real assertions for the detached job runner (lib/jobs.luau).
-- Run from the repo root:  lua5.4 tests/lua/jobs_test.lua

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")
H.install("plugin/restic-snapshots")
local jobs = H.load("lib/jobs.luau")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

local JOB_DIR = "/tmp/restic-data/jobs"

-- Single-quote the way lib/restic.luau does, so a hostile value can be looked for verbatim.
local function q(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function pathsFor(token)
  return {
    log = JOB_DIR .. "/" .. token .. ".jsonl",
    status = JOB_DIR .. "/" .. token .. ".status",
    exit = JOB_DIR .. "/" .. token .. ".exit",
    pid = JOB_DIR .. "/" .. token .. ".pid",
    script = JOB_DIR .. "/" .. token .. ".sh",
    fifo = JOB_DIR .. "/" .. token .. ".fifo",
  }
end

local function lineContaining(text, needle)
  for line in text:gmatch("[^\n]+") do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

local function countLines(text)
  if text == "" then
    return 0
  end
  local _, newlines = text:gsub("\n", "\n")
  if text:sub(-1) ~= "\n" then
    newlines = newlines + 1
  end
  return newlines
end

-- ── script generation ────────────────────────────────────────────────────────

local hostile = "/tmp/it's a $(dangerous) path"
local argv = { "/x/restic", "--password-file", "/tmp/p", "-r", "/tmp/r", "backup", hostile, "--json" }
local token, err, paths = jobs.start(argv, { pathPrefix = "/home/tester/.local/bin" })

check("start returns a token", token ~= nil, tostring(err))
check("start launched the script detached", #H.commands == 1 and H.commands[1][1] == "/bin/sh")
local script = H.files[paths.script] or ""
check("script sets PATH", script:find("PATH=", 1, true) ~= nil)
check("script quotes the hostile path", script:find("'%s*'", 1, false) ~= nil or script:find(hostile, 1, true) ~= nil)
check("script backgrounds and records the pid", script:find("child=$!", 1, true) ~= nil and script:find(".pid", 1, true) ~= nil)
check("script waits and records the exit code", script:find('wait "$child"', 1, true) ~= nil and script:find(".exit", 1, true) ~= nil)
check("hostile path is single-quoted in the script", script:find(q(hostile), 1, true) ~= nil, q(hostile))
check("hostile path is not bare", script:find(hostile, 1, true) == nil or script:find(q(hostile), 1, true) ~= nil)

-- 0.2.0: the job files must be private, and the fifo must exist before restic is backgrounded.
check("script locks itself down", script:find("chmod 600 \"$0\"", 1, true) ~= nil)
check("script restricts the umask before creating anything", script:find("umask 077", 1, true) ~= nil)
check("paths carry the fifo", type(paths.fifo) == "string" and paths.fifo:find("%.fifo$") ~= nil, tostring(paths.fifo))
check("script creates the fifo", script:find('mkfifo "$fifo"', 1, true) ~= nil)
check("script reads the fifo to the end", script:find('done < "$fifo"', 1, true) ~= nil)
check("script removes the fifo afterwards", script:find('rm -f "$fifo"', 1, true) ~= nil)
check("mkfifo runs before restic starts",
  (script:find("mkfifo", 1, true) or 0) < (script:find("/x/restic", 1, true) or 0))

-- The pid must be restic's own: no pipeline member may sit between the shell and restic.
local runLine = lineContaining(script, "/x/restic")
check("restic is backgrounded straight into the fifo, with no pipeline",
  runLine ~= nil and runLine:find('> "$fifo" 2>&1 &', 1, true) ~= nil and runLine:find("|", 1, true) == nil,
  tostring(runLine))
check("the pid file is written from $!",
  script:find('printf \'%s\' "$child" > "$pidfile"', 1, true) ~= nil)

-- The status/log split: status lines are overwritten into .status, everything else appended.
local statusCase = lineContaining(script, "message_type")
check("script recognises restic status lines", statusCase ~= nil, tostring(statusCase))
check("status lines are written to the status file", statusCase ~= nil and statusCase:find("$statusfile", 1, true) ~= nil)
-- The pattern must be a well-formed `case` arm (`)` closes the pattern); a missing `)` is a shell
-- syntax error that only a real shell catches.
check("the status case arm closes its pattern",
  script:find("*'\"message_type\":\"status\"'*) printf", 1, true) ~= nil, tostring(statusCase))
local logCase = lineContaining(script, '"$line" >> "$logfile"')
check("everything else is appended to the log", logCase ~= nil, tostring(logCase))
check("no env file means no sourcing line", script:find("set -a", 1, true) == nil)

-- ── script generation: env file ──────────────────────────────────────────────

local hostileEnv = "/tmp/it's an env $(file)"
local envToken, envErr, envPaths = jobs.start(argv, { pathPrefix = "/bin", envFile = hostileEnv })
check("start with an env file returns a token", envToken ~= nil, tostring(envErr))
local envScript = H.files[envPaths.script] or ""
check("env file is sourced single-quoted and exported",
  envScript:find("set -a; . " .. q(hostileEnv) .. "; set +a", 1, true) ~= nil, envScript)
check("env file is sourced before restic runs",
  (envScript:find("set +a", 1, true) or 0) < (envScript:find("/x/restic", 1, true) or 0))

-- ── polling ──────────────────────────────────────────────────────────────────

local polled = jobs.poll(token, paths, nil)
check("unfinished job reports not done", polled.done == false)

-- A trailing newline in the exit file must not be read as a numeric base.
H.files[paths.exit] = "0\n"
H.files[paths.log] = '{"message_type":"summary","total_files_processed":2}\n'
polled = jobs.poll(token, paths, nil)
check("finished job reports done", polled.done == true)
check("exit code parsed from a newline-terminated file", polled.exitCode == 0, tostring(polled.exitCode))
check("job text is returned", tostring(polled.text):find("summary") ~= nil, tostring(polled.text))

H.files[paths.exit] = "1\n"
polled = jobs.poll(token, paths, nil)
check("non-zero exit parsed", polled.exitCode == 1, tostring(polled.exitCode))

-- ── polling: status line ─────────────────────────────────────────────────────

local statusToken = "statustoken"
local statusPaths = pathsFor(statusToken)
local statusText = '{"message_type":"status","percent_done":0.42,"files_done":3,"total_files":10}'
H.jsonMap[statusText] = { message_type = "status", percent_done = 0.42, files_done = 3, total_files = 10 }
H.files[statusPaths.log] = "first\n"
H.files[statusPaths.status] = statusText .. "\n"

local first = jobs.poll(statusToken, statusPaths, nil)
check("poll reports the first log size", first.size == #"first\n", tostring(first.size))
check("poll decodes the newest status line",
  type(first.statusLine) == "table" and first.statusLine.percent_done == 0.42,
  tostring(first.statusLine and first.statusLine.percent_done))
check("poll reports a change while the job is running", first.changed == true)

-- The log has not grown, but a fresh status line landed: that is a change too.
local newerStatus = '{"message_type":"status","percent_done":0.9,"files_done":9,"total_files":10}'
H.jsonMap[newerStatus] = { message_type = "status", percent_done = 0.9, files_done = 9, total_files = 10 }
H.files[statusPaths.status] = newerStatus .. "\n"
local second = jobs.poll(statusToken, statusPaths, #"first\n")
check("a status-only update counts as changed", second.changed == true)
check("status-only update returns the newest status line",
  type(second.statusLine) == "table" and second.statusLine.percent_done == 0.9,
  tostring(second.statusLine and second.statusLine.percent_done))
check("status-only update does not re-read the unchanged log", second.text == "")

-- Nothing moved at all: no change, and the status line is still available.
local third = jobs.poll(statusToken, statusPaths, #"first\n")
check("a quiet tick reports no change", third.changed == false)
check("a quiet tick still returns the status line", type(third.statusLine) == "table")
check("a quiet tick keeps the keys the service reads",
  third.done == false and type(third.text) == "string" and type(third.size) == "number")

-- ── polling: log size unchanged and the exit file appeared in between ────────
-- Review finding #1: returning early on an unchanged size used to drop the final summary, so
-- the retention preview said "Would keep 0, remove 0" and backups lost their file/byte counts.

local raceToken = "racetoken"
local racePaths = pathsFor(raceToken)
local summaryLine = '{"message_type":"summary","total_files_processed":1234,"total_bytes_processed":999}'
H.jsonMap[summaryLine] = { message_type = "summary", total_files_processed = 1234, total_bytes_processed = 999 }
local raceLog = summaryLine .. "\n"
H.files[racePaths.log] = raceLog

local beforeExit = jobs.poll(raceToken, racePaths, nil)
check("running job returns its summary text", beforeExit.text == raceLog, tostring(beforeExit.text))
check("running job is not done", beforeExit.done == false)

-- The shell finished and wrote .exit; the log did not grow in between (the summary was last).
H.files[racePaths.exit] = "0\n"
local afterExit = jobs.poll(raceToken, racePaths, #raceLog)
check("done is reported when the exit file appears", afterExit.done == true)
check("done with an unchanged log size still returns the text", afterExit.text ~= "", "text empty")
check("done with an unchanged log size still returns the summary",
  tostring(afterExit.text):find("summary", 1, true) ~= nil, tostring(afterExit.text))
check("the summary survives the race", afterExit.text == raceLog, tostring(afterExit.text))

-- ── readLog ──────────────────────────────────────────────────────────────────

local viewerPath = JOB_DIR .. "/viewer.jsonl"
local viewerLines = {}
for index = 1, 400 do
  table.insert(viewerLines, string.format('{"line":%d}', index))
end
local viewerLog = table.concat(viewerLines, "\n") .. "\n"
H.files[viewerPath] = viewerLog

local tail = jobs.readLog(viewerPath, 512, 5)
check("readLog never returns the whole file", #tail < #viewerLog, tostring(#tail) .. " of " .. tostring(#viewerLog))
check("readLog honours maxBytes", #tail <= 512, tostring(#tail))
check("readLog honours maxLines", countLines(tail) <= 5, tostring(countLines(tail)))
check("readLog returns a suffix of the file", viewerLog:sub(-#tail) == tail)

local byLines = jobs.readLog(viewerPath, nil, 3)
check("readLog bounds lines on its own", countLines(byLines) <= 3, tostring(countLines(byLines)))
check("readLog keeps complete lines", byLines:sub(1, 1) == "{" and byLines:sub(-1) == "\n", byLines:sub(1, 12))

check("readLog of a missing file is empty", jobs.readLog(JOB_DIR .. "/nope.jsonl", 128, 4) == "")
check("readLog of nil is empty", jobs.readLog(nil, 128, 4) == "")

-- ── sweep ────────────────────────────────────────────────────────────────────

H.nowMs = 1788874602000
local nowSec = 1788874602
local oldSec = nowSec - 7200

local listing = {}
local function addJobFile(name, mtime, contents)
  H.files[JOB_DIR .. "/" .. name] = contents or "x"
  H.mtimes[JOB_DIR .. "/" .. name] = mtime
  table.insert(listing, name)
end

-- A finished job: `.exit` exists, so every one of its files may age out.
for _, suffix in ipairs({ "exit", "jsonl", "status", "pid", "sh", "fifo" }) do
  addJobFile("done1." .. suffix, oldSec, suffix == "exit" and "0" or "x")
end
-- A running job: no `.exit` yet, so nothing of its may be removed.
addJobFile("live1.jsonl", oldSec, "x")
addJobFile("live1.fifo", oldSec, "")
-- A finished job that is still fresh.
addJobFile("done2.jsonl", nowSec, "x")
addJobFile("done2.exit", nowSec, "0")
-- Stray junk that is not a job file at all keeps the old age-only treatment.
addJobFile("stray.bak", oldSec, "junk")

_G.noctalia.listDir = function() return listing end
local removed = jobs.sweep(3600 * 1000)

check("sweep removes every file of a finished job", removed == 7, tostring(removed))
check("sweep removes the fifo", H.files[JOB_DIR .. "/done1.fifo"] == nil)
check("sweep removes the status file", H.files[JOB_DIR .. "/done1.status"] == nil)
check("sweep keeps a running job's log and fifo",
  H.files[JOB_DIR .. "/live1.jsonl"] ~= nil and H.files[JOB_DIR .. "/live1.fifo"] ~= nil)
check("sweep keeps fresh job files", H.files[JOB_DIR .. "/done2.jsonl"] ~= nil)
check("sweep ages out stray files as before", H.files[JOB_DIR .. "/stray.bak"] == nil)
check("sweep is idempotent", jobs.sweep(3600 * 1000) == 0)

-- ── cancellation ─────────────────────────────────────────────────────────────

H.commands = {}
H.files[paths.pid] = "4242\n"
check("cancel signals the recorded pid", jobs.cancel(paths) == true)
local killCmd = H.commands[#H.commands]
check("cancel uses kill -TERM with the pid as one argument",
  killCmd ~= nil and killCmd[1] == "kill" and killCmd[2] == "-TERM" and killCmd[3] == "4242",
  killCmd and table.concat(killCmd, " "))

H.files[paths.pid] = ""
check("cancel without a pid does nothing", jobs.cancel(paths) == false)

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
