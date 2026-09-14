--!nonstrict
-- 0.3.0 pre/post-backup hooks of the detached job runner (lib/jobs.luau).
-- Run from the repo root:  lua5.4 tests/lua/jobs_hooks_test.lua
--
-- jobs_test.lua owns the runner itself; this file owns the hook contract only: how a user-supplied
-- shell command is written into the generated script, how it is invoked, what a failure does, and
-- that a job without hooks is generated exactly as 0.2.0 generated it. Nothing here *runs* a hook -
-- tests/test_jobs_script.py runs the generated script through a real /bin/sh with a fake restic,
-- which is the only way to exercise ordering and exit codes.

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

local RESTIC = "/x/restic"
local ENV_FILE = [=[/tmp/it's an env $(file)]=]
local ARGV = {
  RESTIC, "--password-file", "/tmp/p", "-r", "/tmp/r", "backup",
  [=[/tmp/it's a $(dangerous) `command` path]=], "--json",
}

-- Both hostile on purpose: a single quote, a `$(...)` substitution and a backtick are exactly what
-- a naive `PRECOMMAND='<value>'` would let escape into the script's own command lines. Each carries
-- a sentinel that appears nowhere else, so a leftover copy means text escaped the quoting.
local PRE_HOSTILE = [=[echo pre:it's a $(prestage-sentinel) thing; dump --to /tmp/stage]=]
local POST_HOSTILE = [=[echo "post:$(poststage-sentinel) it's rc=$RESTIC_EXIT"]=]

local BASE_OPTS = { pathPrefix = "/usr/bin:/bin", envFile = ENV_FILE }

-- Single-quote exactly as lib/restic.luau does, so a hostile value can be looked for verbatim.
local function q(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function lineFor(text, needle)
  for line in text:gmatch("[^\n]+") do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

local function indexOf(text, needle)
  return text:find(needle, 1, true)
end

-- [0.3.0] Last occurrence. The pre-command phase now waits for its own child too, so
-- "the normal path's wait" is the *last* one in the script, not the first.
local function lastIndexOf(text, needle)
  local last, from = nil, 1
  while true do
    local at = text:find(needle, from, true)
    if at == nil then
      return last
    end
    last = at
    from = at + 1
  end
end

local function lines(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    table.insert(out, line)
  end
  return out
end

-- First needle that does not occur in `haystack` in order (and after the previous one).
local function missingInOrder(needles, haystack)
  local from = 1
  for _, needle in ipairs(needles) do
    local found = nil
    for index = from, #haystack do
      if haystack[index] == needle then
        found = index
        break
      end
    end
    if found == nil then
      return needle
    end
    from = found + 1
  end
  return nil
end

-- Generate a job. `extra` is the options table handed to M.start (nil = the no-options call shape
-- the service uses today). Returns the script text plus a token-normalised copy, because the job
-- token is random per call and the paths built from it are in every generated script.
local function generate(extra)
  local opts = nil
  if extra ~= nil then
    opts = {}
    for key, value in pairs(extra) do
      opts[key] = value
    end
  end
  local token, err, paths = jobs.start(ARGV, opts)
  if token == nil then
    return { token = nil, err = err, script = "", text = "" }
  end
  local script = H.files[paths.script] or ""
  return { token = token, paths = paths, script = script, text = script:gsub(token, "TOKEN") }
end

-- ── the two options ──────────────────────────────────────────────────────────

local hooked = generate({
  pathPrefix = "/usr/bin:/bin",
  envFile = ENV_FILE,
  preCommand = PRE_HOSTILE,
  postCommand = POST_HOSTILE,
})
local script = hooked.script

check("start with both hooks returns a token", hooked.token ~= nil, tostring(hooked.err))
check("start with both hooks still launches the script detached",
  #H.commands >= 1 and H.commands[#H.commands][1] == "/bin/sh")

-- The assignment: the whole command must sit inside one single-quoted word, and the line must end
-- where that word ends - neither more nor less, or something escaped the quotes.
local preAssignment = lineFor(script, "PRECOMMAND=")
local postAssignment = lineFor(script, "POSTCOMMAND=")
check("the pre-command is written as one single-quoted assignment",
  preAssignment == "PRECOMMAND=" .. q(PRE_HOSTILE), tostring(preAssignment))
check("the post-command is written as one single-quoted assignment",
  postAssignment == "POSTCOMMAND=" .. q(POST_HOSTILE), tostring(postAssignment))
check("a hostile pre-command value round-trips inside its quotes",
  script:find(q(PRE_HOSTILE), 1, true) ~= nil)
check("a hostile post-command value round-trips inside its quotes",
  script:find(q(POST_HOSTILE), 1, true) ~= nil)

-- Strip both quoted values: whatever is left of the hostile text would be text that escaped.
local function plainReplace(text, needle, replacement)
  local pattern = needle:gsub("%W", "%%%0")
  return (text:gsub(pattern, replacement))
end
local stripped = plainReplace(plainReplace(script, q(PRE_HOSTILE), ""), q(POST_HOSTILE), "")
check("nothing of a hook value survives outside its quotes",
  stripped:find("$(prestage-sentinel)", 1, true) == nil
    and stripped:find("$(poststage-sentinel)", 1, true) == nil
    and stripped:find("it's", 1, true) == nil,
  tostring(stripped))

-- The invocation: the variable is run through /bin/sh -c, the value is never inlined, and both
-- streams go to the job log.
--
-- [0.3.0] The hooks now run in the *background* and are waited for, so the script's own TERM trap
-- can reach a hook that is still running: a foreground child defers the trap, which is how a
-- cancelled job kept its pre-command - and then started restic - after the watchdog had already
-- released the single-flight guard. Backgrounding is the only change: the invocation is still
-- `sh -c` with the variable (never the value), both streams still go to the job log, and `wait`
-- restores the old ordering and the old exit code.
check("the pre-command is invoked through sh -c with the variable, never the value",
  lineFor(script, "/bin/sh -c \"$PRECOMMAND\"") == "/bin/sh -c \"$PRECOMMAND\" >> \"$logfile\" 2>&1 &",
  tostring(lineFor(script, "/bin/sh -c \"$PRECOMMAND\"")))
check("the pre-command's pid is tracked for the trap and then waited for",
  indexOf(script, "/bin/sh -c \"$PRECOMMAND\" >> \"$logfile\" 2>&1 &") < indexOf(script, "child=$!")
    and indexOf(script, "child=$!") < lastIndexOf(script, "wait \"$child\"")
    and indexOf(script, "wait \"$child\"") < indexOf(script, "prestatus=$?"),
  tostring(indexOf(script, "child=$!")) .. "/" .. tostring(indexOf(script, "wait \"$child\"")))
check("the pre-command value is never inlined after sh -c",
  script:find("sh -c " .. PRE_HOSTILE, 1, true) == nil)
check("the post-command is invoked through sh -c with the variable, never the value",
  lineFor(script, "sh -c \"$POSTCOMMAND\"")
    == "RESTIC_EXIT=\"$resticexit\" /bin/sh -c \"$POSTCOMMAND\" >> \"$logfile\" 2>&1 &",
  tostring(lineFor(script, "sh -c \"$POSTCOMMAND\"")))
check("the post-command's pid is tracked and waited for too, before the exit code is recorded",
  indexOf(script, "sh -c \"$POSTCOMMAND\"") < indexOf(script, "printf '%s' \"$resticexit\" > \"$exitfile\"")
    and lastIndexOf(script, "child=$!") > indexOf(script, "sh -c \"$POSTCOMMAND\""),
  tostring(lastIndexOf(script, "child=$!")))
check("the post-command value is never inlined after sh -c",
  script:find("sh -c " .. POST_HOSTILE, 1, true) == nil)

-- ── markers in the job log ───────────────────────────────────────────────────

check("the pre-command output is marked in the job log",
  lineFor(script, "== pre-backup command ==")
    == "printf '%s\\n' '== pre-backup command ==' >> \"$logfile\"",
  tostring(lineFor(script, "== pre-backup command ==")))
check("the post-command output is marked in the job log",
  lineFor(script, "== post-backup command ==")
    == "printf '%s\\n' '== post-backup command ==' >> \"$logfile\"",
  tostring(lineFor(script, "== post-backup command ==")))
check("the pre marker is written before the pre-command runs",
  indexOf(script, "== pre-backup command ==") < indexOf(script, "sh -c \"$PRECOMMAND\""))

-- ── ordering around restic ───────────────────────────────────────────────────

local indexRestic = indexOf(script, RESTIC)
check("the restic launch is still in the script", indexRestic ~= nil)
check("the pre-command runs before restic starts",
  indexOf(script, "sh -c \"$PRECOMMAND\"") < indexRestic,
  tostring(indexOf(script, "sh -c \"$PRECOMMAND\"")) .. " vs " .. tostring(indexRestic))
check("the post-command runs after restic finishes",
  indexOf(script, "sh -c \"$POSTCOMMAND\"") > indexRestic)

-- ── the abort path ───────────────────────────────────────────────────────────

check("the pre-command's status is captured", indexOf(script, "prestatus=$?") ~= nil)
check("a non-zero pre-command has an abort branch",
  indexOf(script, "if [ \"$prestatus\" -ne 0 ]; then") ~= nil)
check("the abort branch is evaluated before restic starts",
  indexOf(script, "if [ \"$prestatus\" -ne 0 ]; then") < indexRestic)
check("the abort branch writes the pre-command's own code to the exit file",
  indexOf(script, "printf '%s' \"$prestatus\" > \"$exitfile\"") ~= nil)
check("the abort branch removes the fifo",
  indexOf(script, "  rm -f \"$fifo\"") ~= nil)
check("the abort branch exits with the pre-command's code",
  indexOf(script, "exit \"$prestatus\"") ~= nil)
check("the abort branch comes before the normal path's fifo cleanup",
  indexOf(script, "exit \"$prestatus\"") < (lastIndexOf(script, "wait \"$child\"") or 0),
  tostring(indexOf(script, "exit \"$prestatus\"")) .. "/" .. tostring(lastIndexOf(script, "wait \"$child\"")))
check("the abort branch says why no backup ran",
  indexOf(script, "the pre-backup command failed; restic was not started") ~= nil)

-- ── restic's exit code is the recorded one ───────────────────────────────────

check("restic's status is captured before the post-command runs",
  indexOf(script, "resticexit=$?") ~= nil
    and indexOf(script, "resticexit=$?") < indexOf(script, "sh -c \"$POSTCOMMAND\""))
check("the post-command receives restic's status in RESTIC_EXIT",
  indexOf(script, "RESTIC_EXIT=\"$resticexit\" /bin/sh -c \"$POSTCOMMAND\"") ~= nil)
check("the exit file records restic's status, not the post-command's",
  indexOf(script, "printf '%s' \"$resticexit\" > \"$exitfile\"") ~= nil
    and indexOf(script, "printf '%s' \"$?\" > \"$exitfile\"") == nil)
check("the exit file is written after the post-command",
  indexOf(script, "printf '%s' \"$resticexit\" > \"$exitfile\"")
    > indexOf(script, "sh -c \"$POSTCOMMAND\""))

-- ── every 0.2.0 guarantee is still there ─────────────────────────────────────

local launchLine = lineFor(script, RESTIC)
check("hooks keep the script private",
  indexOf(script, "chmod 600 \"$0\"") ~= nil and indexOf(script, "umask 077") ~= nil)
check("hooks keep the fifo plumbing",
  indexOf(script, "mkfifo \"$fifo\"") ~= nil and indexOf(script, "done < \"$fifo\"") ~= nil)
check("hooks keep restic backgrounded straight into the fifo, with no pipeline",
  launchLine ~= nil and launchLine:find("> \"$fifo\" 2>&1 &", 1, true) ~= nil
    and launchLine:find("|", 1, true) == nil, tostring(launchLine))
check("hooks keep the pid capture", indexOf(script, "child=$!") ~= nil
  and indexOf(script, "printf '%s' \"$child\" > \"$pidfile\"") ~= nil)
check("hooks keep the status/log split",
  indexOf(script, "> \"$statusfile\"") ~= nil and indexOf(script, ">> \"$logfile\"") ~= nil)
check("hooks keep the env file sourcing, before the pre-command",
  indexOf(script, "set -a; . " .. q(ENV_FILE) .. "; set +a") ~= nil
    and indexOf(script, "set +a") < indexOf(script, "== pre-backup command =="))

-- ── each hook on its own ─────────────────────────────────────────────────────

local preOnly = generate({ preCommand = PRE_HOSTILE })
check("pre-only: no POSTCOMMAND, no post marker, no post invocation",
  indexOf(preOnly.script, "POSTCOMMAND") == nil
    and indexOf(preOnly.script, "post-backup") == nil
    and indexOf(preOnly.script, "resticexit") == nil)
check("pre-only: the 0.2.0 tail is untouched",
  indexOf(preOnly.script, "printf '%s' \"$?\" > \"$exitfile\"") ~= nil)

local postOnly = generate({ postCommand = POST_HOSTILE })
check("post-only: no PRECOMMAND, no pre marker, no abort branch",
  indexOf(postOnly.script, "PRECOMMAND") == nil
    and indexOf(postOnly.script, "pre-backup") == nil
    and indexOf(postOnly.script, "prestatus") == nil)

-- ── no hooks means the 0.2.0 script ──────────────────────────────────────────

local noOpts = generate(nil)         -- the call shape service.luau uses today: no options table
local emptyOpts = generate({})
local emptyStrings = generate({ preCommand = "", postCommand = "" })
local wrongTypes = generate({ preCommand = 42, postCommand = true })

check("no options at all still generates a script", #noOpts.script > 0)
check("omitting the options is byte-identical to an empty options table",
  noOpts.text == emptyOpts.text)
check("empty hook strings generate the same script as omitting them",
  emptyStrings.text == noOpts.text)
check("a non-string hook value is ignored, not stringified",
  wrongTypes.text == noOpts.text)
check("the hook-free script contains no hook artefact at all",
  indexOf(noOpts.script, "PRECOMMAND") == nil
    and indexOf(noOpts.script, "POSTCOMMAND") == nil
    and indexOf(noOpts.script, "/bin/sh -c") == nil
    and indexOf(noOpts.script, "pre-backup") == nil
    and indexOf(noOpts.script, "post-backup") == nil
    and indexOf(noOpts.script, "RESTIC_EXIT") == nil
    and indexOf(noOpts.script, "resticexit") == nil
    and indexOf(noOpts.script, "prestatus") == nil)

-- The tail is where the hook-free path could regress silently: three lines, 0.2.0's.
local bareTail = lines(noOpts.script)
local tailCount = #bareTail
check("the hook-free tail is still 0.2.0's",
  bareTail[tailCount - 2] == "wait \"$child\""
    and bareTail[tailCount - 1] == "printf '%s' \"$?\" > \"$exitfile\""
    and bareTail[tailCount] == "rm -f \"$fifo\"",
  table.concat({ bareTail[tailCount - 2] or "?", bareTail[tailCount - 1] or "?", bareTail[tailCount] or "?" }, " / "))

-- The feature is purely additive: every line of the hook-free script except the one the hooks
-- replace (the exit-code write, which becomes `resticexit=$?` + the same write) must still be there,
-- in the same order, and the hooks may add exactly their own 15 lines minus that replacement.
local bare = generate(BASE_OPTS)
local hookedBase = generate({
  pathPrefix = BASE_OPTS.pathPrefix,
  envFile = BASE_OPTS.envFile,
  preCommand = PRE_HOSTILE,
  postCommand = POST_HOSTILE,
})
local bareLines = lines(bare.text)
local hookedLines = lines(hookedBase.text)
local expected = {}
for _, line in ipairs(bareLines) do
  if line ~= "printf '%s' \"$?\" > \"$exitfile\"" then
    table.insert(expected, line)
  end
end
check("hooks only add lines: everything else is unchanged and in order",
  missingInOrder(expected, hookedLines) == nil, tostring(missingInOrder(expected, hookedLines)))
-- 15 hook lines minus the one exit-code write they replace, plus two per hook for the backgrounded
-- child: `child=$!` and the `wait "$child"` that restores the old ordering (0.3.0 cancellation).
check("hooks add exactly their own lines and nothing else",
  #hookedLines == #bareLines + 15 - 1 + 4, tostring(#hookedLines) .. " vs " .. tostring(#bareLines))

-- ── a multi-line command is still one quoted value ───────────────────────────

local multiLine = "dump --to /tmp/stage \\\n  && echo staged"
local multi = generate({ preCommand = multiLine })
check("a command spanning lines stays inside its quotes",
  multi.script:find("PRECOMMAND=" .. q(multiLine), 1, true) ~= nil,
  tostring(lineFor(multi.script, "PRECOMMAND=")))

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
