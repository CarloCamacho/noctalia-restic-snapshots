--!nonstrict
-- Real assertions for the pure command/parse layer (lib/restic.luau) of Restic Snapshots.
--
-- The fixtures below are verbatim output captured from restic 0.19.1 on this machine against a
-- throwaway repository under /tmp (created and deleted by this workstream; see
-- docs/phase0-findings.md for the documented shapes). No user repository is read.
--
-- Run from the repo root:  lua5.4 tests/lua/restic_pure_test.lua

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")
H.install("plugin/restic-snapshots")

-- ── a real JSON decoder ──────────────────────────────────────────────────────
-- The harness's json.decode is canned (H.jsonMap / H.decodeFn) because the entries only ever hand
-- it a payload the test already knows. Here the input is genuine restic output, so the test
-- installs a decoder and parses the bytes for real. JSON `null` decodes to nil, which is how the
-- host behaves for absent values.

local function jsonDecode(text)
  local pos = 1

  local function fail(message)
    error(message .. " at byte " .. tostring(pos), 0)
  end

  local function skipSpace()
    local _, stop = text:find("[ \t\r\n]*", pos)
    pos = stop + 1
  end

  local parseValue

  local function parseString()
    pos = pos + 1 -- opening quote
    local out = {}
    while pos <= #text do
      local ch = text:sub(pos, pos)
      if ch == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif ch == "\\" then
        local esc = text:sub(pos + 1, pos + 1)
        if esc == "u" then
          table.insert(out, utf8.char(tonumber(text:sub(pos + 2, pos + 5), 16)))
          pos = pos + 6
        elseif esc == "n" then
          table.insert(out, "\n")
          pos = pos + 2
        elseif esc == "t" then
          table.insert(out, "\t")
          pos = pos + 2
        elseif esc == "r" then
          table.insert(out, "\r")
          pos = pos + 2
        elseif esc == "b" or esc == "f" then
          table.insert(out, " ")
          pos = pos + 2
        elseif esc == "/" or esc == '"' or esc == "\\" then
          table.insert(out, esc)
          pos = pos + 2
        else
          fail("bad escape")
        end
      else
        table.insert(out, ch)
        pos = pos + 1
      end
    end
    fail("unterminated string")
  end

  local function parseArray()
    pos = pos + 1
    local out = {}
    skipSpace()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return out
    end
    while true do
      table.insert(out, parseValue())
      skipSpace()
      local ch = text:sub(pos, pos)
      if ch == "," then
        pos = pos + 1
      elseif ch == "]" then
        pos = pos + 1
        return out
      else
        fail("expected , or ]")
      end
    end
  end

  local function parseObject()
    pos = pos + 1
    local out = {}
    skipSpace()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return out
    end
    while true do
      skipSpace()
      local key = parseString()
      skipSpace()
      if text:sub(pos, pos) ~= ":" then
        fail("expected :")
      end
      pos = pos + 1
      local value = parseValue()
      if value ~= nil then
        out[key] = value
      end
      skipSpace()
      local ch = text:sub(pos, pos)
      if ch == "," then
        pos = pos + 1
      elseif ch == "}" then
        pos = pos + 1
        return out
      else
        fail("expected , or }")
      end
    end
  end

  parseValue = function()
    skipSpace()
    local ch = text:sub(pos, pos)
    if ch == "{" then
      return parseObject()
    elseif ch == "[" then
      return parseArray()
    elseif ch == '"' then
      return parseString()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if number ~= nil and number ~= "" then
      pos = pos + #number
      return tonumber(number)
    end
    fail("unexpected character")
  end

  local value = parseValue()
  skipSpace()
  return value
end

H.decodeFn = jsonDecode

local restic = H.load("lib/restic.luau")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

-- ── fixtures: verbatim restic 0.19.1 output ──────────────────────────────────
-- tags: the values in @@...@@ positions were substituted from the captured files, never retyped.

-- `snapshots --json` — one JSON array.
local SNAPSHOTS = [==[[{"time":"2026-09-14T21:20:42.108154635+08:00","tree":"dd6e282b45845227b5f7cb65d8395642be9b950bb8844bcfd2226fbef0672aab","paths":["/tmp/rs-b-fixture/data"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia","daily"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:20:42.108154635+08:00","backup_end":"2026-09-14T21:20:43.180859472+08:00","files_new":4004,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":4121,"tree_blobs":6,"data_added":201491562,"data_added_packed":200577230,"total_files_processed":4004,"total_bytes_processed":200038893},"id":"bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce","short_id":"bcd441d2"},{"time":"2026-09-14T21:20:43.197304291+08:00","tree":"22f0a37c60867097ba93caef324abdfc2927ff5fc624a37ce077da8e8960a8ed","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia","daily"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:20:43.197304291+08:00","backup_end":"2026-09-14T21:20:44.050004878+08:00","files_new":4005,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":2,"tree_blobs":6,"data_added":1450427,"data_added_packed":224486,"total_files_processed":4005,"total_bytes_processed":150038931},"id":"e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44","short_id":"e29a0067"}]
]==]
-- an empty repository answers with an empty array
local EMPTY_SNAPSHOTS = "[]"
-- `stats --json` — one object
local STATS = [==[{"total_size":350077824,"total_file_count":8019,"snapshots_count":2}
]==]
-- `check --json` — the summary record (used here to prove it is not a stats payload)
local CHECK = [==[{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}
]==]
-- `backup --json` — JSONL: four `status` records then the `summary`
local BACKUP = [==[{"message_type":"status","percent_done":0.36113900110415026,"total_files":4004,"total_bytes":200038893,"bytes_done":72241846,"current_files":["/tmp/rs-b-fixture/data/big/blob1.bin","/tmp/rs-b-fixture/data/big/blob2.bin"]}
{"message_type":"status","percent_done":0.718155468896741,"total_files":4004,"files_done":2,"total_bytes":200038893,"bytes_done":143659025,"current_files":["/tmp/rs-b-fixture/data/big/blob3.bin","/tmp/rs-b-fixture/data/big/blob4.bin"]}
{"message_type":"status","percent_done":0.9998271136203498,"total_files":4004,"files_done":439,"total_bytes":200038893,"bytes_done":200004309}
{"message_type":"status","percent_done":1,"total_files":4004,"files_done":4004,"total_bytes":200038893,"bytes_done":200038893}
{"message_type":"summary","files_new":4004,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":4121,"tree_blobs":6,"data_added":201491562,"data_added_packed":200577230,"total_files_processed":4004,"total_bytes_processed":200038893,"total_duration":1.072704827,"backup_start":"2026-09-14T21:20:42.108154635+08:00","backup_end":"2026-09-14T21:20:43.180859472+08:00","snapshot_id":"bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce"}
]==]
-- the `.status` file holds exactly one of those status lines
local STATUS = [==[{"message_type":"status","percent_done":1,"total_files":4004,"files_done":4004,"total_bytes":200038893,"bytes_done":200038893}
]==]
-- `ls <id> --json` — the leading `snapshot` record then one `node` record per entry
local LS = [==[{"time":"2026-09-14T21:20:42.108154635+08:00","tree":"dd6e282b45845227b5f7cb65d8395642be9b950bb8844bcfd2226fbef0672aab","paths":["/tmp/rs-b-fixture/data"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia","daily"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:20:42.108154635+08:00","backup_end":"2026-09-14T21:20:43.180859472+08:00","files_new":4004,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":4121,"tree_blobs":6,"data_added":201491562,"data_added_packed":200577230,"total_files_processed":4004,"total_bytes_processed":200038893},"id":"bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce","short_id":"bcd441d2","message_type":"snapshot","struct_type":"snapshot"}
{"name":"tmp","type":"dir","path":"/tmp","uid":0,"gid":0,"mode":2148532735,"permissions":"dtrwxrwxrwx","mtime":"2026-09-14T21:20:38.202719215+08:00","atime":"2026-09-14T21:20:38.202719215+08:00","ctime":"2026-09-14T21:20:38.202719215+08:00","inode":1,"message_type":"node","struct_type":"node"}
{"name":"rs-b-fixture","type":"dir","path":"/tmp/rs-b-fixture","uid":1000,"gid":1000,"mode":2147484141,"permissions":"drwxr-xr-x","mtime":"2026-09-14T21:20:38.203719208+08:00","atime":"2026-09-14T21:20:38.203719208+08:00","ctime":"2026-09-14T21:20:38.203719208+08:00","inode":74407,"message_type":"node","struct_type":"node"}
{"name":"data","type":"dir","path":"/tmp/rs-b-fixture/data","uid":1000,"gid":1000,"mode":2147484141,"permissions":"drwxr-xr-x","mtime":"2026-09-14T21:20:38.209719168+08:00","atime":"2026-09-14T21:20:38.209719168+08:00","ctime":"2026-09-14T21:20:38.209719168+08:00","inode":74409,"message_type":"node","struct_type":"node"}
{"name":"big","type":"dir","path":"/tmp/rs-b-fixture/data/big","uid":1000,"gid":1000,"mode":2147484141,"permissions":"drwxr-xr-x","mtime":"2026-09-14T21:20:38.69571593+08:00","atime":"2026-09-14T21:20:38.69571593+08:00","ctime":"2026-09-14T21:20:38.69571593+08:00","inode":74413,"message_type":"node","struct_type":"node"}
{"name":"blob1.bin","type":"file","path":"/tmp/rs-b-fixture/data/big/blob1.bin","uid":1000,"gid":1000,"size":50000000,"mode":420,"permissions":"-rw-r--r--","mtime":"2026-09-14T21:20:38.374718069+08:00","atime":"2026-09-14T21:20:38.374718069+08:00","ctime":"2026-09-14T21:20:38.374718069+08:00","inode":74415,"message_type":"node","struct_type":"node"}
]==]
-- `diff --json` — `change` records then the final `statistics` record
local DIFF = [==[{"message_type":"change","path":"/tmp/rs-b-fixture/data2/big/blob1.bin","modifier":"M"}
{"message_type":"statistics","source_snapshot":"e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44","target_snapshot":"3d97b2d6a14a83b9ee54410ff3574522190664c1172d566a8af4c0efcb2bf937","changed_files":1,"added":{"files":0,"dirs":0,"others":0,"data_blobs":1,"tree_blobs":5,"bytes":9477},"removed":{"files":0,"dirs":0,"others":0,"data_blobs":1,"tree_blobs":5,"bytes":9468}}
{"message_type":"change","path":"/tmp/rs-b-fixture/data/","modifier":"-"}
{"message_type":"change","path":"/tmp/rs-b-fixture/data/big/","modifier":"-"}
{"message_type":"change","path":"/tmp/rs-b-fixture/data/big/blob1.bin","modifier":"-"}
]==]
-- the `statistics` record of a *no-change* diff, which emits no `change` record at all
local DIFF_STATISTICS_ONLY = [==[{"message_type":"statistics","source_snapshot":"e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44","target_snapshot":"3d97b2d6a14a83b9ee54410ff3574522190664c1172d566a8af4c0efcb2bf937","changed_files":1,"added":{"files":0,"dirs":0,"others":0,"data_blobs":1,"tree_blobs":5,"bytes":9477},"removed":{"files":0,"dirs":0,"others":0,"data_blobs":1,"tree_blobs":5,"bytes":9468}}
]==]
-- `forget --keep-last 1 --dry-run --json` — group records with keep / remove / reasons
local FORGET = [==[[{"tags":null,"host":"cachyos-x8664","paths":["/tmp/rs-b-fixture/data2"],"keep":[{"time":"2026-09-14T21:23:16.318066415+08:00","parent":"73fb9912e131a3c01dcbb5de82c185f1d1a8ee5b081c164c38b88fa9736e31a9","tree":"7edc81e365850d401a8b1bd883876a90ca29237733b6989766dbc44d7978b90d","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:23:16.318066415+08:00","backup_end":"2026-09-14T21:23:17.02831105+08:00","files_new":0,"files_changed":1,"files_unmodified":4004,"dirs_new":0,"dirs_changed":4,"dirs_unmodified":1,"data_blobs":1,"tree_blobs":5,"data_added":9466,"data_added_packed":5078,"total_files_processed":4005,"total_bytes_processed":150038929},"id":"a287c5311f92b8482a37637d9666950ddd389bf78e32a30cbbb211d764d44cdd","short_id":"a287c531"}],"remove":[{"time":"2026-09-14T21:23:15.596522479+08:00","parent":"9ed49af2872c30061b9de8ac1dc6ccf99fc153465ad4fe79814b65d50f769fb4","tree":"c484b842ac3952f9967bc95a00bd6f271eb7742e7553677c17225acb74e1424c","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:23:15.596522479+08:00","backup_end":"2026-09-14T21:23:16.310461361+08:00","files_new":0,"files_changed":1,"files_unmodified":4004,"dirs_new":0,"dirs_changed":4,"dirs_unmodified":1,"data_blobs":1,"tree_blobs":5,"data_added":9466,"data_added_packed":5079,"total_files_processed":4005,"total_bytes_processed":150038929},"id":"73fb9912e131a3c01dcbb5de82c185f1d1a8ee5b081c164c38b88fa9736e31a9","short_id":"73fb9912"},{"time":"2026-09-14T21:23:14.867994685+08:00","parent":"3d97b2d6a14a83b9ee54410ff3574522190664c1172d566a8af4c0efcb2bf937","tree":"69fc98060f4e3c3c10ae626eb51a499abb9d77af4d1b3a73a0058cd94f35b41a","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:23:14.867994685+08:00","backup_end":"2026-09-14T21:23:15.588673096+08:00","files_new":0,"files_changed":1,"files_unmodified":4004,"dirs_new":0,"dirs_changed":4,"dirs_unmodified":1,"data_blobs":1,"tree_blobs":5,"data_added":9466,"data_added_packed":5077,"total_files_processed":4005,"total_bytes_processed":150038929},"id":"9ed49af2872c30061b9de8ac1dc6ccf99fc153465ad4fe79814b65d50f769fb4","short_id":"9ed49af2"},{"time":"2026-09-14T21:22:02.361737855+08:00","parent":"e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44","tree":"c5298a753a145eef16a8cf3d30093f4c53642ca0c19797437c6ba73d1678a822","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:22:02.361737855+08:00","backup_end":"2026-09-14T21:22:03.071795222+08:00","files_new":0,"files_changed":1,"files_unmodified":4004,"dirs_new":0,"dirs_changed":4,"dirs_unmodified":1,"data_blobs":1,"tree_blobs":5,"data_added":9477,"data_added_packed":5087,"total_files_processed":4005,"total_bytes_processed":150038939},"id":"3d97b2d6a14a83b9ee54410ff3574522190664c1172d566a8af4c0efcb2bf937","short_id":"3d97b2d6"},{"time":"2026-09-14T21:20:43.197304291+08:00","tree":"22f0a37c60867097ba93caef324abdfc2927ff5fc624a37ce077da8e8960a8ed","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia","daily"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:20:43.197304291+08:00","backup_end":"2026-09-14T21:20:44.050004878+08:00","files_new":4005,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":2,"tree_blobs":6,"data_added":1450427,"data_added_packed":224486,"total_files_processed":4005,"total_bytes_processed":150038931},"id":"e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44","short_id":"e29a0067"}],"reasons":[{"snapshot":{"time":"2026-09-14T21:23:16.318066415+08:00","parent":"73fb9912e131a3c01dcbb5de82c185f1d1a8ee5b081c164c38b88fa9736e31a9","tree":"7edc81e365850d401a8b1bd883876a90ca29237733b6989766dbc44d7978b90d","paths":["/tmp/rs-b-fixture/data2"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:23:16.318066415+08:00","backup_end":"2026-09-14T21:23:17.02831105+08:00","files_new":0,"files_changed":1,"files_unmodified":4004,"dirs_new":0,"dirs_changed":4,"dirs_unmodified":1,"data_blobs":1,"tree_blobs":5,"data_added":9466,"data_added_packed":5078,"total_files_processed":4005,"total_bytes_processed":150038929},"id":"a287c5311f92b8482a37637d9666950ddd389bf78e32a30cbbb211d764d44cdd","short_id":"a287c531"},"matches":["last snapshot"]}]},{"tags":null,"host":"cachyos-x8664","paths":["/tmp/rs-b-fixture/data"],"keep":[{"time":"2026-09-14T21:20:42.108154635+08:00","tree":"dd6e282b45845227b5f7cb65d8395642be9b950bb8844bcfd2226fbef0672aab","paths":["/tmp/rs-b-fixture/data"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia","daily"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:20:42.108154635+08:00","backup_end":"2026-09-14T21:20:43.180859472+08:00","files_new":4004,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":4121,"tree_blobs":6,"data_added":201491562,"data_added_packed":200577230,"total_files_processed":4004,"total_bytes_processed":200038893},"id":"bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce","short_id":"bcd441d2"}],"remove":null,"reasons":[{"snapshot":{"time":"2026-09-14T21:20:42.108154635+08:00","tree":"dd6e282b45845227b5f7cb65d8395642be9b950bb8844bcfd2226fbef0672aab","paths":["/tmp/rs-b-fixture/data"],"hostname":"cachyos-x8664","username":"ian","uid":1000,"gid":1000,"tags":["noctalia","daily"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-09-14T21:20:42.108154635+08:00","backup_end":"2026-09-14T21:20:43.180859472+08:00","files_new":4004,"files_changed":0,"files_unmodified":0,"dirs_new":5,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":4121,"tree_blobs":6,"data_added":201491562,"data_added_packed":200577230,"total_files_processed":4004,"total_bytes_processed":200038893},"id":"bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce","short_id":"bcd441d2"},"matches":["last snapshot"]}]}]
exit=0
]==]

-- ── configuration ────────────────────────────────────────────────────────────

local function settings(overrides)
  local base = {
    restic_bin = "",
    repository = "/srv/restic/repo",
    password_file = "/run/secrets/restic-pass",
    backup_paths = { "/home/tester/docs", "/etc" },
    backup_tags = { "noctalia" },
    exclude_file = "",
    mode = "",
    interval_minutes = 30,
    keep_last = 7,
    keep_daily = 7,
    keep_weekly = 4,
    keep_monthly = 6,
    restore_target = "~/restore",
    restore_allow_roots = { "~/extra", "/srv/staging", "relative/dir", "" },
    check_subset = "",
    check_interval_hours = 12,
    stale_after_hours = 0,
    job_timeout_minutes = 0,
    env_file = "/home/tester/.config/restic.env",
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local cfg = restic.config(settings())
check("config: bin falls back to restic", cfg.bin == "restic", cfg.bin)
check("config: repository is kept verbatim for argv", cfg.repository == "/srv/restic/repo")
check("config: redactedRepository is a separate display value", cfg.redactedRepository == "/srv/restic/repo")
check("config: passwordFile", cfg.passwordFile == "/run/secrets/restic-pass")
check("config: mode defaults to plugin", cfg.mode == "plugin", cfg.mode)
check("config: intervalMinutes", cfg.intervalMinutes == 30)
check("config: keep rules",
  cfg.keepLast == 7 and cfg.keepDaily == 7 and cfg.keepWeekly == 4 and cfg.keepMonthly == 6)
check("config: restoreTarget is ~-expanded", cfg.restoreTarget == "/home/tester/restore", cfg.restoreTarget)
check("config: allow roots are expanded and absolute-only",
  #cfg.restoreAllowRoots == 2 and cfg.restoreAllowRoots[1] == "/home/tester/extra"
    and cfg.restoreAllowRoots[2] == "/srv/staging",
  table.concat(cfg.restoreAllowRoots, ","))
check("config: checkSubset defaults to 1/100", restic.config(settings()).checkSubset == "1/100")
check("config: checkIntervalHours", cfg.checkIntervalHours == 12)
check("config: staleAfterHours defaults to 0 (= derive from the interval)", cfg.staleAfterHours == 0)
check("config: a non-positive watchdog ceiling falls back to 180",
  cfg.jobTimeoutMinutes == 180, cfg.jobTimeoutMinutes)
check("config: envFile", cfg.envFile == "/home/tester/.config/restic.env")
check("config: hostile repository is redacted in the display copy",
  restic.config(settings({ repository = "sftp://ian:secret@host:/repo" })).redactedRepository
    == "sftp://***@host:/repo")

local frozenKeys = { "bin", "repository", "redactedRepository", "passwordFile", "paths", "tags",
  "excludeFile", "mode", "intervalMinutes", "keepLast", "keepDaily", "keepWeekly", "keepMonthly",
  "restoreTarget", "restoreAllowRoots", "checkSubset", "checkIntervalHours", "staleAfterHours",
  "jobTimeoutMinutes", "envFile" }
local empty = restic.config(nil)
local missing = {}
for _, key in ipairs(frozenKeys) do
  if empty[key] == nil then
    table.insert(missing, key)
  end
end
check("config: every frozen key is present even for empty settings", #missing == 0, table.concat(missing, ","))

-- ── argv builders ────────────────────────────────────────────────────────────

local BIN = "/usr/bin/restic"

local function indexOf(argv, value)
  for index, item in ipairs(argv) do
    if item == value then
      return index
    end
  end
  return 0
end

local function hasPrefix(argv, prefix)
  for _, item in ipairs(argv) do
    if type(item) == "string" and item:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local snap = restic.snapshotsArgs(cfg, BIN)
check("snapshots: bin, password flag, then -r",
  snap[1] == BIN and snap[2] == "--password-file" and snap[3] == "/run/secrets/restic-pass"
    and snap[4] == "-r" and snap[5] == "/srv/restic/repo")
check("snapshots: --no-lock is a global flag before the subcommand",
  indexOf(snap, "--no-lock") > 0 and indexOf(snap, "--no-lock") < indexOf(snap, "snapshots"), table.concat(snap, " "))
check("snapshots: --json", indexOf(snap, "--json") > 0)

local statsArgv = restic.statsArgs(cfg, BIN)
check("stats: --no-lock before stats",
  indexOf(statsArgv, "stats") > 0 and indexOf(statsArgv, "--no-lock") < indexOf(statsArgv, "stats"))
check("stats: --json", indexOf(statsArgv, "--json") > 0)

local lsArgv = restic.lsArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
check("ls: --no-lock, then ls <id> --json",
  indexOf(lsArgv, "--no-lock") < indexOf(lsArgv, "ls") and indexOf(lsArgv, "ls") + 1 == indexOf(lsArgv, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
    and indexOf(lsArgv, "--json") > 0, table.concat(lsArgv, " "))

local diffArgv = restic.diffArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44")
check("diff: --no-lock, then diff <from> <to> --json",
  indexOf(diffArgv, "--no-lock") < indexOf(diffArgv, "diff")
    and indexOf(diffArgv, "diff") + 1 == indexOf(diffArgv, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
    and indexOf(diffArgv, "e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44") == indexOf(diffArgv, "diff") + 2
    and indexOf(diffArgv, "--json") > 0, table.concat(diffArgv, " "))

local checkArgv = restic.checkArgs(cfg, BIN)
check("check: uses the configured subset", hasPrefix(checkArgv, "--read-data-subset="))
check("check: cfg.checkSubset default 1/100 is passed",
  indexOf(checkArgv, "--read-data-subset=1/100") > 0, table.concat(checkArgv, " "))
check("check: is not read-only, so no --no-lock", indexOf(checkArgv, "--no-lock") == 0)
local checkOverride = restic.checkArgs(cfg, BIN, "3/7")
check("check: an override wins over the configured subset",
  indexOf(checkOverride, "--read-data-subset=3/7") > 0
    and indexOf(checkOverride, "--read-data-subset=1/100") == 0, table.concat(checkOverride, " "))
local noSubsetCfg = { bin = "restic", repository = "/srv/restic/repo", passwordFile = "", checkSubset = "" }
check("check: an empty subset omits the flag",
  not hasPrefix(restic.checkArgs(noSubsetCfg, BIN), "--read-data-subset="))
check("check: a real config always carries a subset, because config defaults it to 1/100",
  restic.config(settings({ check_subset = "" })).checkSubset == "1/100")

local forgetOne = restic.forgetOneArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
check("forget-one: forget <id> --json",
  forgetOne ~= nil and indexOf(forgetOne, "forget") + 1 == indexOf(forgetOne, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
    and indexOf(forgetOne, "--json") > 0, forgetOne and table.concat(forgetOne, " "))
check("forget-one: never --prune", indexOf(forgetOne, "--prune") == 0)
check("forget-one: never --dry-run", indexOf(forgetOne, "--dry-run") == 0)
local forgetBad, forgetErr = restic.forgetOneArgs(cfg, BIN, "--host=evil")
check("forget-one: refuses a flag-shaped id", forgetBad == nil and type(forgetErr) == "string", tostring(forgetErr))

local restore = restic.restoreArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "/home/tester/restore", { "/home/tester/docs/*" })
check("restore: restore <id> --target <dir> --include <pattern> --json",
  indexOf(restore, "restore") + 1 == indexOf(restore, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
    and restore[indexOf(restore, "--target") + 1] == "/home/tester/restore"
    and restore[indexOf(restore, "--include") + 1] == "/home/tester/docs/*"
    and indexOf(restore, "--json") > 0, table.concat(restore, " "))
check("restore: no --dry-run unless asked", indexOf(restore, "--dry-run") == 0)
local restoreDry = restic.restoreArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "/home/tester/restore", nil, { dryRun = true })
check("restore: opts.dryRun adds --dry-run", indexOf(restoreDry, "--dry-run") > 0, table.concat(restoreDry, " "))
local okNoOpts, noOpts = pcall(restic.restoreArgs, cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "/home/tester/restore")
check("restore: opts may be omitted entirely", okNoOpts == true and type(noOpts) == "table")
local restoreTilde = restic.restoreArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "~/restore", nil, {})
check("restore: a ~ target is expanded for restic, which does not expand it itself",
  indexOf(restoreTilde, "/home/tester/restore") > 0, table.concat(restoreTilde, " "))
local restoreBad, restoreErr = restic.restoreArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "relative/target")
check("restore: refuses a relative target", restoreBad == nil and type(restoreErr) == "string", tostring(restoreErr))
local restoreBadId = restic.restoreArgs(cfg, BIN, "latest", "/home/tester/restore")
check("restore: refuses a non-hex snapshot id in the positional slot", restoreBadId == nil)

local lsBad, lsErr = restic.lsArgs(cfg, BIN, "-x")
check("ls: refuses a flag-shaped id", lsBad == nil and type(lsErr) == "string", tostring(lsErr))
local diffBad = restic.diffArgs(cfg, BIN, "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce", "--no-lock")
check("diff: refuses a flag in the second id position", diffBad == nil)

local init = restic.initArgs(cfg, BIN)
check("init: init --json", indexOf(init, "init") > 0 and indexOf(init, "--json") > 0, table.concat(init, " "))
local unlock = restic.unlockArgs(cfg, BIN)
check("unlock: unlock --remove-all --json",
  indexOf(unlock, "unlock") > 0 and indexOf(unlock, "--remove-all") > 0 and indexOf(unlock, "--json") > 0,
  table.concat(unlock, " "))
check("unlock: must not carry --no-lock, or it would ignore the lock it removes",
  indexOf(unlock, "--no-lock") == 0)

local backup = restic.backupArgs(cfg, BIN)
check("backup: unchanged — paths, --json, one --tag per tag",
  indexOf(backup, "backup") > 0 and indexOf(backup, "/home/tester/docs") > 0 and indexOf(backup, "/etc") > 0
    and indexOf(backup, "--json") > 0 and indexOf(backup, "--tag") > 0)
check("backup: no --no-lock (it writes)", indexOf(backup, "--no-lock") == 0)
check("backup: exclude file only when configured", indexOf(backup, "--exclude-file") == 0)
check("backup: exclude file when configured",
  indexOf(restic.backupArgs(restic.config(settings({ exclude_file = "/tmp/ex" })), BIN), "/tmp/ex") > 0)

local policy = restic.policyArgs(cfg)
check("policy: one flag per positive rule, in order",
  #policy == 8 and policy[1] == "--keep-last" and policy[2] == "7" and policy[7] == "--keep-monthly"
    and policy[8] == "6", table.concat(policy, " "))
local noPolicy = restic.config(settings({ keep_last = 0, keep_daily = 0, keep_weekly = 0, keep_monthly = 0 }))
check("policy: empty when every rule is 0", #restic.policyArgs(noPolicy) == 0)
check("hasPolicy: true with a rule, false without", restic.hasPolicy(cfg) and not restic.hasPolicy(noPolicy))
local forgetDry = restic.forgetArgs(cfg, BIN, true)
local forgetPrune = restic.forgetArgs(cfg, BIN, false)
check("forget: dry run has --dry-run and no --prune",
  indexOf(forgetDry, "--dry-run") > 0 and indexOf(forgetDry, "--prune") == 0)
check("forget: the real run has --prune and no --dry-run",
  indexOf(forgetPrune, "--prune") > 0 and indexOf(forgetPrune, "--dry-run") == 0)

check("jobs.luau contract: shellQuote and shellArgv are still exported",
  type(restic.shellQuote) == "function" and type(restic.shellArgv) == "function")
check("quoting: a plain value is single-quoted", restic.shellQuote("plain") == "'plain'")
check("quoting: an embedded quote is escaped", restic.shellQuote("it's") == "'it'\\''s'",
  restic.shellQuote("it's"))
check("quoting: argv joins the quoted values with spaces", restic.shellArgv({ "a b", "c" }) == "'a b' 'c'")

-- ── redaction ────────────────────────────────────────────────────────────────

check("redact: a local filesystem path is never touched",
  restic.redactRepository("/home/tester/backups") == "/home/tester/backups")
check("redact: a ~ path is never touched", restic.redactRepository("~/backups") == "~/backups")
check("redact: a relative path is never touched", restic.redactRepository("backups/2026") == "backups/2026")
local redactedUrl = restic.redactRepository("sftp://ian:sup3rs3cret@backup.example.com:/srv/restic")
check("redact: userinfo is stripped from a URL",
  redactedUrl:find("sup3rs3cret", 1, true) == nil and redactedUrl:find("ian", 1, true) == nil, redactedUrl)
check("redact: the host survives so the user can still recognise the repository",
  redactedUrl == "sftp://***@backup.example.com:/srv/restic", redactedUrl)
check("redact: scp-style userinfo is stripped",
  restic.redactRepository("sftp:ian:hunter2@host:/srv/repo") == "sftp:***@host:/srv/repo",
  restic.redactRepository("sftp:ian:hunter2@host:/srv/repo"))
check("redact: a credential query parameter is redacted",
  restic.redactRepository("rest:https://backup.example.com/repo?token=abc123&user=ian")
    == "rest:https://backup.example.com/repo?token=***&user=ian",
  restic.redactRepository("rest:https://backup.example.com/repo?token=abc123&user=ian"))
check("redact: the query key match is case-insensitive",
  restic.redactRepository("rest:https://h/repo?Password=x&ACCESS_KEY=y")
    == "rest:https://h/repo?Password=***&ACCESS_KEY=***")
check("redact: a token-looking segment is replaced",
  restic.redactRepository("rclone:remote:9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d")
    == "rclone:remote:***")
check("redact: a repository path with a normal name survives",
  restic.redactRepository("rclone:remote:restic-snapshots/cachyos") == "rclone:remote:restic-snapshots/cachyos")
check("redact: is idempotent, so an already-redacted status string is safe to redact again",
  restic.redactRepository(redactedUrl) == redactedUrl)
check("redact: empty and nil are the empty string",
  restic.redactRepository(nil) == "" and restic.redactRepository("") == "")

-- ── validators ───────────────────────────────────────────────────────────────

check("validSnapshotId: the real id passes", restic.validSnapshotId("bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce"))
check("validSnapshotId: 4 hex characters pass", restic.validSnapshotId("abcd"))
check("validSnapshotId: uppercase hex passes", restic.validSnapshotId("ABCD1234"))
check("validSnapshotId: 64 hex characters pass", restic.validSnapshotId(string.rep("a", 64)))
check("validSnapshotId: 3 characters are refused", not restic.validSnapshotId("abc"))
check("validSnapshotId: 65 characters are refused", not restic.validSnapshotId(string.rep("a", 65)))
check("validSnapshotId: latest is refused", not restic.validSnapshotId("latest"))
check("validSnapshotId: a flag is refused", not restic.validSnapshotId("--host=x"))
check("validSnapshotId: non-hex is refused", not restic.validSnapshotId("bcd44g12"))
check("validSnapshotId: trailing whitespace is refused", not restic.validSnapshotId("bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce "))
check("validSnapshotId: non-strings are refused",
  not restic.validSnapshotId(nil) and not restic.validSnapshotId({}) and not restic.validSnapshotId(1234))

local function targetOk(path)
  return restic.validRestoreTarget(cfg, path)
end

check("target: the staging root itself is allowed", targetOk("/home/tester/restore") == true)
check("target: a directory under the staging root is allowed", targetOk("/home/tester/restore/2026-09-14") == true)
check("target: an allow-listed root is allowed", targetOk("/srv/staging/restored") == true)
check("target: a ~ path under an allow root is allowed",
  targetOk("~/restore/x") == true and targetOk("~/extra/y") == true)

local ok1, err1 = targetOk("relative/restore")
check("target: a relative path is refused", ok1 == false and type(err1) == "string", tostring(err1))
local ok2, err2 = targetOk("")
check("target: an empty path is refused", ok2 == false, tostring(err2))
local ok3, err3 = targetOk(nil)
check("target: nil is refused", ok3 == false, tostring(err3))
local ok4, err4 = targetOk("/")
check("target: the filesystem root is refused", ok4 == false, tostring(err4))
local ok5, err5 = targetOk("/home/tester")
check("target: the home directory itself is refused", ok5 == false, tostring(err5))
local ok6, err6 = targetOk("/home/tester/")
check("target: the home directory with a trailing slash is refused", ok6 == false, tostring(err6))
local ok7, err7 = targetOk("/home/tester/docs")
check("target: a backup source is refused", ok7 == false and tostring(err7):find("backup source", 1, true) ~= nil,
  tostring(err7))
local ok8, err8 = targetOk("/home/tester/docs/sub/file")
check("target: a path inside a backup source is refused",
  ok8 == false and tostring(err8):find("backup source", 1, true) ~= nil, tostring(err8))
local ok9, err9 = targetOk("/etc/hosts")
check("target: a second backup source is refused too",
  ok9 == false and tostring(err9):find("backup source", 1, true) ~= nil, tostring(err9))
local ok10, err10 = targetOk("/home/tester/restore/../docs/x")
check("target: `..` cannot be used to escape into a backup source",
  ok10 == false and tostring(err10):find("backup source", 1, true) ~= nil, tostring(err10))
local ok11, err11 = targetOk("/home/tester/docs-archive")
check("target: a sibling sharing a prefix with a source is refused as outside the allow-list",
  ok11 == false and tostring(err11):find("must be inside", 1, true) ~= nil, tostring(err11))
local ok12, err12 = targetOk("/home/tester/restore-old/x")
check("target: a sibling of the staging root is refused", ok12 == false and tostring(err12):find("must be inside", 1, true) ~= nil,
  tostring(err12))
check("target: an unrelated path is refused", targetOk("/tmp/elsewhere") == false)
check("target: without a config nothing is allowed", restic.validRestoreTarget(nil, "/tmp/x") == false)

H.files["/home/tester/restore/occupied"] = "already a file"
local ok13, err13 = targetOk("/home/tester/restore/occupied")
check("target: a path that already exists as a non-directory is refused",
  ok13 == false and tostring(err13):find("not a directory", 1, true) ~= nil, tostring(err13))
local ok14 = targetOk("/home/tester/restore/brand-new")
check("target: a new directory under the staging root is allowed", ok14 == true)

-- ── parsers against real output ──────────────────────────────────────────────

local parsed = restic.parseSnapshots(SNAPSHOTS)
check("parseSnapshots: the real array decodes", #parsed == 2, #parsed)
check("parseSnapshots: an empty repository is an empty list", #restic.parseSnapshots(EMPTY_SNAPSHOTS) == 0)
check("parseSnapshots: garbage is an empty list, never nil",
  #restic.parseSnapshots("not json") == 0 and #restic.parseSnapshots(nil) == 0)

local row = restic.snapshotRow(parsed[1])
check("snapshotRow: id, shortId and time are carried",
  row.id == "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce" and row.shortId == "bcd441d2" and row.time == "2026-09-14T21:20:42.108154635+08:00")
check("snapshotRow: hostname, tags and paths are carried",
  row.hostname == "cachyos-x8664" and row.tags[1] == "noctalia" and row.paths[1] == "/tmp/rs-b-fixture/data",
  tostring(row.hostname))
check("snapshotRow: bounded summary fields",
  row.filesProcessed == 4004 and row.bytesProcessed == 200038893
    and row.dataAdded == 201491562,
  tostring(row.filesProcessed))

local stats = restic.parseStats(STATS)
check("parseStats: real stats object",
  stats ~= nil and stats.totalBytes == 350077824 and stats.totalFileCount == 8019
    and stats.snapshotsCount == 2,
  stats and tostring(stats.totalBytes))
check("parseStats: `check --json` output is not a stats payload", restic.parseStats(CHECK) == nil)
check("parseStats: a snapshot array is not a stats payload", restic.parseStats(SNAPSHOTS) == nil)
check("parseStats: garbage is nil", restic.parseStats("nope") == nil and restic.parseStats(nil) == nil)

local lsParsed = restic.parseLs(LS, 200)
check("parseLs: the snapshot record is skipped and every node counted", lsParsed.count == 5, lsParsed.count)
check("parseLs: entries are the nodes, in order", #lsParsed.entries == 5)
check("parseLs: nothing was truncated under the limit", lsParsed.truncated == false)
check("parseLs: a directory node carries no size", lsParsed.entries[1].type == "dir" and lsParsed.entries[1].size == nil,
  tostring(lsParsed.entries[1].type))
local lastEntry = lsParsed.entries[#lsParsed.entries]
check("parseLs: a file node keeps name, path and size",
  lastEntry.name == "blob1.bin" and lastEntry.type == "file" and lastEntry.size == 50000000
    and lastEntry.path == "/tmp/rs-b-fixture/data/big/blob1.bin", tostring(lastEntry.size))
local lsBounded = restic.parseLs(LS, 3)
check("parseLs: a limit bounds the entries and raises truncated",
  #lsBounded.entries == 3 and lsBounded.truncated == true and lsBounded.count == 5,
  tostring(#lsBounded.entries))
check("parseLs: the default limit keeps this snapshot intact", #restic.parseLs(LS).entries == 5)
check("parseLs: garbage yields no entries and count 0",
  #restic.parseLs("x").entries == 0 and restic.parseLs(nil).count == 0)

local diff = restic.parseDiff(DIFF, 200)
check("parseDiff: counts come from the real change records",
  diff ~= nil and diff.added == 0 and diff.removed == 3 and diff.changed == 1,
  diff and (diff.added .. "/" .. diff.removed .. "/" .. diff.changed))
check("parseDiff: the bounded path lists match the counts",
  #diff.addedPaths == 0 and #diff.removedPaths == 3
    and #diff.changedPaths == 1)
check("parseDiff: a changed path is named", diff.changedPaths[1]:find("blob1.bin", 1, true) ~= nil,
  diff.changedPaths[1])
check("parseDiff: a removed path is named", diff.removedPaths[1] == "/tmp/rs-b-fixture/data/")
local diffBounded = restic.parseDiff(DIFF, 2)
check("parseDiff: a limit bounds the path lists but not the counts",
  #diffBounded.removedPaths == 2 and diffBounded.removed == 3 and diffBounded.truncated == true)
local diffStats = restic.parseDiff(DIFF_STATISTICS_ONLY, 200)
check("parseDiff: falls back to the statistics record for an unchanged pair",
  diffStats ~= nil and diffStats.added == 0 and diffStats.removed == 0 and diffStats.changed == 1,
  diffStats and tostring(diffStats.changed))
check("parseDiff: garbage is nil", restic.parseDiff("nope") == nil and restic.parseDiff(nil) == nil)

local status = restic.lastStatusLine(STATUS)
check("lastStatusLine: the single .status line decodes",
  status ~= nil and status.total_files == 4004 and status.percent_done == 1,
  status and tostring(status.percent_done))
check("lastStatusLine: a torn trailing line falls back to the previous complete one",
  restic.lastStatusLine(STATUS .. '{"message_type":"sta').percent_done == 1)
check("lastStatusLine: garbage and nil are nil",
  restic.lastStatusLine("not json") == nil and restic.lastStatusLine(nil) == nil)
check("lastStatusLine: an empty file is nil", restic.lastStatusLine("") == nil)

local objects = restic.parseJsonLines(BACKUP .. "restic: a stray log line\n")
check("parseJsonLines: a malformed line is skipped", #objects == 5, #objects)
check("parseJsonLines: real status records survive", objects[1].message_type == "status"
  and objects[1].percent_done > 0.3 and objects[1].total_bytes == 200038893,
  tostring(objects[1].percent_done))
local summary = restic.lastSummary(objects)
check("lastSummary: the real summary record",
  summary ~= nil and summary.total_files_processed == 4004
    and summary.total_bytes_processed == 200038893 and summary.snapshot_id == "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce")
local progress = restic.lastStatus(objects)
check("lastStatus: the newest progress record",
  progress ~= nil and progress.percent_done == 1 and progress.files_done == 4004
    and progress.bytes_done == 200038893, progress and tostring(progress.files_done))

-- ── snapshot summary / staleness ─────────────────────────────────────────────

local rows = {}
for _, snapshot in ipairs(parsed) do
  table.insert(rows, restic.snapshotRow(snapshot))
end

local aggregate = restic.snapshotSummary(rows)
check("snapshotSummary: counts the rows", aggregate.count == 2, aggregate.count)
check("snapshotSummary: newestAt is the newest RFC3339 time in epoch seconds",
  aggregate.newestAt == 1789392043, tostring(aggregate.newestAt))
check("snapshotSummary: an empty list has no age",
  restic.snapshotSummary({}).count == 0 and restic.snapshotSummary({}).newestAt == nil)
check("snapshotSummary: nil input is safe", restic.snapshotSummary(nil).count == 0)
check("snapshotSummary: unreadable times are ignored, not guessed",
  restic.snapshotSummary({ { time = "yesterday" }, { time = nil }, {} }).newestAt == nil)
check("epochFromRfc3339: the real +08:00 timestamp", restic.epochFromRfc3339("2026-09-14T21:20:43.197304291+08:00") == 1789392043)
check("epochFromRfc3339: Z", restic.epochFromRfc3339("2026-09-14T13:20:43.197304291Z") == 1789392043)
check("epochFromRfc3339: sub-second digits are floored",
  restic.epochFromRfc3339("2026-09-14T13:20:43.999Z") == 1789392043)
check("epochFromRfc3339: the offset is applied arithmetically, not from the local zone",
  restic.epochFromRfc3339("2026-09-14T08:20:43-05:00") == 1789392043
    and restic.epochFromRfc3339("2026-09-14T13:20:43+00:00") == 1789392043)
check("epochFromRfc3339: a timestamp without an offset is refused, not guessed",
  restic.epochFromRfc3339("2026-09-14T21:20:43") == nil)
check("epochFromRfc3339: an already-numeric time passes through",
  restic.epochFromRfc3339("1789392043") == 1789392043)
check("epochFromRfc3339: garbage and nil are nil",
  restic.epochFromRfc3339("nope") == nil and restic.epochFromRfc3339(nil) == nil)

local filtered = restic.filterSnapshots(rows, nil)
check("filterSnapshots: no filter returns every row", #filtered == 2)
check("filterSnapshots: an empty filter returns every row", #restic.filterSnapshots(rows, {}) == 2)
check("filterSnapshots: host is an exact match",
  #restic.filterSnapshots(rows, { host = "cachyos-x8664" }) == 2
    and #restic.filterSnapshots(rows, { host = "cachyos" }) == 0)
check("filterSnapshots: a tag is a membership test",
  #restic.filterSnapshots(rows, { tag = "daily" }) == 2
    and #restic.filterSnapshots(rows, { tag = "DAILY" }) == 0)
check("filterSnapshots: text is a case-insensitive substring of the paths",
  #restic.filterSnapshots(rows, { text = "DATA2" }) == 1
    and restic.filterSnapshots(rows, { text = "DATA2" })[1].shortId == "e29a0067")
check("filterSnapshots: text also matches tags and host",
  #restic.filterSnapshots(rows, { text = "noctalia" }) == 2
    and #restic.filterSnapshots(rows, { text = "cachyos-x8664" }) == 2)
check("filterSnapshots: every supplied filter must match",
  #restic.filterSnapshots(rows, { host = "cachyos-x8664", tag = "daily", text = "data" }) == 2
    and #restic.filterSnapshots(rows, { host = "cachyos-x8664", tag = "weekly" }) == 0)
check("filterSnapshots: a plain substring, not a pattern",
  #restic.filterSnapshots(rows, { text = "data(2)" }) == 0)
check("filterSnapshots: rows with missing fields do not error",
  #restic.filterSnapshots({ { id = "abcd1234" } }, { text = "zzz" }) == 0
    and #restic.filterSnapshots({ { id = "abcd1234" } }, {}) == 1)
check("filterSnapshots: a non-table row list is an empty result", #restic.filterSnapshots(nil, {}) == 0)

-- ── forget preview ───────────────────────────────────────────────────────────

local groups = restic.parseObject(FORGET)
check("parseObject: forget --dry-run --json decodes to the group records",
  type(groups) == "table" and #groups == 2, type(groups))
local dry = restic.summariseForgetDry(groups, 50)
check("summariseForgetDry: keepCount across groups", dry.keepCount == 2, tostring(dry.keepCount))
check("summariseForgetDry: removeCount across groups", dry.removeCount == 4, tostring(dry.removeCount))
check("summariseForgetDry: the removed snapshots are listed, not just counted",
  #dry.remove == 4 and dry.truncated == false, tostring(#dry.remove))
check("summariseForgetDry: the first removed snapshot is named with id, shortId and time",
  dry.remove[1].id == "73fb9912e131a3c01dcbb5de82c185f1d1a8ee5b081c164c38b88fa9736e31a9" and dry.remove[1].shortId == "73fb9912"
    and dry.remove[1].time == "2026-09-14T21:23:15.596522479+08:00", tostring(dry.remove[1].shortId))
local dryBounded = restic.summariseForgetDry(groups, 2)
check("summariseForgetDry: the list is bounded but the count is not",
  #dryBounded.remove == 2 and dryBounded.removeCount == 4 and dryBounded.truncated == true,
  tostring(#dryBounded.remove))
check("summariseForgetDry: a single group record works",
  restic.summariseForgetDry(groups[1], 50).removeCount == 4)
check("summariseForgetDry: a group whose remove is null contributes nothing",
  restic.summariseForgetDry(groups[2], 50).removeCount == 0
    and restic.summariseForgetDry(groups[2], 50).keepCount == 1)
check("summariseForgetDry: an empty payload is zero, not an error",
  restic.summariseForgetDry({}, 50).removeCount == 0 and restic.summariseForgetDry({}, 50).keepCount == 0)
check("summariseForgetDry: non-table input is nil", restic.summariseForgetDry("x") == nil)

-- The shape the SERVICE passes is not the shape above. The service reads the job log with
-- parseJsonLines (one decoded value per LINE) while these checks call parseObject (one decode of
-- the whole text), and restic writes the forget array on a single line. So production passes
-- { array } and the checks above never saw it -- which is how a panel came to report
-- "Would keep 0, remove 0" for a repository holding 22 snapshots. Assert the real shape.
local wrapped = { restic.parseObject(FORGET) }
local dryWrapped = restic.summariseForgetDry(wrapped, 50)
check("summariseForgetDry: the parseJsonLines wrapper is unwrapped, not read as one group",
  dryWrapped ~= nil and dryWrapped.keepCount == 2 and dryWrapped.removeCount == 4,
  dryWrapped == nil and "nil" or (tostring(dryWrapped.keepCount) .. "/" .. tostring(dryWrapped.removeCount)))
check("summariseForgetDry: a wrapped empty payload is still a zero",
  restic.summariseForgetDry({ {} }, 50) ~= nil
    and restic.summariseForgetDry({ {} }, 50).keepCount == 0)
check("summariseForgetDry: an unreadable non-empty payload is nil, never a false zero",
  restic.summariseForgetDry({ { error = "repository is already locked" } }, 50) == nil)
check("summariseForgetDry: a wrapped array is still bounded like a bare one",
  restic.summariseForgetDry(wrapped, 2).removeCount == 4
    and #restic.summariseForgetDry(wrapped, 2).remove == 2)

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
