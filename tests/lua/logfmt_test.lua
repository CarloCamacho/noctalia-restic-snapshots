--!nonstrict
-- logfmt: restic's raw `--json` stream -> human lines.
--
-- Run from the repo root:  lua5.4 tests/lua/logfmt_test.lua
--
-- The inputs are the REAL captures in tests/fixtures/ (restic 0.19.1 on this machine), read from
-- disk: a formatter tested against invented JSON is tested against nothing. tests/test_logfmt.py
-- independently pins the properties of those files (3 status lines, 40 records, ...) so that
-- regenerating a fixture cannot quietly weaken what is asserted here.
--
-- The module is pure by contract, so this suite drives it with `noctalia` replaced by a table that
-- raises on any access: the load and a full pass over every fixture run under that trap.

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")
H.install("plugin/restic-snapshots")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

local function close(a, b)
  return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-9
end

-- ── the module must not need the host at all ────────────────────────────────

local function withHostTrap(fn)
  local real = _G.noctalia
  _G.noctalia = setmetatable({}, {
    __index = function(_, key)
      error("logfmt reached for noctalia." .. tostring(key) .. " -- it must stay pure", 2)
    end,
  })
  local ok, result = pcall(fn)
  _G.noctalia = real
  return ok, result
end

local logfmt, loadError
do
  local ok, result = withHostTrap(function() return H.load("lib/logfmt.luau") end)
  if ok then
    logfmt = result
  end
  loadError = not ok and result or nil
end
check("the module loads with no host available", type(logfmt) == "table", tostring(loadError))
local exported = 0
if type(logfmt) == "table" then
  for _ in pairs(logfmt) do
    exported = exported + 1
  end
end
check("it exposes M.format and nothing else",
  type(logfmt) == "table" and type(logfmt.format) == "function" and exported == 1,
  logfmt and (tostring(logfmt.format) .. " keys=" .. tostring(exported)))
if type(logfmt) ~= "table" or type(logfmt.format) ~= "function" then
  print("\nFAILURES -- the module could not be loaded")
  os.exit(1)
end

-- ── the real fixtures ───────────────────────────────────────────────────────

local function fixture(name)
  local handle = io.open("tests/fixtures/" .. name, "r")
  if handle == nil then
    check("fixture " .. name .. " is readable", false, "tests/fixtures/" .. name .. " is missing")
    return nil
  end
  local text = handle:read("a")
  handle:close()
  return text
end

local function format(text, opts)
  local ok, out = pcall(logfmt.format, text, opts)
  if not ok then
    return nil, out
  end
  return out
end

local function kindOf(line)
  return type(line) == "table" and line.kind or nil
end

local function countKind(out, kind)
  local count = 0
  for _, line in ipairs(out.display) do
    if kindOf(line) == kind then
      count = count + 1
    end
  end
  return count
end

local function first(out, kind)
  for _, line in ipairs(out.display) do
    if kindOf(line) == kind then
      return line
    end
  end
  return nil
end

print("== a real backup log (one 473-byte JSON line)")

do
  local text = fixture("backup-summary.jsonl")
  local out = format(text)
  check("the real one-line log produces exactly one display line",
    out ~= nil and #out.display == 1, out and tostring(#out.display))
  check("it is typed as a backup", kindOf(out.display[1]) == "backup", kindOf(out.display[1]))
  check("nothing else sneaks in as text", countKind(out, "text") == 0)
  check("nothing was folded", out.collapsed == 0, tostring(out.collapsed))
  local line = out.display[1]
  check("filesNew comes from files_new", line.filesNew == 0, tostring(line.filesNew))
  check("filesChanged comes from files_changed", line.filesChanged == 0, tostring(line.filesChanged))
  check("filesUnmodified comes from files_unmodified", line.filesUnmodified == 173,
    tostring(line.filesUnmodified))
  check("dirsNew comes from dirs_new", line.dirsNew == 0, tostring(line.dirsNew))
  check("dirsChanged comes from dirs_changed", line.dirsChanged == 0, tostring(line.dirsChanged))
  check("dataAdded comes from data_added", line.dataAdded == 0, tostring(line.dataAdded))
  check("bytesProcessed comes from total_bytes_processed", line.bytesProcessed == 860367,
    tostring(line.bytesProcessed))
  check("durationSeconds comes from total_duration", close(line.durationSeconds, 1.167760836),
    tostring(line.durationSeconds))
  -- The formatter deliberately builds no second copy of the log (see the module header): the
  -- caller holds the text, and the panel's Raw view renders the service's own lines.
  check("the formatter copies nothing back", out.raw == nil, tostring(out.raw))
end

do
  local text = fixture("backup-unchanged.jsonl")
  local line = first(format(text), "backup")
  check("an unchanged backup is still one backup line",
    line ~= nil and line.filesUnmodified == 4000 and line.dataAdded == 358,
    line and tostring(line.filesUnmodified))
  check("its duration is read", line ~= nil and close(line.durationSeconds, 0.750548185),
    line and tostring(line.durationSeconds))
end

print("== progress: only the last status line, from the real 3-status capture")

do
  local text = fixture("backup-progress.jsonl")
  local out = format(text)
  check("the stream folds into one progress line plus the summary", #out.display == 2,
    tostring(#out.display))
  check("the first line is the progress", kindOf(out.display[1]) == "progress", kindOf(out.display[1]))
  check("the second line is the backup", kindOf(out.display[2]) == "backup", kindOf(out.display[2]))
  check("the two folded status lines are counted", out.collapsed == 2, tostring(out.collapsed))
  local line = out.display[1]
  check("percent is scaled for display (0.8425 -> 84.25)", close(line.percent, 84.25),
    tostring(line.percent))
  check("filesDone is the LAST status line's count", line.filesDone == 3362, tostring(line.filesDone))
  check("totalFiles is carried", line.totalFiles == 4000, tostring(line.totalFiles))
  check("bytesDone is the LAST status line's byte count", line.bytesDone == 220856320,
    tostring(line.bytesDone))
  check("totalBytes is carried", line.totalBytes == 262144000, tostring(line.totalBytes))
  check("the earlier status line's numbers are not the ones shown", line.filesDone ~= 1006,
    tostring(line.filesDone))
  check("the summary after the progress is intact",
    out.display[2].filesNew == 4000 and out.display[2].dirsNew == 6
      and close(out.display[2].durationSeconds, 1.069303796),
    tostring(out.display[2].filesNew))
end

do
  local out = format('{"message_type":"status","percent_done":0.2545,"total_files":4000,'
    .. '"files_done":1006,"total_bytes":262144000,"bytes_done":66715648}')
  check("a run with a single status line folds nothing", out.collapsed == 0, tostring(out.collapsed))
  check("the single status line is shown", #out.display == 1
    and kindOf(out.display[1]) == "progress" and out.display[1].filesDone == 1006,
    tostring(#out.display))
end

print("== check summaries")

do
  local out = format(fixture("check-summary.jsonl"))
  local line = first(out, "check")
  check("a check summary is a check line", line ~= nil and #out.display == 1, kindOf(out.display[1]))
  check("errors comes from num_errors", line ~= nil and line.errors == 0, line and tostring(line.errors))
  check("broken_packs null stays absent rather than becoming 0",
    line ~= nil and line.brokenPacks == nil, line and tostring(line.brokenPacks))
  check("suggestRepair is a boolean", line ~= nil and line.suggestRepair == false,
    line and tostring(line.suggestRepair))
  check("suggestPrune is a boolean", line ~= nil and line.suggestPrune == false,
    line and tostring(line.suggestPrune))
  check("a check folds nothing", out.collapsed == 0, tostring(out.collapsed))
end

do
  -- The same record shape with the flags set: the mapping to booleans is what is under test.
  local out = format('{"message_type":"summary","num_errors":3,"broken_packs":2,'
    .. '"suggest_repair_index":true,"suggest_prune":true}')
  local line = first(out, "check")
  check("a check with problems reports them", line ~= nil and line.errors == 3
    and line.brokenPacks == 2 and line.suggestRepair == true and line.suggestPrune == true,
    line and tostring(line.errors))
end

print("== errors survive")

do
  local out = format(fixture("error.jsonl"))
  local line = first(out, "error")
  check("a real error record becomes an error line",
    line ~= nil and kindOf(out.display[1]) == "error", kindOf(out.display[1]))
  check("the message is restic's own",
    line ~= nil and line.message ==
      "Fatal: unable to open config file: stat /tmp/nope/config: no such file or directory",
    line and line.message)
  check("the exit/error code is carried", line ~= nil and line.code == 10, line and tostring(line.code))
  check("an error is never folded", out.collapsed == 0, tostring(out.collapsed))
end

do
  local lines = { (fixture("error.jsonl"):gsub("\n$", "")) }
  for index = 1, 40 do
    table.insert(lines, "hook output line " .. index)
  end
  local out = format(table.concat(lines, "\n"), { maxLines = 3 })
  check("an error survives a bound that cuts everything else",
    first(out, "error") ~= nil, tostring(#out.display))
  check("the bound is still respected", #out.display <= 3, tostring(#out.display))
end

do
  local out = format('{"message_type":"node","path":"/x","error":{"message":"permission denied"},'
    .. '"code":3}')
  local line = first(out, "error")
  check("a record carrying an error keeps the error", line ~= nil and line.message == "permission denied",
    line and line.message)
  check("the same record is still counted as a record",
    first(out, "records") ~= nil and first(out, "records").count == 1, tostring(#out.display))
end

print("== hook output is text, and text is never folded")

do
  local out = format(fixture("hooks.txt"))
  local expected = {
    "== pre-backup command ==",
    "database dump written to /tmp/dump.sql",
    "== post-backup command ==",
    "pruned 3 old dumps",
  }
  check("hook markers and output are four text lines", #out.display == 4, tostring(#out.display))
  for index, want in ipairs(expected) do
    local line = out.display[index]
    check("line " .. index .. " is the hook text verbatim",
      line ~= nil and line.kind == "text" and line.text == want,
      line and tostring(line.text))
  end
  check("nothing in a hook log is folded", out.collapsed == 0, tostring(out.collapsed))
end

do
  -- Text between JSON records must stay put: it is the only thing in the log a human wrote.
  local text = table.concat({
    "== post-backup command ==",
    '{"message_type":"status","percent_done":0.5,"total_files":4,"files_done":2,'
      .. '"total_bytes":100,"bytes_done":50}',
    "pruned 3 old dumps",
    '{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":3,'
      .. '"dirs_new":0,"dirs_changed":0,"data_added":10,"total_bytes_processed":100,'
      .. '"total_duration":0.5}',
  }, "\n")
  local out = format(text)
  check("text lines are not folded away by the JSON around them",
    countKind(out, "text") == 2 and #out.display == 4, tostring(#out.display))
  check("the order of the stream is preserved",
    out.display[1].kind == "text" and out.display[2].kind == "progress"
      and out.display[3].kind == "text" and out.display[4].kind == "backup",
    kindOf(out.display[1]) .. "," .. kindOf(out.display[2]))
end

print("== record streams are counted, never listed")

do
  local out = format(fixture("ls-list.jsonl"))
  check("forty ls records become ONE line", #out.display == 1, tostring(#out.display))
  local line = out.display[1]
  check("it is a records line, not forty text lines",
    kindOf(line) == "records", kindOf(line))
  check("it counts all forty records", line ~= nil and line.count == 40, line and tostring(line.count))
  check("it names the stream restic gave us", line ~= nil and line.source == "ls", line and line.source)
  check("the folded records are counted", out.collapsed == 39, tostring(out.collapsed))
  check("the formatter builds no raw copy of a 40-line stream", out.raw == nil, tostring(out.raw))
end

do
  local out = format(fixture("ls-real.jsonl"))
  local line = first(out, "records")
  check("a thirty-line ls job is one line too", #out.display == 1 and line ~= nil and line.count == 30,
    tostring(#out.display))
end

print("== output is bounded, and says what it hid")

do
  local lines = {}
  for index = 1, 200 do
    table.insert(lines, "line " .. index)
  end
  local out = format(table.concat(lines, "\n"), { maxLines = 10 })
  check("the display is bounded to maxLines", #out.display == 10, tostring(#out.display))
  check("collapsed tells the truth about the cut", out.collapsed == 190, tostring(out.collapsed))
  check("the newest lines are the ones kept", out.display[10].text == "line 200",
    tostring(out.display[10].text))
end

do
  local lines = { '{"message_type":"summary","files_new":1,"total_files_processed":1}' }
  for index = 1, 300 do
    table.insert(lines, "output " .. index)
  end
  local out = format(table.concat(lines, "\n"), { maxLines = 5 })
  check("a derived line is cut before a text line", #out.display == 5, tostring(#out.display))
  check("the cut is counted", out.collapsed == 296, tostring(out.collapsed))
  check("the summary is the line that went", first(out, "backup") == nil)
end

do
  local lines = {}
  for index = 1, 130 do
    table.insert(lines, '{"message_type":"summary","files_new":' .. index
      .. ',"total_files_processed":1}')
  end
  local out = format(table.concat(lines, "\n"))
  check("the default maxLines (60) applies", #out.display == 60, tostring(#out.display))
  check("a hundred and thirty summaries fold to the newest sixty",
    out.collapsed == 70 and out.display[60].filesNew == 130,
    tostring(out.collapsed) .. "/" .. tostring(out.display[60] and out.display[60].filesNew))
end

do
  local lines = {}
  for index = 1, 500 do
    table.insert(lines, "line " .. index)
  end
  local text = table.concat(lines, "\n")
  local out = format(text, { maxLines = 5 })
  check("a 500-line log is bounded to maxLines", #out.display <= 5, tostring(#out.display))
  check("the lines it cut are reported in collapsed", out.collapsed > 0, tostring(out.collapsed))
end

do
  local long = string.rep("x", 400)
  local out = format(long, { maxWidth = 20 })
  check("a text line is clamped to maxWidth", #out.display[1].text == 20, tostring(#out.display[1].text))
  check("the clamp keeps the head and marks itself", out.display[1].text == string.rep("x", 17) .. "...",
    out.display[1].text)
  local errorOut = format('{"message_type":"error","error":{"message":"' .. long .. '"},"code":1}',
    { maxWidth = 30 })
  check("an error message is clamped as well", #errorOut.display[1].message == 30,
    tostring(#errorOut.display[1].message))
end

print("== nothing about a log may raise")

do
  -- Every entry is a table: a bare `nil` value would end an ipairs walk after the first case.
  local hostile = {
    { name = "nil", value = nil },
    { name = "a number", value = 42 },
    { name = "a table", value = {} },
    { name = "an empty string", value = "" },
    { name = "a lone newline", value = "\n" },
    { name = "whitespace only", value = "   \t " },
    { name = "a truncated object", value = '{"message_type":"summary","files_new":1' },
    { name = "a truncated status", value = '{"message_type":"status"' },
    { name = "an unterminated string", value = '{"message_type":"error","error":{"message":"no end}' },
    { name = "not JSON at all", value = "not json at all" },
    { name = "a broken object", value = '{"a":}' },
    { name = "a JSON array", value = "[1,2,3]" },
    { name = "a JSON scalar", value = "42" },
    { name = "a JSON string", value = '"standalone"' },
    { name = "null", value = "null" },
    { name = "duplicate keys", value = '{"message_type":"summary","files_new":1,"files_new":2}' },
  }
  for _, case in ipairs(hostile) do
    local out, err = format(case.value)
    check(case.name .. " does not raise and returns the documented shape",
      out ~= nil and type(out.display) == "table" and type(out.collapsed) == "number",
      err)
  end
  check("nil input yields an empty result",
    #format(nil).display == 0 and format(nil).collapsed == 0)
  check("a number input yields an empty result", #format(42).display == 0)
  check("a truncated line is shown, not guessed at",
    kindOf(format('{"message_type":"summary","files_new":1').display[1]) == "text")
end

do
  -- The JSON reader has to cope with what a shell can write: spaced keys, exponents, escapes.
  local spaced = format('{"message_type" : "status" , "percent_done" : 0.5 , "files_done" : 2 }')
  check("spaced JSON keys are still read",
    kindOf(spaced.display[1]) == "progress" and spaced.display[1].filesDone == 2,
    kindOf(spaced.display[1]))
  local exponent = format('{"message_type":"status","percent_done":1e-3,"files_done":1}')
  check("an exponent is read as a number", close(exponent.display[1].percent, 0.1),
    tostring(exponent.display[1].percent))
  local escaped = format('{"message_type":"error","error":{"message":"a \\"quoted\\" line\\nwith a '
    .. 'break"},"code":1}')
  check("escapes in an error message are decoded",
    escaped.display[1].message == 'a "quoted" line\nwith a break', escaped.display[1].message)
  local unicode = format('{"message_type":"error","error":{"message":"caf\\u00e9"},"code":1}')
  check("a \\uXXXX escape is kept rather than lost",
    unicode.display[1].message == "caf\\u00e9", unicode.display[1].message)
end

do
  local out = format('{"weird":true,"nested":{"a":1},"list":[1,2,3]}')
  check("JSON that is neither a message nor a record is shown compactly",
    kindOf(out.display[1]) == "text" and out.display[1].text == '{"weird":true,"nested":{"a":1},"list":[1,2,3]}',
    out.display[1].text)
end

print("== purity: no host, no files, no translations")

do
  local names = {
    "backup-summary.jsonl", "backup-progress.jsonl", "backup-unchanged.jsonl",
    "check-summary.jsonl", "error.jsonl", "hooks.txt", "ls-list.jsonl", "ls-real.jsonl",
  }
  local texts = {}
  for _, name in ipairs(names) do
    texts[name] = fixture(name)
  end
  local ok, err = withHostTrap(function()
    for _, name in ipairs(names) do
      local out = logfmt.format(texts[name], {})
      assert(type(out.display) == "table" and (#out.display > 0 or out.collapsed > 0),
        name .. " produced nothing")
    end
    logfmt.format('{"message_type":"error","error":{"message":"x"},"code":1}', nil)
    logfmt.format(nil, nil)
  end)
  check("every fixture formats with `noctalia` replaced by a trap", ok, err)
end

do
  -- Same input, same output: the panel's render depends on that.
  local text = fixture("backup-progress.jsonl")
  local firstPass = format(text)
  local secondPass = format(text)
  local same = #firstPass.display == #secondPass.display and firstPass.collapsed == secondPass.collapsed
  for index = 1, #firstPass.display do
    for key, value in pairs(firstPass.display[index]) do
      if secondPass.display[index][key] ~= value then
        same = false
      end
    end
  end
  check("two calls with the same input agree", same)
end

-- ── per-file records: `backup --json --verbose` (0.6.0) ──────────────────────
-- Without --verbose a backup log is one summary object and the Log tab has nothing to show. With it
-- restic emits one verbose_status per file AND per directory, and the job script drops the
-- `unchanged` ones, so what the formatter sees is the short list of what the run actually did.
-- Both fixtures are real captures from a throwaway repository.

print("== a --verbose backup log (tests/fixtures/backup-verbose-*)")

do
  local out = format(fixture("backup-verbose-modified.jsonl"))
  check("the verbose log formats", out ~= nil and #out.display > 0, out and tostring(#out.display))

  local changed = nil
  for _, line in ipairs(out.display) do
    if kindOf(line) == "file" and line.action == "modified" and type(line.path) == "string"
        and line.path:find("one.txt", 1, true) ~= nil then
      changed = line
    end
  end
  check("the file the run changed becomes a file line naming its path", changed ~= nil)
  check("the file line carries restic's own action word",
    changed ~= nil and changed.action == "modified", changed and tostring(changed.action))
  check("a directory record is kept, trailing slash and all",
    (function()
      for _, line in ipairs(out.display) do
        if kindOf(line) == "file" and type(line.path) == "string" and line.path:sub(-1) == "/" then
          return true
        end
      end
      return false
    end)())
  check("the summary still renders beside the file lines", first(out, "backup") ~= nil)
  check("file lines are not folded into a records count", countKind(out, "records") == 0,
    tostring(countKind(out, "records")))

  -- scan_finished is the one action with no item: it must not become a file line with an empty path.
  local scan = first(out, "scan")
  check("scan_finished is typed as a scan, not as a file", scan ~= nil)
  check("the scan line carries the number of files restic examined",
    scan ~= nil and scan.files == 2, scan and tostring(scan.files))
  check("no file line was made from the item-less scan record",
    (function()
      for _, line in ipairs(out.display) do
        if kindOf(line) == "file" and line.path == nil then
          return false
        end
      end
      return true
    end)())

  local newOut = format(fixture("backup-verbose-new.jsonl"))
  local added = nil
  for _, line in ipairs(newOut.display) do
    if kindOf(line) == "file" and line.action == "new" then
      added = line
      break
    end
  end
  check("a first backup reports the files it added", added ~= nil)
  check("an added file is typed new with its path",
    added ~= nil and added.action == "new" and type(added.path) == "string",
    added and tostring(added.path))

  -- An action this formatter has never seen must still be shown: a file the run touched cannot
  -- vanish because the panel had not heard of the verb.
  local unknown = format('{"message_type":"verbose_status","action":"invented_later","item":"/tmp/x"}')
  local line = unknown ~= nil and unknown.display[1] or nil
  check("an unknown action is passed through, not dropped",
    line ~= nil and line.kind == "file" and line.action == "invented_later",
    line and tostring(line.action))
end

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
