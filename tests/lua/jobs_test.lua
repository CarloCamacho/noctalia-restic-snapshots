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
local function addJobFile(name, mtime, contents, into)
  H.files[JOB_DIR .. "/" .. name] = contents or "x"
  H.mtimes[JOB_DIR .. "/" .. name] = mtime
  table.insert(into or listing, name)
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

-- ── sweep: liveness from the recorded pid ────────────────────────────────────
-- A job whose script died before writing `.exit` (power loss, a SIGKILLed script, a shell crash)
-- used to look like a running job forever and leak its files. Liveness is now decided from the pid
-- in the `.pid` file: `/proc/<pid>` exists exactly while that process does, so sweep spawns nothing
-- and needs no read access to the process.

local liveListing = {}

-- Killed before `.exit`: nothing serves /proc/900001.
for _, suffix in ipairs({ "jsonl", "status", "pid", "sh", "fifo" }) do
  addJobFile("dead1." .. suffix, oldSec, suffix == "pid" and "900001" or "x", liveListing)
end
-- Genuinely running: the stub below reports /proc/4242 as existing, so none of its files may go.
for _, suffix in ipairs({ "jsonl", "status", "pid", "sh", "fifo" }) do
  addJobFile("live2." .. suffix, oldSec, suffix == "pid" and "4242\n" or "x", liveListing)
end
-- An unknown suffix is still aged out on mtime alone, whatever the pids around it are doing.
addJobFile("unknownthing.weird", oldSec, "junk", liveListing)
-- A pid of 1 is not sane, so the old rule stands and the token counts as running.
addJobFile("pidone.jsonl", oldSec, "x", liveListing)
addJobFile("pidone.pid", oldSec, "1", liveListing)

-- poll() remembers the last log size per token; the sweep must drop that memo with the files, or a
-- later poll of the same token would be told "nothing changed" about a file that no longer exists.
local memoToken = "memotoken"
local memoPaths = pathsFor(memoToken)
addJobFile(memoToken .. ".jsonl", oldSec, "abc", liveListing)
addJobFile(memoToken .. ".pid", oldSec, "900002", liveListing)
jobs.poll(memoToken, memoPaths, nil)   -- remembers logSize = 3

_G.noctalia.listDir = function() return liveListing end

-- The harness stub answers true only for /tmp paths and a `/restic` suffix, so every liveness probe
-- would look dead. Answer true for the one pid this test calls alive, record what was probed, and
-- restore the harness stub afterwards so the tests that follow see the default again.
local liveProbes = {}
local originalFileExists = _G.noctalia.fileExists
_G.noctalia.fileExists = function(path)
  liveProbes[path] = true
  if path == "/proc/4242" then
    return true
  end
  return originalFileExists(path)
end

local spawnedBefore = #H.commands
local liveRemoved = jobs.sweep(3600 * 1000)
local spawnedBySweep = #H.commands - spawnedBefore
_G.noctalia.fileExists = originalFileExists

check("sweep removes exactly the dead tokens' files", liveRemoved == 8, tostring(liveRemoved))
check("a token whose pid is gone is swept despite the missing .exit file",
  H.files[JOB_DIR .. "/dead1.jsonl"] == nil and H.files[JOB_DIR .. "/dead1.fifo"] == nil)
check("a dead token's status, pid and script files go too",
  H.files[JOB_DIR .. "/dead1.status"] == nil and H.files[JOB_DIR .. "/dead1.pid"] == nil
    and H.files[JOB_DIR .. "/dead1.sh"] == nil)
check("a token whose pid is alive keeps every file",
  H.files[JOB_DIR .. "/live2.jsonl"] ~= nil and H.files[JOB_DIR .. "/live2.fifo"] ~= nil
    and H.files[JOB_DIR .. "/live2.status"] ~= nil and H.files[JOB_DIR .. "/live2.sh"] ~= nil
    and H.files[JOB_DIR .. "/live2.pid"] ~= nil)
check("an old file with an unknown suffix is still swept", H.files[JOB_DIR .. "/unknownthing.weird"] == nil)
check("a pid outside the sane range falls back to the old no-exit rule",
  H.files[JOB_DIR .. "/pidone.jsonl"] ~= nil and H.files[JOB_DIR .. "/pidone.pid"] ~= nil)
check("liveness is probed on /proc/<pid>",
  liveProbes["/proc/4242"] == true and liveProbes["/proc/900001"] == true)
check("sweep spawns no process to test liveness", spawnedBySweep == 0, tostring(spawnedBySweep))

-- The memo is only observable from outside through the same path coming back at the same size: with
-- the memo dropped, the size is unknown (lastSize is nil) and the tick counts as changed.
H.files[memoPaths.log] = "xyz"
local afterSweepPoll = jobs.poll(memoToken, memoPaths, nil)
check("sweeping a token forgets what poll remembered about it",
  afterSweepPoll.changed == true)

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

-- ── cancellation escalation: M.signal ────────────────────────────────────────
-- The service sends TERM first and escalates to KILL after a grace period. Both go through
-- M.signal, which is the single place that reads the pid and validates the signal name, so the two
-- attempts cannot disagree about which process they are signalling.

H.commands = {}
H.files[paths.pid] = "4242\n"
local killedOk, killedErr = jobs.signal(paths, "KILL")
check("signal accepts KILL for a recorded pid", killedOk == true, tostring(killedErr))
local killCommand = H.commands[#H.commands]
check("signal sends kill -KILL with the pid as one argument",
  killCommand ~= nil and #killCommand == 3 and killCommand[1] == "kill"
    and killCommand[2] == "-KILL" and killCommand[3] == "4242",
  killCommand and table.concat(killCommand, " "))

-- The allow-list is what keeps an unvalidated string out of kill's argv.
local sentBefore = #H.commands
local rejectedOk, rejectedErr = jobs.signal(paths, "STOP")
check("signal refuses a signal name outside the allow-list",
  rejectedOk == false and type(rejectedErr) == "string")
check("signal refuses an empty or missing signal name",
  jobs.signal(paths, "") == false and jobs.signal(paths) == false)
check("signal refuses a name that would smuggle another argv entry",
  jobs.signal(paths, "TERM -9") == false and jobs.signal(paths, "-9") == false)
check("a refused signal name never reaches kill", #H.commands == sentBefore)

H.files[paths.pid] = "1"
check("signal refuses pid 1", jobs.signal(paths, "KILL") == false)
H.files[paths.pid] = "not-a-pid"
check("signal refuses a non-numeric pid", jobs.signal(paths, "KILL") == false)
H.files[paths.pid] = ""
check("signal refuses an empty pid file", jobs.signal(paths, "KILL") == false)
H.files[paths.pid] = nil
check("signal refuses a missing pid file", jobs.signal(paths, "KILL") == false)
check("signal refuses paths that carry no pid path",
  jobs.signal({}, "KILL") == false and jobs.signal(nil, "KILL") == false)
check("a refused pid never reaches kill", #H.commands == sentBefore)

-- M.cancel keeps its old single-signal contract: TERM, and false when there is nothing to signal.
H.commands = {}
H.files[paths.pid] = " 4242 \n"
check("cancel still signals through M.signal", jobs.cancel(paths) == true)
local termCommand = H.commands[#H.commands]
check("cancel still uses kill -TERM with the pid as one argument",
  termCommand ~= nil and #termCommand == 3 and termCommand[1] == "kill"
    and termCommand[2] == "-TERM" and termCommand[3] == "4242",
  termCommand and table.concat(termCommand, " "))
H.files[paths.pid] = nil
check("cancel without a pid file is still false", jobs.cancel(paths) == false)
check("cancel without paths is still false", jobs.cancel(nil) == false and jobs.cancel("nope") == false)

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
