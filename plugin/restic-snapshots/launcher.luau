--!nonstrict
-- Launcher provider (manifest prefix /snap): the recent snapshots and the three actions this plugin
-- is actually driven by, so the plugin is reachable from the keyboard and not only from the panel.
--
-- [0.3.0] docs/CONTRACTS-0.3.0.md 5.5. Every query reads the published KEY_SNAPSHOTS state fresh:
-- this entry can be loaded before the service has published anything, so a cached copy would only
-- ever go stale. The only process it ever runs is the same `noctalia msg plugin` IPC the panel
-- sends -- argv vector, JSON payload as ONE argument, never a shell string -- and it makes no
-- network call at all.
--
-- Filtering -- the one part of 5.5 this workstream was left to decide, so the rule is written down:
--   * A snapshot matches when the query is a case-insensitive substring of its short id, its host,
--     one of its tags or its formatted time; failing that, when the host's fuzzy matcher
--     (`noctalia.fuzzyScore`) accepts the same field. Fuzzy is the nicer behaviour for a pasted-ish
--     short id or a hostname -- "cds" still finds a cachyos row that "contains" alone would miss --
--     so the best field score is published as the result's `score`, which floats a closer match up
--     while equally-scored rows keep the recency order.
--   * The three action rows are filtered by the same rule against their (translated) label: "back",
--     "check" and "open" keep them visible, an unrelated query drops them, and a query that matches
--     nothing publishes an EMPTY list -- the launcher then draws its own "no results" placeholder,
--     no crash, and backspacing restores the actions immediately. Action ids are not searchable
--     text; only the label is.
--   * Results are published newest snapshot first, then the fixed action rows, in the order below.

local restic = require("./lib/restic.luau")
local state = require("./lib/state.luau")

local SERVICE = "carlocamacho/restic-snapshots:service"
local PANEL = "carlocamacho/restic-snapshots:browser"

-- The category label must stay byte-identical to the [[launcher_provider.category]] label in
-- plugin.toml -- the launcher's filter bar narrows by comparing the two -- so it is the one string
-- in this file that must NOT go through noctalia.tr. (translations/en.json's
-- launcher.category.snapshots spells it "Restic snapshots"; passing that would make the category
-- filter drop every row. Reported to the lead rather than changed here.)
local CATEGORY = "Snapshots"

-- "up to about 8" (contract): roughly one launcher page, and the walk stays linear in records.
local MAX_SNAPSHOTS = 8

-- Action ids. A restic snapshot id is hex, so it can never contain ':' -- that is what lets
-- onActivate tell an action row from a snapshot row, and is why the two id spaces cannot collide.
local ACTION_BACKUP = "action:backup"
local ACTION_CHECK = "action:check"
local ACTION_PANEL = "action:panel"

-- The fixed action rows, in publication order. `event` is the service event to send (nil for the
-- panel-only row), `panel = true` opens the panel. The icon names are string literals on purpose:
-- tests/test_source_invariants.py and /tmp/glyph_audit.py only audit literal assignments, so a
-- constant would slip past both and a bad name would render as nothing at runtime.
local ACTIONS = {
  {
    id = ACTION_BACKUP,
    titleKey = "launcher.action.backup_now",
    glyph = "archive",
    event = state.EVENT_BACKUP,
  },
  {
    id = ACTION_CHECK,
    titleKey = "launcher.action.check",
    glyph = "shield-check",
    event = state.EVENT_CHECK,
  },
  {
    id = ACTION_PANEL,
    titleKey = "launcher.action.open_panel",
    glyph = "layout-dashboard",
    panel = true,
  },
}

-- ── helpers ──────────────────────────────────────────────────────────────────
-- `send` and `encode` are the panel's, verbatim: the IPC shape (argv table, JSON payload as one
-- element) is the frozen part, not just the event name.

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function send(event, payload)
  local argv = { "noctalia", "msg", "plugin", SERVICE, "all", event }
  if payload ~= nil then
    table.insert(argv, payload)
  end
  return noctalia.runAsync(argv, nil, 10000)
end

local function encode(value)
  local text = noctalia.json.encode(value)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  return text
end

-- Rows from the published state, newest first. A row with neither id nor short id is skipped:
-- it could not be activated, so publishing it would advertise a result that does nothing.
local function allRows()
  local rows = {}
  local published = noctalia.state.get(state.KEY_SNAPSHOTS)
  if type(published) ~= "table" or type(published.snapshots) ~= "table" then
    return rows
  end
  for _, row in ipairs(published.snapshots) do
    if type(row) == "table" and (row.id ~= nil or row.shortId ~= nil) then
      table.insert(rows, row)
    end
  end
  -- An unreadable time sorts as the oldest, which keeps the order total: table.sort may raise on an
  -- inconsistent comparator. Same reasoning (and same shape) as lib/restic's sorted rows.
  table.sort(rows, function(a, b)
    return (restic.epochFromRfc3339(a.time) or 0) > (restic.epochFromRfc3339(b.time) or 0)
  end)
  return rows
end

-- The snapshot's own instant as local clock time. "%H:%M" is the strftime-compatible token style
-- the shell's clock settings use (noctalia.timeFormat() defaults to "{:%H:%M}").
local function timeLabel(row)
  local at = restic.epochFromRfc3339(row.time)
  if at == nil then
    return tostring(row.time or "")
  end
  return tostring(noctalia.formatTime("%H:%M", at))
end

local function titleFor(row)
  return tostring(row.shortId or row.id) .. " · " .. timeLabel(row)
end

-- The searchable text of a snapshot: exactly the fields the contract names.
local function searchFields(row)
  local fields = { tostring(row.shortId or row.id or ""), tostring(row.hostname or ""), timeLabel(row) }
  if type(row.tags) == "table" then
    for _, tag in ipairs(row.tags) do
      table.insert(fields, tostring(tag))
    end
  end
  return fields
end

-- Case-insensitive substring first ("contains it" is what the contract asks for, and it is exact
-- for a pasted short id), then the host's matcher, which is case-insensitive and order-tolerant.
-- Either way the caller gets a number or nil. Every walk here is over a short field, never bytes.
local function fieldScore(query, value)
  if value == nil or value == "" then
    return nil
  end
  if string.find(string.lower(value), string.lower(query), 1, true) ~= nil then
    return 1
  end
  local score = noctalia.fuzzyScore(query, value)
  if type(score) == "number" then
    return score
  end
  return nil
end

local function matchScore(query, fields)
  local best = nil
  for _, value in ipairs(fields) do
    local score = fieldScore(query, value)
    if score ~= nil and (best == nil or score > best) then
      best = score
    end
  end
  return best
end

local function snapshotResult(row, score)
  local result = {
    id = tostring(row.id or row.shortId),
    title = titleFor(row),
    subtitle = tr("launcher.snapshot.subtitle", {
      host = tostring(row.hostname or "?"),
      files = tostring(row.filesProcessed or 0),
      size = restic.humanBytes(row.bytesProcessed),
    }),
    glyph = "archive",
    category = CATEGORY,
  }
  if score ~= nil then
    result.score = score
  end
  return result
end

local function actionResults(query)
  local results = {}
  for _, action in ipairs(ACTIONS) do
    local label = tostring(tr(action.titleKey))
    if query == "" or matchScore(query, { label }) ~= nil then
      table.insert(results, {
        id = action.id,
        title = label,
        glyph = action.glyph,
        category = CATEGORY,
      })
    end
  end
  return results
end

local function actionFor(id)
  for _, action in ipairs(ACTIONS) do
    if action.id == id then
      return action
    end
  end
  return nil
end

-- ── entry points ─────────────────────────────────────────────────────────────

function onQuery(text)
  local query = tostring(text or "")
  local results = {}
  local shown = 0
  for _, row in ipairs(allRows()) do
    if shown >= MAX_SNAPSHOTS then
      break
    end
    local score = nil
    if query ~= "" then
      score = matchScore(query, searchFields(row))
    end
    if query == "" or score ~= nil then
      shown = shown + 1
      table.insert(results, snapshotResult(row, score))
    end
  end
  for _, result in ipairs(actionResults(query)) do
    table.insert(results, result)
  end
  -- `text` is echoed verbatim: the host maps a late result set back to the query it answers.
  launcher.setResults(text or "", results)
end

-- Nothing beyond what the panel already does is validated here: the panel's own "files" action
-- sends the same {"snapshot": <id>} payload and the service validates ids with
-- restic.validSnapshotId before restic ever sees them.
function onActivate(id)
  local key = tostring(id or "")
  if key == "" then
    return
  end
  local action = actionFor(key)
  if action ~= nil then
    if action.event ~= nil then
      send(action.event)
    end
    if action.panel == true then
      noctalia.togglePanel(PANEL)
    end
    return
  end
  -- A snapshot row: publish its file listing for the panel, then open the panel on it.
  send(state.EVENT_LS, encode({ snapshot = key }))
  noctalia.togglePanel(PANEL)
end
