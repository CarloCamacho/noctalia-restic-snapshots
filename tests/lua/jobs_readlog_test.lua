--!nonstrict
-- Regression tests for jobs.readLog / the log tail, written after a LIVE failure that no
-- plain-Lua test could see: the old tailLines walked the string one character at a time, which
-- blew the host's per-callback CPU budget on a ~97 KB `ls --json` job log and killed the whole
-- service update() tick. Correctness is asserted here; the algorithmic shape (no per-character
-- walk) is asserted by tests/test_source_invariants.py, because a Lua test cannot measure a VM
-- instruction budget.
--
-- Run from the repo root:  lua5.4 tests/lua/jobs_readlog_test.lua

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

local function lines(text)
  local out = {}
  for line in text:gmatch("[^\n]*\n") do
    table.insert(out, line)
  end
  if text:sub(-1) ~= "\n" and text ~= "" then
    table.insert(out, text:sub((text:find("[^\n]*$"))))
  end
  return out
end

local LOG = "/tmp/restic-data/jobs/tail.jsonl"

-- ── correctness ──────────────────────────────────────────────────────────────

H.files[LOG] = "line1\nline2\nline3\nline4\nline5\n"
check("keeps exactly the requested number of lines", jobs.readLog(LOG, 65536, 2) == "line4\nline5\n",
  string.format("%q", jobs.readLog(LOG, 65536, 2)))
check("keeps the whole file when it is shorter than the limit",
  jobs.readLog(LOG, 65536, 99) == H.files[LOG], string.format("%q", jobs.readLog(LOG, 65536, 99)))
check("maxLines = 0 means no line bound", jobs.readLog(LOG, 65536, 0) == H.files[LOG])

H.files[LOG] = "a\nb\nc"          -- no trailing newline
check("handles a missing trailing newline", jobs.readLog(LOG, 65536, 2) == "b\nc",
  string.format("%q", jobs.readLog(LOG, 65536, 2)))

H.files[LOG] = "a\n\nb\n"         -- blank line in the middle counts as a line
check("counts blank lines", jobs.readLog(LOG, 65536, 2) == "\nb\n",
  string.format("%q", jobs.readLog(LOG, 65536, 2)))

H.files[LOG] = ""
check("empty file yields empty text", jobs.readLog(LOG, 65536, 10) == "")
check("missing file yields empty text", jobs.readLog("/tmp/restic-data/jobs/nope.jsonl", 65536, 10) == "")
check("nil path yields empty text", jobs.readLog(nil, 65536, 10) == "")

-- Byte bound first, then the line bound: a 200 KB single-line log must not be walked byte by byte.
local huge = "x" .. string.rep("y", 200000)
H.files[LOG] = huge
local bounded = jobs.readLog(LOG, 4096, 200)
check("a 200 KB single line is byte-bounded", #bounded <= 4096 and #bounded > 0, tostring(#bounded))

-- 5000 lines: the tail must still be exactly the last 200 lines.
local many = {}
for i = 1, 5000 do
  table.insert(many, string.format("{\"n\":%d}", i))
end
H.files[LOG] = table.concat(many, "\n") .. "\n"
local tail = jobs.readLog(LOG, 1048576, 200)
local got = lines(tail)
check("a 5000-line log keeps exactly 200 lines", #got == 200, tostring(#got))
check("the tail starts at line 4801", got[1] == "{\"n\":4801}\n", tostring(got[1]))
check("the tail ends at line 5000", got[#got] == "{\"n\":5000}\n", tostring(got[#got]))

-- ── the poll path is unaffected by the change ────────────────────────────────

local argv = { "/x/restic", "-r", "/tmp/repo", "backup", "--json" }
local token, err, paths = jobs.start(argv, {})
check("start still returns paths", token ~= nil and paths.log ~= nil, tostring(err))
H.files[paths.log] = "{\"message_type\":\"summary\",\"total_files_processed\":3}\n"
H.files[paths.exit] = "0"
local polled = jobs.poll(token, paths, #H.files[paths.log])
check("poll still returns the text on the exit tick", polled.done == true and polled.text ~= "",
  string.format("%q", polled.text))

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
