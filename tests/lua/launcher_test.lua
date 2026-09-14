--!nonstrict
-- Launcher-provider assertions for the /snap entry (Restic Snapshots 0.3.0).
-- Run from the repo root:  lua5.4 tests/lua/launcher_test.lua
--
-- Drives the REAL launcher.luau through tests/lua/harness.lua: the harness's launcher stub records
-- what onQuery published (H.launcherQuery / H.launcherResults), H.stateValues seeds the published
-- KEY_SNAPSHOTS state, and H.commands records the IPC the entry spawns.
--
-- Two harness stubs are too thin for this provider and are replaced here, each with the check that
-- depends on it named in the comment: noctalia.formatTime (a constant "12:00", so it cannot show
-- which instant was passed) and noctalia.fuzzyScore (a case-SENSITIVE substring test, where the
-- host's matcher is a case-insensitive subsequence scorer).

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.install("plugin/restic-snapshots")

local SNAPSHOTS_KEY = "restic_snapshots"
local SERVICE = "carlocamacho/restic-snapshots:service"
local PANEL = "carlocamacho/restic-snapshots:browser"
local CATEGORY = "Snapshots"
local ACTION_BACKUP = "action:backup"
local ACTION_CHECK = "action:check"
local ACTION_PANEL = "action:panel"

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

-- ── the real translation catalogue, as the host would render it ──────────────

local CATALOGUE = {}
do
  local handle = io.open("plugin/restic-snapshots/translations/en.json", "rb")
  if handle ~= nil then
    local text = handle:read("*a")
    handle:close()
    for key, value in (text or ""):gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
      CATALOGUE[key] = value
    end
  end
end

local TR_CALLS = {}
noctalia.tr = function(key, subst)
  table.insert(TR_CALLS, key)
  local template = CATALOGUE[key]
  if template == nil then
    return key
  end
  if type(subst) ~= "table" then
    return template
  end
  return (template:gsub("{(%w+)}", function(name)
    local value = subst[name]
    if value == nil then
      return "{" .. name .. "}"
    end
    return tostring(value)
  end))
end
noctalia.trp = noctalia.tr

-- Deterministic local time from the epoch the entry passes. UTC-formatted so the expectation does
-- not depend on the box's timezone; the entry's own pattern argument is asserted separately.
local TIME_CALLS = {}
noctalia.formatTime = function(pattern, seconds)
  table.insert(TIME_CALLS, { pattern = pattern, seconds = seconds })
  if seconds == nil then
    return os.date("!%H:%M")
  end
  return os.date("!%H:%M", tonumber(seconds) or 0)
end

-- The harness's togglePanel does nothing; record which panel (if any) was opened.
local panelOpened = nil
noctalia.togglePanel = function(id)
  panelOpened = id
end

local harnessFuzzy = noctalia.fuzzyScore

-- ── fixtures ─────────────────────────────────────────────────────────────────

local EPOCH_NEWEST = 1789392042  -- 2026-09-14T21:20:42+08:00
local EPOCH_MIDDLE = 1789387200  -- 2026-09-14T20:00:00+08:00
local EPOCH_OLDEST = 1789264800  -- 2026-09-13T10:00:00+08:00
local EPOCH_12 = 1788231600      -- 2026-09-01T11:00:00+08:00

local function row(shortId, time, hostname, tags, files, bytes)
  return {
    id = shortId .. string.rep("a", 48),
    shortId = shortId,
    time = time,
    hostname = hostname,
    tags = tags,
    paths = { "/home/ian/cachyos-dotfiles" },
    filesProcessed = files,
    bytesProcessed = bytes,
  }
end

local NEWEST = row("aaa11111", "2026-09-14T21:20:42+08:00", "cachyos", { "noctalia" }, 1234, 5242880)
local MIDDLE = row("bcd44d1a", "2026-09-14T20:00:00+08:00", "nas", { "noctalia", "media" }, 10, 2048)
local OLDEST = row("ccc33333", "2026-09-13T10:00:00+08:00", "cachyos", { "daily" }, 0, nil)

local function seed(rows)
  H.stateValues[SNAPSHOTS_KEY] = { schema = 2, updatedAt = 1788874602, snapshots = rows }
end

local function results()
  return H.launcherResults or {}
end

local function resultIds()
  local ids = {}
  for _, result in ipairs(results()) do
    table.insert(ids, tostring(result.id))
  end
  return ids
end

local function findResult(id)
  for _, result in ipairs(results()) do
    if result.id == id then
      return result
    end
  end
  return nil
end

local function snapshotResults()
  local out = {}
  for _, result in ipairs(results()) do
    if tostring(result.id):sub(1, 7) ~= "action:" then
      table.insert(out, result)
    end
  end
  return out
end

local function actionResults()
  local out = {}
  for _, result in ipairs(results()) do
    if tostring(result.id):sub(1, 7) == "action:" then
      table.insert(out, result)
    end
  end
  return out
end

local function lastArgv()
  return H.commands[#H.commands]
end

local function argvText()
  return table.concat(lastArgv() or {}, " ")
end

H.load("launcher.luau")

-- ── an empty query: the snapshots and the three actions ──────────────────────

seed({ NEWEST, MIDDLE, OLDEST })
onQuery("")

check("empty query publishes the snapshots and the actions", #results() == 6, tostring(#results()))
check("the published query echoes the text verbatim", H.launcherQuery == "", tostring(H.launcherQuery))
check("snapshots come newest first", table.concat(resultIds(), ",") == table.concat({
  NEWEST.id, MIDDLE.id, OLDEST.id, ACTION_BACKUP, ACTION_CHECK, ACTION_PANEL,
}, ","), table.concat(resultIds(), ","))

local newest = findResult(NEWEST.id)
local middle = findResult(MIDDLE.id)
local oldest = findResult(OLDEST.id)

check("a snapshot title is the short id plus its local time",
  newest ~= nil and newest.title == "aaa11111 · " .. os.date("!%H:%M", EPOCH_NEWEST),
  newest ~= nil and newest.title)
check("the time is the snapshot's OWN instant, not now",
  newest ~= nil and newest.title:find(os.date("!%H:%M", EPOCH_OLDEST), 1, true) == nil
    and middle ~= nil and middle.title == "bcd44d1a · " .. os.date("!%H:%M", EPOCH_MIDDLE),
  middle ~= nil and middle.title)
check("the entry asks the host for the clock time", TIME_CALLS[1] ~= nil and TIME_CALLS[1].pattern == "%H:%M"
  and TIME_CALLS[1].seconds == EPOCH_NEWEST, TIME_CALLS[1] ~= nil and tostring(TIME_CALLS[1].seconds))
check("a snapshot subtitle uses the frozen key's shape",
  newest ~= nil and newest.subtitle == "cachyos · 1234 files · 5.0 MiB",
  newest ~= nil and newest.subtitle)
check("a snapshot with no size falls back to the em dash",
  oldest ~= nil and oldest.subtitle == "cachyos · 0 files · —",
  oldest ~= nil and oldest.subtitle)
check("the frozen launcher.* keys are the ones requested",
  (function()
    local want = {
      ["launcher.snapshot.subtitle"] = false,
      ["launcher.action.backup_now"] = false,
      ["launcher.action.check"] = false,
      ["launcher.action.open_panel"] = false,
    }
    for _, key in ipairs(TR_CALLS) do
      if want[key] ~= nil then
        want[key] = true
      end
    end
    for _, seen in pairs(want) do
      if seen ~= true then
        return false
      end
    end
    return true
  end)(), table.concat(TR_CALLS, ","))
check("action titles are the real translations",
  findResult(ACTION_BACKUP) ~= nil and findResult(ACTION_BACKUP).title == "Back up now"
    and findResult(ACTION_CHECK) ~= nil and findResult(ACTION_CHECK).title == "Check repository"
    and findResult(ACTION_PANEL) ~= nil and findResult(ACTION_PANEL).title == "Open Restic Snapshots",
  findResult(ACTION_BACKUP) ~= nil and findResult(ACTION_BACKUP).title)

-- ── every result carries the declared category and a glyph ───────────────────

local badCategory, badGlyph, badTitle, leakedKey = {}, {}, {}, {}
for _, result in ipairs(results()) do
  if result.category ~= CATEGORY then
    table.insert(badCategory, tostring(result.id) .. "=" .. tostring(result.category))
  end
  if type(result.glyph) ~= "string" or result.glyph == "" then
    table.insert(badGlyph, tostring(result.id))
  end
  if type(result.title) ~= "string" or result.title == "" then
    table.insert(badTitle, tostring(result.id))
  end
  if type(result.title) == "string" and result.title:find("launcher.", 1, true) ~= nil then
    table.insert(leakedKey, tostring(result.id))
  end
  if type(result.subtitle) == "string" and result.subtitle:find("launcher.", 1, true) ~= nil then
    table.insert(leakedKey, tostring(result.id))
  end
end

check("every result carries the declared category label", #badCategory == 0, table.concat(badCategory, ","))
check("every result carries a glyph", #badGlyph == 0, table.concat(badGlyph, ","))
check("every result carries a title", #badTitle == 0, table.concat(badTitle, ","))
check("no raw translation key leaks into a result", #leakedKey == 0, table.concat(leakedKey, ","))

local glyphs = {}
for _, result in ipairs(results()) do
  glyphs[tostring(result.glyph)] = true
end
local actionGlyphs = {}
for _, result in ipairs(actionResults()) do
  actionGlyphs[tostring(result.glyph)] = true
end
local function countKeys(table_)
  local count = 0
  for _ in pairs(table_) do
    count = count + 1
  end
  return count
end
check("snapshot rows use the archive glyph", newest ~= nil and newest.glyph == "archive",
  newest ~= nil and tostring(newest.glyph))
check("the three action rows have distinct glyphs",
  countKeys(actionGlyphs) == 3 and countKeys(glyphs) >= 3,
  "action glyphs: " .. tostring(countKeys(actionGlyphs)) .. ", all glyphs: " .. tostring(countKeys(glyphs)))

-- The category label is compared against the manifest verbatim by the host, so guard the literal.
do
  local label = nil
  local handle = io.open("plugin/restic-snapshots/plugin.toml", "rb")
  if handle ~= nil then
    local text = handle:read("*a")
    handle:close()
    local at = text:find("%[%[launcher_provider.category%]%]")
    if at ~= nil then
      label = text:sub(at):match('label%s*=%s*"([^"]+)"')
    end
  end
  check("the category matches plugin.toml's declared label", label == CATEGORY, tostring(label))
end

-- ── a query narrows the list ─────────────────────────────────────────────────

seed({ NEWEST, MIDDLE, OLDEST })

onQuery("bcd44d1a")
check("a short-id query narrows to one snapshot", #results() == 1 and results()[1].id == MIDDLE.id,
  table.concat(resultIds(), ","))
check("the short-id query is echoed", H.launcherQuery == "bcd44d1a", tostring(H.launcherQuery))
check("a matched row is scored so the host can rank it", results()[1].score ~= nil,
  tostring(results()[1].score))

onQuery("nas")
check("a host query narrows to that host's snapshot", #results() == 1 and results()[1].id == MIDDLE.id,
  table.concat(resultIds(), ","))

onQuery("media")
check("a tag query narrows to the tagged snapshot", #results() == 1 and results()[1].id == MIDDLE.id,
  table.concat(resultIds(), ","))

onQuery(os.date("!%H:%M", EPOCH_NEWEST))
check("a formatted-time query narrows to that snapshot",
  #results() == 1 and results()[1].id == NEWEST.id, table.concat(resultIds(), ","))

onQuery("CACHYOS")
check("matching is case-insensitive", #results() == 2, table.concat(resultIds(), ","))

onQuery("back")
check("a common action prefix keeps the backup row",
  #results() == 1 and results()[1].id == ACTION_BACKUP, table.concat(resultIds(), ","))

onQuery("open restic")
check("a multi-word action prefix keeps the panel row",
  #results() == 1 and results()[1].id == ACTION_PANEL, table.concat(resultIds(), ","))

-- ── the fuzzy path ───────────────────────────────────────────────────────────
-- The harness stub is a case-sensitive "contains" test, so this section installs a matcher with the
-- host's semantics (case-insensitive subsequence) and then puts the stub back to prove which path
-- did the work.

local function subsequence(pattern, text)
  local haystack = string.lower(tostring(text))
  local needle = string.lower(tostring(pattern))
  local from = 1
  for index = 1, #needle do
    local char = string.char(string.byte(needle, index))
    local found = haystack:find(char, from, true)
    if found == nil then
      return nil
    end
    from = found + 1
  end
  return 1
end

seed({ NEWEST, MIDDLE, OLDEST })
noctalia.fuzzyScore = subsequence

onQuery("cyos")
check("a fuzzy (non-substring) host query still finds the rows",
  #results() == 2 and findResult(NEWEST.id) ~= nil and findResult(OLDEST.id) ~= nil,
  table.concat(resultIds(), ","))

onQuery("bdd")
check("a fuzzy short-id query still finds the row",
  #results() == 1 and results()[1].id == MIDDLE.id, table.concat(resultIds(), ","))

noctalia.fuzzyScore = harnessFuzzy
onQuery("bdd")
check("the same short-id query matches nothing without the fuzzy path", #results() == 0,
  table.concat(resultIds(), ","))
onQuery("cyos")
check("the same host query matches nothing without the fuzzy path", #results() == 0,
  table.concat(resultIds(), ","))

-- ── a query that matches nothing ─────────────────────────────────────────────

seed({ NEWEST, MIDDLE, OLDEST })
onQuery("zzzznothing")
check("an unmatched query publishes an empty list without crashing", #results() == 0,
  table.concat(resultIds(), ","))
check("the unmatched query is still echoed", H.launcherQuery == "zzzznothing", tostring(H.launcherQuery))

onQuery("back")
check("backspacing to a prefix brings an action back",
  #results() == 1 and results()[1].id == ACTION_BACKUP, table.concat(resultIds(), ","))

onQuery()
check("a nil query is treated as empty and republishes everything", #results() == 6,
  tostring(#results()))

-- ── more than 8 snapshots is bounded ─────────────────────────────────────────

local function shortIdFor(index)
  return string.format("%08x", index * 17)
end

local many = {}
for index = 1, 12 do
  local rowTime = string.format("2026-09-01T%02d:00:00+08:00", index - 1)
  many[index] = row(shortIdFor(index), rowTime, "cachyos", { "noctalia" }, index, index * 1024)
end

-- Deliberately out of order: the entry must publish by time, not by the state's insertion order.
seed({ many[1], many[5], many[12], many[3], many[9], many[2], many[11], many[4], many[7], many[10], many[6], many[8] })
onQuery("")

local expected = {}
for index = 12, 5, -1 do
  table.insert(expected, many[index].id)
end
local published = {}
for _, result in ipairs(snapshotResults()) do
  table.insert(published, tostring(result.id))
end
check("at most 8 snapshots are published", #published == 8, tostring(#published))
check("the bound keeps the newest 8, newest first", table.concat(published, ",") == table.concat(expected, ","),
  table.concat(published, ","))
check("the actions follow the bounded snapshot list",
  #results() == 11 and results()[9].id == ACTION_BACKUP and results()[11].id == ACTION_PANEL,
  table.concat(resultIds(), ","))
check("the newest of the 12 keeps the last row's instant",
  H.launcherResults[1].title == shortIdFor(12) .. " · " .. os.date("!%H:%M", EPOCH_12),
  H.launcherResults[1].title)

-- ── absent or junk state ─────────────────────────────────────────────────────

H.stateValues[SNAPSHOTS_KEY] = nil
onQuery("")
check("an unpublished state still offers the three actions", #results() == 3
  and results()[1].id == ACTION_BACKUP and results()[3].id == ACTION_PANEL, table.concat(resultIds(), ","))

H.stateValues[SNAPSHOTS_KEY] = { schema = 2, snapshots = { "junk", {}, NEWEST } }
onQuery("")
check("junk rows are skipped rather than published", #snapshotResults() == 1
  and snapshotResults()[1].id == NEWEST.id, table.concat(resultIds(), ","))

H.stateValues[SNAPSHOTS_KEY] = { schema = 2 }
onQuery("")
check("a state without a snapshots list does not crash", #results() == 3, tostring(#results()))

-- ── the provider reads published state, it never writes ──────────────────────

seed({ NEWEST, MIDDLE, OLDEST })
H.commands = {}
H.published = {}
onQuery("")
check("a query spawns no process", #H.commands == 0, argvText())
check("a query writes no state", countKeys(H.published) == 0, tostring(countKeys(H.published)))

-- ── activation ───────────────────────────────────────────────────────────────

seed({ NEWEST, MIDDLE, OLDEST })
onQuery("")

H.commands = {}
panelOpened = nil
onActivate(NEWEST.id)

check("activating a snapshot spawns exactly one IPC", #H.commands == 1, tostring(#H.commands))
check("the IPC is the panel's argv shape, with the payload as one element",
  #(lastArgv() or {}) == 7 and lastArgv()[1] == "noctalia" and lastArgv()[2] == "msg"
    and lastArgv()[3] == "plugin" and lastArgv()[4] == SERVICE and lastArgv()[5] == "all"
    and lastArgv()[6] == "ls",
  argvText())
check("the ls payload names the full snapshot id",
  type(lastArgv()[7]) == "string" and lastArgv()[7]:find(NEWEST.id, 1, true) ~= nil
    and lastArgv()[7]:find('"snapshot"', 1, true) ~= nil,
  tostring(lastArgv()[7]))
check("the payload carries no shell string, just JSON", type(lastArgv()[7]) == "string"
  and lastArgv()[7]:sub(1, 1) == "{" and lastArgv()[7]:sub(-1) == "}", tostring(lastArgv()[7]))
check("activating a snapshot opens the panel", panelOpened == PANEL, tostring(panelOpened))

H.commands = {}
panelOpened = nil
onActivate(ACTION_BACKUP)
check("the backup action sends the backup-now event",
  #H.commands == 1 and lastArgv()[6] == "backup-now" and #lastArgv() == 6
    and lastArgv()[4] == SERVICE,
  argvText())
check("the backup action does not open the panel", panelOpened == nil, tostring(panelOpened))

H.commands = {}
panelOpened = nil
onActivate(ACTION_CHECK)
check("the check action sends the check event",
  #H.commands == 1 and lastArgv()[6] == "check" and #lastArgv() == 6, argvText())
check("the check action does not open the panel", panelOpened == nil, tostring(panelOpened))

H.commands = {}
panelOpened = nil
onActivate(ACTION_PANEL)
check("the panel action spawns nothing", #H.commands == 0, argvText())
check("the panel action opens the panel", panelOpened == PANEL, tostring(panelOpened))

H.commands = {}
panelOpened = nil
onActivate("")
onActivate(nil)
check("an empty id is ignored rather than sent to the service",
  #H.commands == 0 and panelOpened == nil, argvText())

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
