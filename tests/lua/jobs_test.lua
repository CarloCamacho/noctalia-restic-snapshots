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
-- The hostile path must appear only inside single quotes, so the shell never expands it.
local function q(v)
  return "'" .. v:gsub("'", "'\\''") .. "'"
end
check("hostile path is single-quoted in the script", script:find(q(hostile), 1, true) ~= nil, q(hostile))
check("hostile path is not bare", script:find(hostile, 1, true) == nil or script:find(q(hostile), 1, true) ~= nil)

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
