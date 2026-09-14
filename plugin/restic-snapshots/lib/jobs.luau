--!nonstrict
-- Detached job runner.
--
-- `noctalia.runAsync` clamps its timeout to 50–60000 ms, which a real backup would blow
-- through. A job therefore runs as a generated script launched *detached* (no callback, so no
-- timeout), writing:
--   <pluginDataDir>/jobs/<token>.jsonl    every non-status line of restic's output (the job log)
--   <pluginDataDir>/jobs/<token>.status   restic's newest --json status line, overwritten in place
--   <pluginDataDir>/jobs/<token>.pid      restic's own pid (0.2.0's cancellation target)
--   <pluginDataDir>/jobs/<token>.shpid    the job script's own pid (0.3.0: cancel signals this
--                                         one first - it is the only pid that exists while a
--                                         pre/post-backup hook runs)
--   <pluginDataDir>/jobs/<token>.exit     restic's exit code, written when it exits
-- The service polls `.exit`, parses the log for the final summary, and reads `.status` for
-- progress. 0.2.0 splits the two: status lines used to be re-parsed out of the log every tick.
--
-- [0.2.0] restic is backgrounded behind a FIFO instead of being piped into a filter. A pipeline
-- would put the *filter's* pid in `$!`, so cancel would signal the wrong process (review finding
-- "the recorded pid must belong to restic"). The generated script never contains credentials —
-- only paths.
--
-- [0.3.0] A job may carry two user-supplied shell commands: `opts.preCommand` (a staging step, say
-- a database dump into a directory the backup reads) and `opts.postCommand` (a follow-up that gets
-- restic's status in RESTIC_EXIT). Both run *inside* this same script, so they inherit its
-- timeout, its cancellation and its log, instead of being a side process the plugin cannot see.
-- A failing pre-command aborts the job before restic starts; a failing post-command never changes
-- the backup's recorded result. Both are passed as single-quoted assignments and invoked as
-- `/bin/sh -c "$PRECOMMAND"`, never inlined into a command line.

local restic = require("./restic.luau")

local M = {}

local LOG_TAIL_BYTES = 65536

-- Job files are <token>.<suffix>. sweep() only trusts these suffixes when it decides whether a
-- token's job is still running; anything else in the directory is treated as stray junk and
-- aged out as before.
local JOB_FILE_SUFFIXES = {
  jsonl = true,
  status = true,
  exit = true,
  pid = true,
  shpid = true,
  sh = true,
  fifo = true,
}

-- [0.3.0] What a job script does when it is signalled: kill the child running right now - restic,
-- or the hook during the pre/post phase - drop the fifo, record 143 and leave. Before this a TERM
-- only ever reached restic, so a job whose pre-command was running had no pid to signal at all,
-- and a watchdog strike released the single-flight guard while the script - and its hook - stayed
-- alive and went on to start restic unwatched.
--
-- `.exit` is written here (only when the job has not finished on its own) so the service's next
-- poll sees the cancellation and finishes the job with the code the signal produced, instead of
-- holding the guard until its own escalation runs out. Every branch tolerates an unset variable:
-- the trap is installed before the paths are assigned, so a signal in that window must not run
-- `rm -f ""` or `> ""`.
local TRAP_ACTION = "if [ -n \"$child\" ]; then kill -TERM \"$child\" 2>/dev/null; fi; "
  .. "if [ -n \"$fifo\" ]; then rm -f \"$fifo\"; fi; "
  .. "if [ -n \"$exitfile\" ] && [ ! -e \"$exitfile\" ]; then echo 143 > \"$exitfile\"; fi; "
  .. "exit 143"

-- What the last poll handed out per token. The service only passes the *log* size back and the
-- status file is overwritten in place, so "did the status file change?" is not answerable from
-- the arguments alone — remembering the last seen status text keeps `changed` honest.
local progressSeen = {}

function M.dataDir(sub)
  local base = noctalia.pluginDataDir()
  if type(base) ~= "string" or base == "" then
    return nil, "plugin data directory unavailable"
  end
  local dir = sub and (base .. "/" .. sub) or base
  if not noctalia.fileExists(dir) then
    local ok, err = noctalia.mkdirAll(dir)
    if not ok then
      return nil, err or ("cannot create " .. dir)
    end
  end
  return dir
end

-- [0.3.0] A token must be unique within the process, not merely likely to be: seeding math.random
-- from the clock in milliseconds means two jobs started in the same millisecond draw the same seed
-- and therefore the same number, and both jobs would then share one log, one exit file and one
-- generated script (the verify workstream hit exactly that in its tests, where time is frozen).
-- The counter is monotonic and cannot repeat, so the seed only has to make a token unguessable.
local tokenCounter = 0

function M.newToken()
  tokenCounter = tokenCounter + 1
  math.randomseed(noctalia.nowMs() % 2147483647)
  return string.format("%x%x%x", noctalia.nowMs(), math.random(0, 0xFFFFFF), tokenCounter)
end

-- Decode one restic status line. restic.luau owns the status JSON shape; the plain decode is a
-- fallback so this module still works on its own.
local function decodeStatusLine(text)
  if type(text) ~= "string" then
    return nil
  end
  local line = text:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then
    return nil
  end
  if type(restic.lastStatusLine) == "function" then
    local ok, decoded = pcall(restic.lastStatusLine, text)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  local ok, decoded = pcall(noctalia.json.decode, line)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

-- Start a detached restic job. Returns the token, or nil + error.
function M.start(argv, opts)
  opts = opts or {}
  local dir, derr = M.dataDir("jobs")
  if dir == nil then
    return nil, derr
  end

  local token = M.newToken()
  local logPath = dir .. "/" .. token .. ".jsonl"
  local statusPath = dir .. "/" .. token .. ".status"
  local exitPath = dir .. "/" .. token .. ".exit"
  local pidPath = dir .. "/" .. token .. ".pid"
  local shpidPath = dir .. "/" .. token .. ".shpid"
  local scriptPath = dir .. "/" .. token .. ".sh"
  local fifoPath = dir .. "/" .. token .. ".fifo"

  -- `case` pattern matching one restic --json status line; the double quotes are literal, so the
  -- whole pattern is single-quoted for the shell.
  local statusPattern = "*'\"message_type\":\"status\"'*"

  -- [0.3.0] Pre/post-backup hooks are *user-supplied shell strings*, the one thing here that is
  -- neither an argv vector nor a path. They never reach a command line: each is written into the
  -- script as a single-quoted assignment and invoked as `/bin/sh -c "$PRECOMMAND"`, which is the
  -- only form whose content cannot escape into the surrounding script. An empty or missing option
  -- means "no hook", so a caller that passes `preCommand = ""` (the settings default) generates
  -- exactly the 0.2.0 script.
  local preCommand = nil
  if type(opts.preCommand) == "string" and opts.preCommand ~= "" then
    preCommand = opts.preCommand
  end
  local postCommand = nil
  if type(opts.postCommand) == "string" and opts.postCommand ~= "" then
    postCommand = opts.postCommand
  end

  local lines = {
    "#!/bin/sh",
    "# generated by carlocamacho/restic-snapshots - safe to delete",
    "# Secret-free by construction: only paths and restic's own output travel through this file.",
    '# Fold the script private before it does anything, then let the umask make the fifo and every',
    '# log file it creates 0600 as well.',
    'chmod 600 "$0" 2>/dev/null || true',
    "umask 077",
    -- [0.3.0] The script's own pid, written before anything else runs, so cancellation reaches the
    -- whole job and not just restic: a pre-command phase has no restic pid at all (cancel used to
    -- do nothing there), and a job the watchdog struck down must not keep the script - and its
    -- hook - alive to start restic unwatched afterwards.
    "shpidfile=" .. restic.shellQuote(shpidPath),
    'printf \'%s\' "$$" > "$shpidfile"',
    -- `child` is the one variable the trap can see in every phase; it holds restic's pid once
    -- restic is up and the running hook's pid while a hook runs.
    "child=",
    "trap " .. restic.shellQuote(TRAP_ACTION) .. " TERM INT HUP",
  }
  if opts.pathPrefix and opts.pathPrefix ~= "" then
    local parts = { opts.pathPrefix, "/usr/local/bin", "/usr/bin", "/bin" }
    table.insert(lines, "PATH=" .. restic.shellQuote(table.concat(parts, ":")))
    table.insert(lines, "export PATH")
  end
  -- Cloud/remote credentials live in the user's env file. `set -a` exports what it defines so
  -- restic, a child process, inherits them. Only the path is written here - never a secret.
  if type(opts.envFile) == "string" and opts.envFile ~= "" then
    table.insert(lines, "set -a; . " .. restic.shellQuote(opts.envFile) .. "; set +a")
  end
  table.insert(lines, "fifo=" .. restic.shellQuote(fifoPath))
  table.insert(lines, "logfile=" .. restic.shellQuote(logPath))
  table.insert(lines, "statusfile=" .. restic.shellQuote(statusPath))
  table.insert(lines, "pidfile=" .. restic.shellQuote(pidPath))
  table.insert(lines, "exitfile=" .. restic.shellQuote(exitPath))
  -- The hook bodies travel as quoted data, never as script text: restic.shellQuote turns every
  -- value - quotes, `$(...)`, backticks and newlines included - into one inert single-quoted word.
  if preCommand ~= nil then
    table.insert(lines, "PRECOMMAND=" .. restic.shellQuote(preCommand))
  end
  if postCommand ~= nil then
    table.insert(lines, "POSTCOMMAND=" .. restic.shellQuote(postCommand))
  end
  table.insert(lines, 'rm -f "$fifo"')
  -- Without the fifo the reader below would see nothing, so fail loudly with a log line and an
  -- exit code instead of leaving a job that looks alive but never finishes.
  table.insert(lines, 'if ! mkfifo "$fifo"; then')
  table.insert(lines, "  printf '%s\\n' 'the job script could not create its fifo' >> \"$logfile\"")
  table.insert(lines, '  printf \'%s\' 1 > "$exitfile"')
  table.insert(lines, "  exit 1")
  table.insert(lines, "fi")
  -- [0.3.0] Pre-backup hook: a staging step (a database dump into a directory the backup then
  -- reads, say) that must run *inside* the job. Its stdout and stderr are appended to the job log
  -- behind a marker line so the Log tab shows them, and a non-zero status aborts the job before
  -- restic is ever started - the fifo is removed again, the abort status becomes the job's result
  -- and the script exits with it. Without a hook not one of these lines is emitted.
  --
  -- Backgrounded and then waited for, rather than run in the foreground: while a foreground child
  -- runs, `sh` defers a signal trap until that child finishes, so a TERM could not reach a hook at
  -- all. `wait` restores the old ordering and the old exit code, while `child=$!` is what makes
  -- the hook reachable by the trap.
  if preCommand ~= nil then
    table.insert(lines, "printf '%s\\n' '== pre-backup command ==' >> \"$logfile\"")
    table.insert(lines, '/bin/sh -c "$PRECOMMAND" >> "$logfile" 2>&1 &')
    table.insert(lines, "child=$!")
    table.insert(lines, 'wait "$child"')
    table.insert(lines, "prestatus=$?")
    table.insert(lines, 'if [ "$prestatus" -ne 0 ]; then')
    table.insert(lines, "  printf '%s\\n' 'the pre-backup command failed; restic was not started' >> \"$logfile\"")
    table.insert(lines, '  rm -f "$fifo"')
    table.insert(lines, '  printf \'%s\' "$prestatus" > "$exitfile"')
    table.insert(lines, '  exit "$prestatus"')
    table.insert(lines, "fi")
  end
  -- Backgrounded directly (no pipeline), so $! is restic's own pid and cancel signals it.
  table.insert(lines, restic.shellArgv(argv) .. ' > "$fifo" 2>&1 &')
  table.insert(lines, "child=$!")
  table.insert(lines, "printf '%s' \"$child\" > \"$pidfile\"")
  table.insert(lines, "while IFS= read -r line; do")
  table.insert(lines, "  case \"$line\" in")
  table.insert(lines, "    " .. statusPattern .. ") printf '%s\\n' \"$line\" > \"$statusfile\" ;;")
  table.insert(lines, "    *) printf '%s\\n' \"$line\" >> \"$logfile\" ;;")
  table.insert(lines, "  esac")
  table.insert(lines, 'done < "$fifo"')
  table.insert(lines, 'wait "$child"')
  if postCommand == nil then
    table.insert(lines, "printf '%s' \"$?\" > \"$exitfile\"")
  else
    -- [0.3.0] Post-backup hook. It runs whatever restic's status was, and it runs *before* the
    -- `.exit` file is written, so a job only counts as finished once the follow-up is done too -
    -- it stays inside the job's lifetime and its output stays in the job's log. `resticexit`
    -- captures restic's status before the hook starts: the hook sees it as RESTIC_EXIT, and the
    -- code finally recorded in `.exit` is restic's again, never the hook's own.
    --
    -- Backgrounded and waited for like the pre-command, so a TERM that arrives while the hook
    -- runs reaches it: a hung post-command used to be unkillable, and the job would only look
    -- finished after the watchdog's kill while the hook kept running.
    table.insert(lines, "resticexit=$?")
    table.insert(lines, "printf '%s\\n' '== post-backup command ==' >> \"$logfile\"")
    table.insert(lines, 'RESTIC_EXIT="$resticexit" /bin/sh -c "$POSTCOMMAND" >> "$logfile" 2>&1 &')
    table.insert(lines, "child=$!")
    table.insert(lines, 'wait "$child"')
    table.insert(lines, 'printf \'%s\' "$resticexit" > "$exitfile"')
  end
  table.insert(lines, 'rm -f "$fifo"')

  local ok, werr = noctalia.writeFile(scriptPath, table.concat(lines, "\n") .. "\n")
  if not ok then
    return nil, werr or "cannot write job script"
  end

  -- No callback: detached, so no timeout applies.
  local accepted = noctalia.runAsync({ "/bin/sh", scriptPath })
  if not accepted then
    return nil, "could not start the job"
  end

  return token, nil, {
    log = logPath,
    status = statusPath,
    exit = exitPath,
    pid = pidPath,
    shpid = shpidPath,
    script = scriptPath,
    fifo = fifoPath,
  }
end

-- The signals M.signal will send. An allow-list rather than a pass-through: the name is built into
-- kill's argv, so anything else - a flag, a second pid, a shell metacharacter - must be unreachable.
-- The service escalates deliberately: TERM first, then KILL after a grace period.
local ALLOWED_SIGNALS = {
  TERM = true,
  KILL = true,
}

-- Read a job's recorded pid. Returns a number greater than 1, or nil when the file is missing,
-- unreadable, empty or does not hold a plain process id. Digits only, so that what the file holds
-- reaches kill - and, in sweep, /proc - as a number and never as anything else.
local function readPid(pidPath)
  if type(pidPath) ~= "string" or pidPath == "" then
    return nil
  end
  local text = noctalia.readFile(pidPath)
  if type(text) ~= "string" then
    return nil
  end
  local digits = text:match("^%s*(%d+)%s*$")
  if digits == nil then
    return nil
  end
  local pid = tonumber(digits)
  if pid == nil or pid <= 1 then
    return nil
  end
  return pid
end

-- Signal a running job. Returns true when the signal was accepted, plus an error string otherwise.
--
-- [0.3.0] The *script's* pid (`.shpid`) is preferred over restic's own (`.pid`): a job is more than
-- its restic process - the pre-command phase has no restic pid at all, and the script's trap is
-- what kills whichever child is running and cleans the fifo up. `.pid` stays the fallback for a
-- job whose script has not written `.shpid` yet, and for the tests and tools that only know 0.2.0
-- paths. This is the single place that reads and validates a pid, so an escalation (TERM, then
-- KILL) cannot drift from the first attempt. Kill's argv is built here and nowhere else, and only
-- `ALLOWED_SIGNALS` members can reach it.
function M.signal(paths, signalName)
  if type(paths) ~= "table" then
    return false, "no job to signal"
  end
  if ALLOWED_SIGNALS[signalName] ~= true then
    return false, "unsupported signal"
  end
  local pid = readPid(paths.shpid) or readPid(paths.pid)
  if pid == nil then
    return false, "no usable pid"
  end
  if noctalia.runAsync({ "kill", "-" .. signalName, tostring(pid) }) ~= true then
    return false, "could not signal the job"
  end
  return true, nil
end

-- Terminate a running job (0.3.0: its script, falling back to restic - see M.signal). Returns true
-- when a signal was sent.
function M.cancel(paths)
  local ok = M.signal(paths, "TERM")
  return ok == true
end

-- Poll a job. Returns { done, exitCode, text, statusLine, changed, size }.
function M.poll(token, paths, lastSize)
  local dir = M.dataDir("jobs")
  if dir == nil then
    return { done = false, exitCode = nil, text = "", statusLine = nil, changed = false, size = 0 }
  end
  paths = paths or {
    log = dir .. "/" .. token .. ".jsonl",
    status = dir .. "/" .. token .. ".status",
    exit = dir .. "/" .. token .. ".exit",
    pid = dir .. "/" .. token .. ".pid",
  }

  local result = { done = false, exitCode = nil, text = "", statusLine = nil, changed = false, size = 0 }

  local exitText = noctalia.readFile(paths.exit)
  if type(exitText) == "string" and exitText ~= "" then
    result.done = true
    result.exitCode = tonumber((exitText:gsub("%s+$", ""))) or 1
  end

  local info = noctalia.fileInfo(paths.log)
  local size = info ~= nil and tonumber(info.size) or 0
  result.size = size

  local statusText = nil
  if type(paths.status) == "string" then
    local raw = noctalia.readFile(paths.status)
    if type(raw) == "string" and raw ~= "" then
      statusText = raw
    end
  end
  result.statusLine = decodeStatusLine(statusText)

  local previous = progressSeen[token]
  local seenSize = lastSize
  if seenSize == nil and previous ~= nil then
    seenSize = previous.logSize
  end
  local logChanged = seenSize == nil or size ~= seenSize
  local statusChanged = statusText ~= nil
    and (previous == nil or previous.statusText ~= statusText)
  result.changed = logChanged or statusChanged
  progressSeen[token] = { logSize = size, statusText = statusText }

  -- Review finding #1: when `.exit` appears between two ticks the log may not have grown since
  -- the previous call (the summary was its last line). Returning early here would hand the
  -- service an empty text, and the summary - file/byte counts, the forget-dry preview - would be
  -- lost. A finished job therefore always reports its text.
  if lastSize ~= nil and size == lastSize and not result.done then
    return result
  end

  local text = noctalia.readFile(paths.log)
  if type(text) == "string" then
    if #text > LOG_TAIL_BYTES then
      text = text:sub(-LOG_TAIL_BYTES)
    end
    result.text = text
  end
  return result
end

-- Keep at most maxLines trailing lines (the tail of `text`, newline inclusive).
--
-- One forward pass over the newlines, keeping the start offset of each of the last `maxLines`
-- lines in a ring buffer, so the cost scales with the number of LINES and never with the byte
-- count. The previous version walked the string backwards one character at a time and called
-- sub() per character; on a multi-KB log that blew the HOST's per-callback CPU budget, and
-- because a job log is published from the service's update() tick the whole tick died with
-- "script callback 'update' exceeded its CPU budget" (seen live: an `ls --json` job log, ~97 KB).
-- Plain-Lua tests have no such budget, so this loop must stay linear in lines.
local function tailLines(text, maxLines)
  local limit = tonumber(maxLines)
  if limit == nil or limit <= 0 then
    return text
  end
  local starts = {}
  local count = 0
  local from = 1
  local size = #text
  while from <= size do
    local newline = text:find("\n", from, true)
    count = count + 1
    starts[((count - 1) % limit) + 1] = from
    if newline == nil then
      break
    end
    from = newline + 1
  end
  if count <= limit then
    return text
  end
  return text:sub(starts[((count - limit) % limit) + 1])
end

-- Bounded tail of a job log for the panel's viewer: never the whole file, and never more than
-- maxLines lines. The host reads whole files only, so the bound is applied to what we return.
function M.readLog(path, maxBytes, maxLines)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  local text = noctalia.readFile(path)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  local bytes = tonumber(maxBytes) or LOG_TAIL_BYTES
  if bytes > 0 and #text > bytes then
    text = text:sub(-bytes)
    -- Drop the partial first line: half a line is not a line the viewer can show. Unless the
    -- bound landed inside a line with no newline after it at all (a log of one enormous line) --
    -- then dropping it would show nothing, which is worse than a bounded partial line.
    local newline = text:find("\n", 1, true)
    if newline ~= nil then
      text = text:sub(newline + 1)
    end
  end
  return tailLines(text, tonumber(maxLines))
end

-- Is the process recorded in `pidPath` still running? The host answers this without spawning
-- anything and without needing read access to the process: `/proc/<pid>` exists exactly while that
-- process does, and `fileExists` reads an absolute path verbatim. Returns nil when there is no
-- usable pid to test, so the caller can keep the old "no `.exit` means running" rule.
local function pidAlive(pidPath)
  local pid = readPid(pidPath)
  if pid == nil then
    return nil
  end
  return noctalia.fileExists("/proc/" .. tostring(pid)) == true
end

-- Delete *finished* job files older than maxAgeMs. A token counts as running only when it has no
-- `.exit` file *and* the pid it recorded is still alive; only then are its files - including the
-- fifo and the status file - protected from removal. A script killed before it could write `.exit`
-- (power loss, a SIGKILLed script, a shell crash) leaves a dead pid behind, so its files age out
-- like a finished job's instead of leaking forever. Without a readable, sane pid the old rule
-- stands: no `.exit` means running, which is the only safe reading when the job may simply not have
-- written its pid yet.
function M.sweep(maxAgeMs)
  local dir = M.dataDir("jobs")
  if dir == nil then
    return 0
  end
  local listing = noctalia.listDir(dir)
  if type(listing) ~= "table" then
    return 0
  end
  local present = {}
  for _, name in ipairs(listing) do
    if type(name) == "string" then
      present[name] = true
    end
  end
  local now = noctalia.nowMs()
  local limit = maxAgeMs or 24 * 3600 * 1000
  local removed = 0

  -- Liveness is decided once per token and before anything is removed. Testing it per file would be
  -- order-dependent: once the `.pid` file itself has been swept, its siblings would look pid-less
  -- and be kept forever by the fallback.
  local runningTokens = {}
  local function tokenRunning(token)
    local cached = runningTokens[token]
    if cached == nil then
      if present[token .. ".exit"] == true then
        -- The job wrote its exit code: nothing about it needs protecting any more.
        cached = false
      else
        -- nil (no readable, sane pid) keeps the pre-0.2.0 rule: assume it is still running.
        cached = pidAlive(dir .. "/" .. token .. ".pid") ~= false
      end
      runningTokens[token] = cached
    end
    return cached
  end

  for _, name in ipairs(listing) do
    if type(name) == "string" then
      local path = dir .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info ~= nil and not info.isDir then
        local token, suffix = name:match("^(.*)%.([^%.]+)$")
        -- An unknown suffix is never a job file: age alone decides, with no liveness test at all.
        local running = token ~= nil and JOB_FILE_SUFFIXES[suffix] == true and tokenRunning(token)
        if not running then
          local mtime = tonumber(info.mtime) or 0
          local age = mtime > 1e12 and (now - mtime) or (now - mtime * 1000)
          if age > limit then
            noctalia.removeFile(path)
            if token ~= nil then
              -- The files are gone, so forget what poll() remembered about this job.
              progressSeen[token] = nil
            end
            removed = removed + 1
          end
        end
      end
    end
  end
  return removed
end

return M
