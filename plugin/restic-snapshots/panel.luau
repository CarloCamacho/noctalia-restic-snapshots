--!nonstrict
-- Snapshot browser, manual run, dry-run-gated retention, and the last job's log.
--
-- [0.2.0] Four tabs (Snapshots / Run / Retention / Log). Both destructive flows are two-step and
-- both steps live in `ui_state`, which is cleared whenever the tab changes, so a confirmation
-- left over from another tab can never be clicked. Restore previews before it confirms: the
-- one-click restore was the review finding that produced 0.2.0.
--
-- [0.3.0] The Run tab renders the two results the service had been publishing invisibly -- the last
-- integrity check (`status.checks`) and the last restore verification (`status.verify`, with its
-- counts, the service's own detail sentence and a "Verify restore" button sending EVENT_VERIFY) --
-- the diff lists the changed paths instead of only counting them, and "this host only" reads the
-- real hostname from /etc/hostname instead of inferring it from the snapshot list.
--
-- Invariants this file keeps (see docs/CONTRACTS-0.2.0.md 4.8):
--   * `status.repository` is ALREADY redacted by the service -- the panel never redacts it again.
--   * a retention preview is NOT re-summed: keepCount / removeCount / remove come straight from
--     restic.summariseForgetDry via the service, the panel only renders them.
--   * the panel does not grade results: a verification's verdict comes from its published counts
--     (`lastOk` alone would call a run that compared nothing a success) and the check's result from
--     `lastOk` plus `numErrors`.
--   * every user-visible string goes through noctalia.tr with a key from translations/en.json.

local restic = require("./lib/restic.luau")
local schedule = require("./lib/schedule.luau")
local state = require("./lib/state.luau")

local SERVICE = "carlocamacho/restic-snapshots:service"

local status = state.migrate(noctalia.state.get(state.KEY_STATUS))
local snapshots = noctalia.state.get(state.KEY_SNAPSHOTS)
local job = noctalia.state.get(state.KEY_JOB)         -- forget-dry (retention) / restore-dry
local joblog = noctalia.state.get(state.KEY_JOBLOG)
local stats = noctalia.state.get(state.KEY_STATS)
local files = noctalia.state.get(state.KEY_FILES)
local diff = noctalia.state.get(state.KEY_DIFF)

-- Display bounds. The service bounds its own payloads; these caps keep one huge snapshot list or
-- file listing from stalling a re-render.
local MAX_ROWS = 60
local MAX_FILE_ROWS = 12
local MAX_REMOVE_ROWS = 20
local MAX_DIFF_ROWS = 12

local ui_state = {
  tab = "snapshots",
  filterIndex = 0,       -- 0 all snapshots, 1 this host only, 2 tagged <configured tag>
  query = "",
  sort = "newest",       -- newest | oldest
  confirmPrune = false,  -- retention second step
  restoreDraft = nil,    -- { snapshot = <id> } restore confirm, revealed only after a preview
  forgetDraft = nil,     -- { snapshot = <id> } forget-one confirm
  message = nil,
  -- [0.4.0] The ONE snapshot row whose action sheet / details card is expanded, and the Log tab's
  -- view mode. Cleared with every other transient step (showTab / onOpen); `logRaw` is a view
  -- preference rather than a pending action, so a tab switch leaves it alone.
  openRow = nil,         -- { id = <snapshot id>, sheet = bool, details = bool }
  logRaw = false,        -- Log tab: false = the typed display lines, true = the service's raw lines
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nowSec()
  return math.floor(noctalia.nowMs() / 1000)
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

local function settings()
  return {
    repository = noctalia.getConfig("repository"),
    password_file = noctalia.getConfig("password_file"),
    env_file = noctalia.getConfig("env_file"),
    backup_paths = noctalia.getConfig("backup_paths"),
    backup_tags = noctalia.getConfig("backup_tags"),
    exclude_file = noctalia.getConfig("exclude_file"),
    mode = noctalia.getConfig("mode"),
    interval_minutes = noctalia.getConfig("interval_minutes"),
    job_timeout_minutes = noctalia.getConfig("job_timeout_minutes"),
    check_interval_hours = noctalia.getConfig("check_interval_hours"),
    stale_after_hours = noctalia.getConfig("stale_after_hours"),
    keep_last = noctalia.getConfig("keep_last"),
    keep_daily = noctalia.getConfig("keep_daily"),
    keep_weekly = noctalia.getConfig("keep_weekly"),
    keep_monthly = noctalia.getConfig("keep_monthly"),
    restore_target = noctalia.getConfig("restore_target"),
    restore_allow_roots = noctalia.getConfig("restore_allow_roots"),
    check_subset = noctalia.getConfig("check_subset"),
    restic_bin = noctalia.getConfig("restic_bin"),
  }
end

local function config()
  return restic.config(settings())
end

-- "5m ago" / "never". The shared key covers the panel and the widget tooltip.
local function agoLabel(at)
  if at == nil then
    return tr("panel.label.never")
  end
  return tr("panel.label.ago", { age = restic.ageLabel(nowSec() - at) })
end

-- ── snapshots: rows, filtering, ordering ─────────────────────────────────────

local function allRows()
  if type(snapshots) ~= "table" or type(snapshots.snapshots) ~= "table" then
    return {}
  end
  return snapshots.snapshots
end

local function configuredTag()
  local tags = noctalia.getConfig("backup_tags")
  if type(tags) == "table" and type(tags[1]) == "string" then
    return tags[1]
  end
  return ""
end

local function hasTag(row, tag)
  if tag == "" or type(row.tags) ~= "table" then
    return false
  end
  for _, value in ipairs(row.tags) do
    if tostring(value) == tag then
      return true
    end
  end
  return false
end

-- The real local hostname, from /etc/hostname (trimmed). The host names its own machine, so this is
-- exact; there is no inference to be wrong. No cache: the file is a few bytes, the panel renders on
-- user action and on state publishes (not on a timer), and a cached value could outlive a rename.
local function readLocalHostname()
  local text = noctalia.readFile("/etc/hostname")
  if type(text) ~= "string" then
    return nil
  end
  -- Trimmed with two whole-string gsubs, never a per-character walk (the host runs callbacks under a
  -- CPU budget).
  local trimmed = (text:gsub("^%s+", ""):gsub("%s+$", ""))
  if trimmed == "" then
    return nil
  end
  return trimmed
end

-- "This host only" used to be inferred, because the status shape deliberately carries no hostname
-- (the service publishes display fields only) and this plugin's snapshots were assumed to be exactly
-- the ones carrying the configured backup tag. That inference was NOT enough: restic records the
-- hostname of the machine that *made* the snapshot, and one repository can hold snapshots from
-- several machines -- including one where the same tag is configured -- so the newest tagged row is
-- not necessarily this host. The filter then silently showed / hid the wrong host's snapshots with
-- nothing on screen to reveal it. /etc/hostname is the machine's own answer, so read it first and
-- keep the inference only as the fallback for when the file is unreadable (a container, a chroot).
local function inferredHostname(list, tag)
  for _, row in ipairs(list) do
    if hasTag(row, tag) and row.hostname ~= nil then
      return row.hostname
    end
  end
  for _, row in ipairs(list) do
    if row.hostname ~= nil then
      return row.hostname
    end
  end
  return nil
end

local function localHostname(list, tag)
  local exact = readLocalHostname()
  if exact ~= nil then
    return exact
  end
  return inferredHostname(list, tag)
end

-- A total order: a row with an unreadable time sorts as the oldest rather than making the
-- comparator inconsistent (Lua's table.sort may raise on an inconsistent order function).
local function sortedRows(list, mode)
  local copy = {}
  for index, row in ipairs(list) do
    copy[index] = row
  end
  table.sort(copy, function(a, b)
    local left = restic.epochFromRfc3339(a.time) or 0
    local right = restic.epochFromRfc3339(b.time) or 0
    if mode == "oldest" then
      return left < right
    end
    return left > right
  end)
  return copy
end

local function visibleRows()
  local list = allRows()
  local tag = configuredTag()
  local filter = { text = ui_state.query }
  if ui_state.filterIndex == 1 then
    filter.host = localHostname(list, tag)
  elseif ui_state.filterIndex == 2 and tag ~= "" then
    -- With no configured tag the option cannot discriminate, so it degrades to "all snapshots"
    -- instead of hiding every row.
    filter.tag = tag
  end
  return sortedRows(restic.filterSnapshots(list, filter), ui_state.sort)
end

local function findRow(id)
  for _, row in ipairs(allRows()) do
    if tostring(row.id) == id then
      return row
    end
  end
  return nil
end

-- The older neighbour in publication order (restic lists newest first); the "diff with previous"
-- anchor. Uses the unfiltered list on purpose: a filter must not change what "previous" means.
local function previousId(id)
  local ordered = sortedRows(allRows(), "newest")
  for index, row in ipairs(ordered) do
    if tostring(row.id) == id then
      local older = ordered[index + 1]
      if older ~= nil then
        return tostring(older.id)
      end
      return nil
    end
  end
  return nil
end

-- ── restore / forget: two-step, previewed ────────────────────────────────────

local function previewFor(id)
  if type(job) ~= "table" or job.kind ~= "restore-dry" then
    return nil
  end
  if tostring(job.snapshot) ~= id then
    return nil
  end
  return job
end

-- Always preview first: the panel must never offer the real restore before a dry run has been
-- seen, which is exactly the 0.1.0 behaviour the review flagged.
local function startRestore(row)
  if row == nil then
    return
  end
  local id = tostring(row.id)
  ui_state.forgetDraft = nil
  ui_state.restoreDraft = { snapshot = id, shortId = row.shortId }
  ui_state.message = nil
  send(state.EVENT_RESTORE_DRY, encode({ snapshot = id, target = config().restoreTarget }))
  render()
end

local function contextItems()
  return {
    { id = "restore_preview", label = tr("panel.action.restore_preview") },
    { id = "restore", label = tr("panel.action.restore") },
    { kind = "separator" },
    { id = "files", label = tr("panel.action.files") },
    { id = "diff_prev", label = tr("panel.action.diff") },
    { id = "copy_id", label = tr("panel.action.copy_id") },
    { kind = "separator" },
    { id = "forget_one", label = tr("panel.action.forget_one") },
  }
end

local function openMenu(row)
  if row == nil then
    return
  end
  panel.openContextMenu({
    items = contextItems(),
    onActivate = "onContextAction",
    context = row.id,
    maxVisible = 12,
  })
end

-- Called by the host for every context-menu activation (panel.openContextMenu's onActivate).
-- `context` is the snapshot id the menu was opened for.
function onContextAction(actionId, context)
  local id = tostring(context or "")
  local row = findRow(id)

  -- An action that changes the view closes the row's action SHEET, whichever surface asked for it:
  -- the sheet exists only for the row it was opened on, and the native menu can be opened on a row
  -- whose sheet happens to be open too. The details CARD is deliberately not closed by its own
  -- buttons -- it is a view the user opened to read, not a menu, and "Copy id" must not take the
  -- fields away from under them. It closes on its own Close, on a second dots click, when another
  -- row is expanded, or on a tab switch.
  if ui_state.openRow ~= nil and ui_state.openRow.id == id and ui_state.openRow.sheet == true then
    ui_state.openRow = nil
  end

  if actionId == "copy_id" then
    noctalia.copyToClipboard(id)
    ui_state.message = tr("panel.message.copied_id", { id = id })
    render()
    return
  end

  if actionId == "details" then
    -- The details card, revealed by the sheet on the row it belongs to. Nothing is fetched: the row
    -- the panel already holds carries every field the card renders (lib/restic.luau snapshotRow).
    -- Only the sheet offers this entry -- the native menu's item list is frozen at its six actions
    -- and its test pins them.
    ui_state.openRow = { id = id, sheet = false, details = true }
    render()
    return
  end

  if actionId == "forget_one" then
    -- Step one of two: name the snapshot and wait for the confirm button.
    ui_state.restoreDraft = nil
    ui_state.forgetDraft = { snapshot = id, shortId = row ~= nil and row.shortId or nil }
    ui_state.message = nil
    render()
    return
  end

  if actionId == "files" then
    ui_state.restoreDraft = nil
    ui_state.forgetDraft = nil
    send(state.EVENT_LS, encode({ snapshot = id }))
    render()
    return
  end

  if actionId == "diff_prev" then
    local from = previousId(id)
    if from == nil then
      ui_state.message = tr("panel.diff.no_previous")
      render()
      return
    end
    send(state.EVENT_DIFF, encode({ from = from, to = id }))
    render()
    return
  end

  if actionId == "restore" then
    -- "Restore now" jumps to the confirm step, but only while a successful preview for this
    -- snapshot is loaded; otherwise it starts one, so the destructive button is never reachable
    -- unpreviewed.
    ui_state.forgetDraft = nil
    ui_state.restoreDraft = { snapshot = id, shortId = row ~= nil and row.shortId or nil }
    if previewFor(id) == nil then
      send(state.EVENT_RESTORE_DRY, encode({ snapshot = id, target = config().restoreTarget }))
    end
    render()
    return
  end

  if actionId == "restore_preview" then
    startRestore(row or { id = id, shortId = id })
  end
end

local function dismissButton(key, onDismiss)
  return ui.button({
    key = key,
    text = tr("panel.action.cancel"),
    variant = "ghost",
    controlSize = "sm",
    onClick = onDismiss,
  })
end

local function restoreDrawer()
  local draft = ui_state.restoreDraft
  if draft == nil then
    return nil
  end
  local preview = previewFor(draft.snapshot)
  local target = config().restoreTarget
  if preview ~= nil and type(preview.target) == "string" and preview.target ~= "" then
    target = preview.target
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "arrow-back-up", size = 14, color = "primary" }),
      ui.label({ key = "restore-draft-title", text = tr("panel.action.restore"), fontWeight = "bold" }),
      ui.label({ text = tostring(draft.snapshot), color = "on_surface/0.6", fontSize = 12 }),
      ui.spacer({ flexGrow = 1 }),
      dismissButton("draft-dismiss", function()
        ui_state.restoreDraft = nil
        render()
      end),
    }),
  }

  if preview == nil then
    table.insert(children, ui.label({
      key = "restore-preview-missing",
      text = tr("panel.restore.preview_missing"),
      color = "on_surface/0.6",
      fontSize = 12,
    }))
  elseif preview.ok ~= true then
    -- A failed preview never reveals the confirm button.
    table.insert(children, ui.label({
      key = "restore-preview-failed",
      text = tr("panel.error.preview_failed"),
      color = "error",
      fontSize = 12,
    }))
  else
    table.insert(children, ui.label({
      key = "restore-preview",
      text = tr("panel.restore.dry_run_header", { files = tostring(preview.files or 0), target = target }),
    }))
    table.insert(children, ui.label({
      key = "restore-warning",
      text = tr("panel.restore.confirm"),
      color = "on_surface/0.5",
      fontSize = 12,
    }))
    table.insert(children, ui.button({
      key = "restore-confirm",
      text = tr("panel.action.confirm_restore", { target = target }),
      variant = "destructive",
      onClick = function()
        send(state.EVENT_RESTORE, encode({ snapshot = draft.snapshot, target = target }))
        ui_state.restoreDraft = nil
        render()
      end,
    }))
  end

  return ui.column({ key = "restore-draft", gap = 6, padding = 10 }, children)
end

local function forgetDrawer()
  local draft = ui_state.forgetDraft
  if draft == nil then
    return nil
  end
  local name = draft.shortId ~= nil and tostring(draft.shortId) or draft.snapshot
  return ui.column({ key = "forget-draft", gap = 6, padding = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "trash", size = 14, color = "error" }),
      ui.label({ key = "forget-draft-title", text = tr("panel.action.forget_one"), fontWeight = "bold" }),
      ui.label({ text = tostring(name), color = "on_surface/0.6", fontSize = 12 }),
      ui.spacer({ flexGrow = 1 }),
      dismissButton("forget-dismiss", function()
        ui_state.forgetDraft = nil
        render()
      end),
    }),
    ui.button({
      key = "forget-confirm",
      text = tr("panel.action.confirm_forget_one", { id = tostring(draft.snapshot) }),
      variant = "destructive",
      onClick = function()
        -- Step two: always names the full id in the IPC payload.
        send(state.EVENT_FORGET_ONE, encode({ snapshot = draft.snapshot }))
        ui_state.forgetDraft = nil
        render()
      end,
    }),
  })
end

-- ── the per-row action sheet and the details card (0.4.0) ────────────────────
--
-- The trailing dots button cannot open the native context menu on a LEFT click: the host refuses
-- panel.openContextMenu outside a live pointer context (src/scripting/plugin_bindings.cpp returns
-- false) and the API doc names onRightClick as the only place it may be called. So the left click
-- opens something the PANEL renders -- a column of small buttons beneath the row (the UI has no
-- menu or popup node, so it is built from rows of buttons) -- while the right click keeps the native
-- menu exactly as before (openMenu from onRightClick).
--
-- The expansion belongs to one row's id and one row may be expanded at a time: opening row B's
-- sheet closes row A's. Predictable beats several-at-once here -- the sheet is a menu, not a form,
-- and a single slot keeps "click the dots again to close" true for whatever happens to be open.
local SHEET_ENTRIES = {
  -- The native menu's actions in the same order, plus Details, each naming an EXISTING action id so
  -- activateSheetEntry can route it through onContextAction -- the very function the native menu's
  -- onActivate calls. One code path for both surfaces, two-step restore and forget flows included.
  -- `glyph` values stay string literals: glyph names are checked against the host icon set.
  { action = "details", label = "panel.action.details", glyph = "info-circle" },
  { action = "files", label = "panel.action.files", glyph = "file" },
  { action = "diff_prev", label = "panel.action.diff", glyph = "arrows-diff" },
  { action = "restore", label = "panel.action.restore", glyph = "arrow-back-up" },
  { action = "copy_id", label = "panel.action.copy_id", glyph = "copy" },
  { action = "forget_one", label = "panel.action.forget_one", glyph = "trash" },
}

local function rowIsOpen(id)
  local open = ui_state.openRow
  return open ~= nil and open.id == id
end

-- Left click on the dots: toggle this row's sheet. A second click on the same dots closes whatever
-- this row had open (sheet or card); clicking another row's dots moves the expansion there.
local function toggleSheet(row)
  local id = tostring(row.id)
  if rowIsOpen(id) then
    ui_state.openRow = nil
  else
    ui_state.openRow = { id = id, sheet = true, details = false }
  end
  render()
end

-- One router, no extra state: every entry hands its existing action id to onContextAction -- the
-- very function the native menu's onActivate calls. That function is also what closes this row's
-- sheet (every entry changes what the panel shows) and re-opens the row as the details card for
-- `details`, so the two surfaces behave identically by construction.
local function activateSheetEntry(action, row)
  onContextAction(action, tostring(row.id))
end

local function actionSheet(row)
  local id = tostring(row.id)
  local children = {}
  -- Bounded by the frozen entry list above, never by anything the service sent.
  for _, entry in ipairs(SHEET_ENTRIES) do
    table.insert(children, ui.button({
      key = "sheet-" .. entry.action .. "-" .. id,
      text = tr(entry.label),
      glyph = entry.glyph,
      -- The delete entry is not styled destructive: this button only opens the two-step flow, and a
      -- destructive-looking button would promise something a single click never does.
      variant = entry.action == "forget_one" and "outline" or "ghost",
      controlSize = "sm",
      onClick = function()
        activateSheetEntry(entry.action, row)
      end,
    }))
  end
  return ui.column({ key = "sheet-" .. id, gap = 4, padding = 6 }, children)
end

-- A field the row does not carry renders the catalogue's own "not recorded": never a fabricated
-- zero, never tostring(nil) ("nil"), never restic.humanBytes(nil) (an em dash is a different
-- sentence). A real 0 from the row is a value and is shown as one.
local function detailText(value)
  if type(value) == "number" then
    return tostring(value)
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return tr("panel.details.none")
end

local function detailBytes(value)
  if tonumber(value) == nil then
    return tr("panel.details.none")
  end
  return restic.humanBytes(value)
end

local function detailList(list)
  if type(list) ~= "table" or #list == 0 then
    return tr("panel.details.none")
  end
  -- Bounded by the entries restic recorded (tags and paths; single digits in practice, and the
  -- paths are the user's own backup settings), never by bytes walked one at a time.
  local parts = {}
  for _, entry in ipairs(list) do
    table.insert(parts, tostring(entry))
  end
  return table.concat(parts, ", ")
end

-- Short id and full id together: the short one is what the list shows, the full one is what restic
-- and every IPC payload use. Equal or absent parts are not repeated.
local function detailId(row)
  if row.id == nil then
    return detailText(row.shortId)
  end
  local full = tostring(row.id)
  local short = row.shortId ~= nil and tostring(row.shortId) or nil
  if short == nil or short == full then
    return full
  end
  return short .. " · " .. full
end

-- Captured: the absolute time exactly as the row carries it (RFC3339 with the snapshot's own UTC
-- offset, i.e. local time at capture) AND the relative form this panel already uses elsewhere
-- (panel.label.ago over restic.ageLabel).
local function detailCaptured(row)
  if type(row.time) ~= "string" or row.time == "" then
    return tr("panel.details.none")
  end
  local epoch = restic.epochFromRfc3339(row.time)
  if epoch == nil then
    -- An absolute time the panel cannot parse is still the truth about when it was captured; the
    -- relative half is what gets left out.
    return row.time
  end
  return row.time .. " · " .. tr("panel.label.ago", { age = restic.ageLabel(nowSec() - epoch) })
end

local function detailRow(key, labelKey, value)
  return ui.row({ key = key, gap = 8, align = "center" }, {
    ui.label({ text = tr(labelKey), color = "on_surface/0.6", fontSize = 12 }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ key = key .. "-value", text = tostring(value), fontSize = 12 }),
  })
end

local function detailsCard(row)
  local id = tostring(row.id)
  return ui.column({ key = "details-" .. id, gap = 4, padding = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "info-circle", size = 14, color = "primary" }),
      ui.label({ key = "details-title", text = tr("panel.details.title"), fontWeight = "bold", fontSize = 12 }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        key = "details-files-" .. id,
        text = tr("panel.action.files"),
        glyph = "file",
        variant = "ghost",
        controlSize = "sm",
        -- The same code path the menu and the sheet use.
        onClick = function()
          onContextAction("files", id)
        end,
      }),
      ui.button({
        key = "details-copy-" .. id,
        text = tr("panel.action.copy_id"),
        glyph = "copy",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          onContextAction("copy_id", id)
        end,
      }),
      ui.button({
        key = "details-dismiss-" .. id,
        text = tr("panel.action.close"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          ui_state.openRow = nil
          render()
        end,
      }),
    }),
    detailRow("details-id-" .. id, "panel.details.snapshot_id", detailId(row)),
    detailRow("details-captured-" .. id, "panel.details.captured", detailCaptured(row)),
    detailRow("details-host-" .. id, "panel.details.host", detailText(row.hostname)),
    detailRow("details-tags-" .. id, "panel.details.tags", detailList(row.tags)),
    detailRow("details-paths-" .. id, "panel.details.paths", detailList(row.paths)),
    detailRow("details-files-" .. id, "panel.details.files", detailText(row.filesProcessed)),
    detailRow("details-bytes-" .. id, "panel.details.bytes", detailBytes(row.bytesProcessed)),
    detailRow("details-added-" .. id, "panel.details.added", detailBytes(row.dataAdded)),
  })
end

-- ── snapshots tab ────────────────────────────────────────────────────────────

local function snapshotRow(row)
  local id = tostring(row.id)
  local tags = ""
  if type(row.tags) == "table" and #row.tags > 0 then
    tags = " · " .. table.concat(row.tags, ", ")
  end
  return ui.row({ key = "row-" .. id, gap = 8, align = "center", padding = 6 }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tostring(row.time or "?") .. tags, fontSize = 12 }),
      ui.label({
        text = tr("panel.row.meta", {
          host = tostring(row.hostname or "?"),
          files = tostring(row.filesProcessed or 0),
          size = restic.humanBytes(row.bytesProcessed),
        }),
        color = "on_surface/0.5",
        fontSize = 11,
      }),
    }),
    -- A visible Restore button keeps the (now two-step) flow discoverable without right-clicking.
    ui.button({
      key = "restore-" .. id,
      text = tr("panel.action.restore"),
      glyph = "arrow-back-up",
      variant = "secondary",
      controlSize = "sm",
      onClick = function()
        startRestore(row)
      end,
    }),
    -- The trailing dots button opens the in-panel action sheet from a left click and the native
    -- context menu from a right click. The left click CANNOT open the native menu: the host refuses
    -- panel.openContextMenu outside a live pointer context, and the API doc names onRightClick as
    -- its only legal caller (docs/CONTRACTS-0.4.0.md 1.2). Both surfaces list the same actions.
    ui.button({
      key = "menu-" .. id,
      glyph = "dots-vertical",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        toggleSheet(row)
      end,
      onRightClick = function()
        openMenu(row)
      end,
    }),
  })
end

-- The row plus whatever that row has expanded beneath it: the action sheet, or the details card.
-- Rendered in the same column so the sheet sits under the row it belongs to; the panel has no menu
-- or popup node to put it anywhere else.
local function snapshotEntry(row)
  local id = tostring(row.id)
  local children = { snapshotRow(row) }
  local open = ui_state.openRow
  if open ~= nil and open.id == id then
    if open.sheet == true then
      table.insert(children, actionSheet(row))
    end
    if open.details == true then
      table.insert(children, detailsCard(row))
    end
  end
  return ui.column({ key = "entry-" .. id, gap = 6 }, children)
end

local function filesSection()
  if type(files) ~= "table" or files.ok == false then
    -- A failed listing is reported by the job itself (Log tab); staying silent here beats
    -- guessing at the reason.
    return {}
  end
  local entries = type(files.entries) == "table" and files.entries or {}
  local out = {
    ui.separator({}),
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "file", size = 13 }),
      ui.label({
        key = "files-title",
        text = tr("panel.action.files") .. " · " .. tostring(files.snapshot or "?"),
        fontWeight = "bold",
        fontSize = 12,
      }),
      ui.spacer({ flexGrow = 1 }),
      dismissButton("files-dismiss", function()
        files = nil
        render()
      end),
    }),
  }
  if #entries == 0 then
    table.insert(out, ui.label({ text = tr("panel.empty.files"), color = "on_surface/0.5", fontSize = 12 }))
    return out
  end
  local shown = 0
  for _, entry in ipairs(entries) do
    if shown >= MAX_FILE_ROWS then
      break
    end
    shown = shown + 1
    table.insert(out, ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = tostring(entry.path or entry.name or "?"),
        fontSize = 11,
        maxLines = 1,
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = restic.humanBytes(entry.size), color = "on_surface/0.6", fontSize = 11 }),
    }))
  end
  if files.truncated == true or #entries > shown then
    table.insert(out, ui.label({
      key = "files-truncated",
      text = tr("panel.files.truncated", { lines = tostring(shown) }),
      color = "on_surface/0.5",
      fontSize = 11,
    }))
  end
  return out
end

-- The diff's changed-path lists. restic.parseDiff returns them as addedPaths / removedPaths /
-- changedPaths; the brief that asked for this rendering names them "added/removed/changed" and the
-- counts already occupy those names, so an array under either name is read -- a shape mismatch must
-- not silently empty the list, because a silently truncated list is a lie about the repository. Only
-- string entries are rendered: a nested statistics table must never be shown as "table: 0x...".
local function pathList(source, primary, fallback)
  local list = source[primary]
  if type(list) ~= "table" then
    list = source[fallback]
  end
  if type(list) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(list) do
    if type(entry) == "string" then
      table.insert(out, entry)
    end
  end
  return out
end

-- The count beside each list: the payload's own number when it carries one, otherwise the number of
-- paths it shipped. Never `tostring(<table>)` under a count, and never a hard 0 that would understate
-- what changed.
local function countOf(value, list)
  local number = tonumber(value)
  if number ~= nil then
    return number
  end
  return #list
end

-- One bounded pass over the three lists (records, never bytes): at most MAX_DIFF_ROWS rows, exactly
-- like the file listing. Returns how many rows were written so the caller can state what it left out.
-- The +/~/- markers are diff syntax rather than prose, so they need no translation key (en.json has
-- no per-direction path heading; `panel.label.diff_paths` labels the list).
local function diffPathRows(out, groups)
  local shown = 0
  for _, group in ipairs(groups) do
    for _, path in ipairs(group.paths) do
      if shown >= MAX_DIFF_ROWS then
        return shown
      end
      shown = shown + 1
      table.insert(out, ui.row({ key = "diff-path-" .. tostring(shown), gap = 8, align = "center" }, {
        ui.label({ text = group.marker, color = group.color, fontSize = 11 }),
        ui.label({ text = path, fontSize = 11, maxLines = 1 }),
      }))
    end
  end
  return shown
end

local function diffSection()
  if type(diff) ~= "table" or diff.ok == false then
    return {}
  end
  -- Counts first, then the paths, in the order the counts line names them.
  local added = pathList(diff, "addedPaths", "added")
  local removed = pathList(diff, "removedPaths", "removed")
  local changed = pathList(diff, "changedPaths", "changed")
  local out = {
    ui.separator({}),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        key = "diff-title",
        text = tr("panel.diff.header", { from = tostring(diff.from or "?"), to = tostring(diff.to or "?") }),
        fontWeight = "bold",
        fontSize = 12,
      }),
      ui.spacer({ flexGrow = 1 }),
      dismissButton("diff-dismiss", function()
        diff = nil
        render()
      end),
    }),
    ui.label({
      key = "diff-counts",
      text = tr("panel.diff.counts", {
        added = tostring(countOf(diff.added, added)),
        removed = tostring(countOf(diff.removed, removed)),
        changed = tostring(countOf(diff.changed, changed)),
      }),
      fontSize = 12,
    }),
  }

  local groups = {
    { marker = "+", color = "primary", paths = added },
    { marker = "-", color = "error", paths = removed },
    { marker = "~", color = "on_surface/0.6", paths = changed },
  }
  local total = #added + #removed + #changed
  if total == 0 then
    return out
  end

  table.insert(out, ui.label({
    key = "diff-paths-title",
    text = tr("panel.label.diff_paths"),
    color = "on_surface/0.7",
    fontSize = 12,
  }))
  local shown = diffPathRows(out, groups)
  if total > shown then
    -- Exact: these paths arrived in the payload and this bound left them out.
    table.insert(out, ui.label({
      key = "diff-more",
      text = tr("panel.label.diff_more", { count = tostring(total - shown) }),
      color = "on_surface/0.5",
      fontSize = 11,
    }))
  elseif diff.truncated == true then
    -- The parser cut the lists before the panel saw them, so the number still missing is unknown --
    -- stating a count here would be a guess. Say only what is known: how many were listed.
    table.insert(out, ui.label({
      key = "diff-truncated",
      text = tr("panel.files.truncated", { lines = tostring(shown) }),
      color = "on_surface/0.5",
      fontSize = 11,
    }))
  end
  return out
end

local function snapshotsTab()
  local list = allRows()
  local visible = visibleRows()
  local tag = configuredTag()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = tr("panel.filter.label"), color = "on_surface/0.7", fontSize = 12 }),
    ui.select({
      key = "filter-select",
      options = {
        tr("panel.filter.all"),
        tr("panel.filter.only_host"),
        tr("panel.filter.tagged", { tag = tag }),
      },
      selectedIndex = ui_state.filterIndex,
      controlSize = "sm",
      onChange = function(index)
        ui_state.filterIndex = tonumber(index) or 0
        render()
      end,
    }),
    ui.input({
      key = "filter-text",
      value = ui_state.query,
      placeholder = tr("panel.filter.search"),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(value)
        ui_state.query = value or ""
        render()
      end,
    }),
    ui.button({
      key = "sort",
      text = ui_state.sort == "newest" and tr("panel.filter.newest") or tr("panel.filter.oldest"),
      glyph = "arrows-up-down",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        ui_state.sort = ui_state.sort == "newest" and "oldest" or "newest"
        render()
      end,
    }),
  }))

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({
      key = "snapshot-count",
      text = tr("panel.label.snapshot_count", { shown = tostring(#visible), total = tostring(#list) }),
      color = "on_surface/0.7",
      fontSize = 12,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      key = "refresh",
      text = tr("panel.action.refresh"),
      glyph = "refresh",
      variant = "secondary",
      controlSize = "sm",
      onClick = function()
        send(state.EVENT_REFRESH)
      end,
    }),
  }))

  local drawer = restoreDrawer()
  if drawer ~= nil then
    table.insert(children, drawer)
  end
  drawer = forgetDrawer()
  if drawer ~= nil then
    table.insert(children, drawer)
  end

  local items = {}
  if #list == 0 then
    table.insert(items, ui.column({ key = "snapshots-empty", gap = 6, align = "center", padding = 24 }, {
      ui.glyph({ name = "archive-off", size = 28, color = "on_surface/0.5" }),
      ui.label({ text = tr("panel.empty.snapshots"), color = "on_surface/0.7" }),
      ui.label({ text = tr("panel.empty.snapshots_hint"), color = "on_surface/0.4", fontSize = 12 }),
    }))
  else
    local shown = 0
    for _, row in ipairs(visible) do
      if shown >= MAX_ROWS then
        break
      end
      shown = shown + 1
      table.insert(items, snapshotEntry(row))
    end
  end
  for _, node in ipairs(filesSection()) do
    table.insert(items, node)
  end
  for _, node in ipairs(diffSection()) do
    table.insert(items, node)
  end

  table.insert(children, ui.scroll({ key = "snapshot-list", flexGrow = 1, gap = 2 }, items))
  return children
end

-- ── run tab ──────────────────────────────────────────────────────────────────

-- Unavailable reasons come from the frozen why keys, in the order that matters to the user: a
-- missing binary beats an unconfigured repository, which beats the mode, which beats no paths.
local function whyUnavailable(cfg)
  if status.available ~= true then
    return tr("panel.why.not_installed")
  end
  if status.repoConfigured ~= true then
    return tr("panel.why.not_configured")
  end
  if status.mode ~= "plugin" then
    return tr("panel.why.observe")
  end
  if #cfg.paths == 0 then
    return tr("panel.why.no_paths")
  end
  return nil
end

local function isLocked()
  if status.error == nil or status.error == "" then
    return false
  end
  return string.lower(tostring(status.error)):find("lock", 1, true) ~= nil
end

local function progressBlock()
  local work = status.job or {}
  local percent = tonumber(work.percent) or 0
  return ui.column({ key = "progress", gap = 6, padding = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ key = "progress-label", text = tr("panel.label.progress"), fontWeight = "bold", fontSize = 12 }),
      ui.label({ text = tostring(work.kind or ""), color = "on_surface/0.5", fontSize = 12 }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ key = "progress-percent", text = string.format("%.0f%%", percent * 100), fontSize = 12 }),
    }),
    ui.progress({ key = "progress-bar", progress = percent, height = 6 }),
    ui.label({
      key = "progress-files",
      text = string.format("%s / %s", tostring(work.filesDone or 0), tostring(work.totalFiles or 0))
        .. " · " .. restic.humanBytes(work.bytesDone) .. " / " .. restic.humanBytes(work.totalBytes),
      color = "on_surface/0.6",
      fontSize = 11,
    }),
  })
end

local function statRow(key, labelKey, value)
  return ui.row({ key = key, gap = 8, align = "center" }, {
    ui.label({ text = tr(labelKey), color = "on_surface/0.6", fontSize = 12 }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ text = tostring(value), fontSize = 12 }),
  })
end

local function statsCard()
  if type(stats) ~= "table" then
    -- Never render zeros for a card that was never fetched; the refresh button below is how the
    -- user asks for it.
    return nil
  end
  return ui.column({ key = "stats-card", gap = 4, padding = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "database", size = 13, color = "primary" }),
      ui.label({ text = tr("panel.stats.repo_label"), fontWeight = "bold", fontSize = 12 }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        key = "stats-refresh",
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.action.refresh"),
        onClick = function()
          send(state.EVENT_STATS)
        end,
      }),
    }),
    statRow("stats-size", "panel.label.stats_size", restic.humanBytes(stats.totalBytes)),
    statRow("stats-files", "panel.label.stats_files", stats.totalFileCount or 0),
    statRow("stats-snapshots", "panel.label.stats_snapshots", stats.snapshotsCount or 0),
  })
end

local function lastRunLine()
  local last = status.lastRun
  if type(last) ~= "table" then
    return ui.label({ key = "last-run", text = tr("panel.run.no_run"), color = "on_surface/0.6", fontSize = 12 })
  end
  local verdict
  if last.cancelled == true then
    verdict = tr("panel.run.last_cancelled")
  elseif last.ok == true then
    verdict = tr("panel.run.last_succeeded")
  else
    verdict = tr("panel.run.last_failed")
  end
  return ui.column({ key = "last-run", gap = 4 }, {
    ui.label({ text = verdict .. " · " .. agoLabel(last.at), fontSize = 12 }),
    ui.label({
      text = tr("panel.run.files_line", {
        files = tostring(last.files or 0),
        processed = restic.humanBytes(last.bytes),
        added = restic.humanBytes(last.added),
      }),
      color = "on_surface/0.6",
      fontSize = 11,
    }),
  })
end

-- The last integrity check. status.checks is published by the service as { lastAt, lastOk, numErrors }
-- (numErrors is restic's own summary count, nil when the run produced no summary). Until 0.3.0 only
-- the Log tab showed it, so a check that reported errors was effectively invisible.
local function checksLine()
  local checks = status.checks
  local at = type(checks) == "table" and tonumber(checks.lastAt) or nil
  local value
  local problem = false
  if at == nil then
    value = tr("panel.label.never")
  else
    local errors = tonumber(checks.numErrors) or 0
    local verdict = tr("panel.label.ok")
    if errors > 0 then
      -- The error count outranks a lastOk of true: "ok · 3 errors" contradicts itself, and a check
      -- that found errors must never read as green.
      verdict = tr("panel.label.failed") .. " · " .. tr("panel.label.check_errors", { errors = tostring(errors) })
      problem = true
    elseif checks.lastOk ~= true then
      verdict = tr("panel.label.failed")
      problem = true
    end
    value = agoLabel(at) .. " · " .. verdict
  end
  return ui.row({ key = "checks-line", gap = 8, align = "center" }, {
    ui.glyph({ name = "shield-check", size = 13, color = problem and "error" or "on_surface/0.6" }),
    ui.label({ text = tr("panel.label.last_check"), color = "on_surface/0.6", fontSize = 12 }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ key = "checks-value", text = value, color = problem and "error" or "on_surface", fontSize = 12 }),
  })
end

-- The last restore verification, from status.verify = { lastAt, lastOk, checked, matched, failed,
-- detail }. `skipped` is deliberately not a field: skipped = checked - matched - failed, and a
-- skipped file is one whose live copy legitimately changed or went away, so it proves neither way.
--
-- lastOk alone is NOT the verdict: a run that compared nothing publishes lastOk = true (no live file
-- was blamed) with a detail sentence saying so, and rendering that as "N verified" would be the exact
-- lie this feature exists to remove. So success is judged on the counts, and a run that proved
-- nothing shows no verdict word at all -- the counts line and the service's own detail sentence carry
-- it, in the palette's attention role rather than a success one.
local function verifyBlock(running)
  local verify = status.verify
  local verdict = nil
  local tone = "on_surface"
  local counts = nil
  local failLine = nil
  local detail = nil
  local at = nil

  if type(verify) ~= "table" then
    verdict = tr("panel.label.never_verified")
    tone = "on_surface/0.6"
  else
    at = tonumber(verify.lastAt)
    local checked = tonumber(verify.checked) or 0
    local matched = tonumber(verify.matched) or 0
    local failed = tonumber(verify.failed) or 0
    if checked == 0 then
      -- Nothing could be checked at all (no snapshot, a failed listing, a refused target). The
      -- service reports that as lastOk = false with a reason, and "0 of 0 files matched" would read
      -- like a pass, so the verdict word carries it and the counts line is left out.
      verdict = tr("panel.label.failed")
      tone = "error"
    elseif failed > 0 then
      verdict = tr("panel.label.failed")
      tone = "error"
    elseif matched == 0 then
      -- checked > 0 and nothing was compared: every file was skipped. No verdict word -- nothing was
      -- proven, and neither "ok" nor "failed" would be true.
      tone = "tertiary"
    else
      verdict = tr("panel.label.ok")
    end
    if checked > 0 then
      counts = tr("panel.label.verified_ok", { matched = tostring(matched), checked = tostring(checked) })
      if failed > 0 then
        -- Stated as its own line rather than left to the detail sentence below, which is free text
        -- from the service and may be trimmed in a future version.
        failLine = tr("panel.label.verified_fail", { failed = tostring(failed), checked = tostring(checked) })
      end
    end
    -- The service's own sentence, shown exactly where the counts cannot explain themselves: nothing
    -- was checked, something did not match (it names the first mismatch), or nothing was compared.
    -- A run whose files all matched has its counts line already saying the same thing.
    local worded = checked == 0 or failed > 0 or matched == 0
    if worded and type(verify.detail) == "string" and verify.detail ~= "" then
      detail = verify.detail
    end
  end

  local children = {
    ui.row({ key = "verify-header", gap = 8, align = "center" }, {
      ui.glyph({ name = "arrow-back-up", size = 13, color = tone }),
      ui.label({ text = tr("panel.label.last_verified"), color = "on_surface/0.6", fontSize = 12 }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        key = "verify-verdict",
        -- "never verified" is the whole value when there is no result: appending an age ("never ·
        -- never") would read as two facts where there are none.
        text = at == nil and verdict
          or (verdict ~= nil and (agoLabel(at) .. " · " .. verdict) or agoLabel(at)),
        color = tone,
        fontSize = 12,
      }),
      ui.button({
        key = "verify-now",
        text = tr("panel.action.verify"),
        glyph = "arrow-back-up",
        variant = "secondary",
        controlSize = "sm",
        -- Same gate as the check button (a verification needs restic and a repository), plus the
        -- in-flight guard every action carries: while a job runs the button is disabled rather than
        -- hidden, because the last result below it is exactly what the user is looking at.
        enabled = status.available == true and status.repoConfigured == true and running ~= true,
        onClick = function()
          -- No payload: the service derives the scratch target from the configured restore target.
          send(state.EVENT_VERIFY)
        end,
      }),
    }),
  }
  if counts ~= nil then
    table.insert(children, ui.label({ key = "verify-counts", text = counts, color = tone, fontSize = 12 }))
  end
  if failLine ~= nil then
    table.insert(children, ui.label({ key = "verify-failed", text = failLine, color = tone, fontSize = 12 }))
  end
  if detail ~= nil then
    table.insert(children, ui.label({ key = "verify-detail", text = detail, color = tone, fontSize = 11 }))
  end
  return ui.column({ key = "verify-block", gap = 4, padding = 10 }, children)
end

local function runTab()
  local cfg = config()
  local children = {}
  local running = status.busy == true or status.phase == "running"
  local why = whyUnavailable(cfg)
  local locked = isLocked()

  if running then
    table.insert(children, progressBlock())
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.button({
        key = "cancel",
        text = tr("panel.action.cancel"),
        glyph = "x",
        variant = "destructive",
        onClick = function()
          send(state.EVENT_CANCEL)
        end,
      }),
    }))
  else
    local actions = {
      ui.button({
        key = "backup",
        text = tr("panel.action.backup_now"),
        glyph = "archive",
        variant = "primary",
        enabled = why == nil and status.initNeeded ~= true,
        onClick = function()
          send(state.EVENT_BACKUP)
        end,
      }),
      ui.button({
        key = "check",
        text = tr("panel.action.check"),
        glyph = "shield-check",
        variant = "secondary",
        enabled = status.available == true and status.repoConfigured == true,
        onClick = function()
          send(state.EVENT_CHECK)
        end,
      }),
    }
    if status.initNeeded == true then
      table.insert(actions, ui.button({
        key = "init",
        text = tr("panel.action.init"),
        glyph = "database",
        variant = "secondary",
        onClick = function()
          send(state.EVENT_INIT)
        end,
      }))
    end
    if locked then
      table.insert(actions, ui.button({
        key = "unlock",
        text = tr("panel.action.unlock"),
        glyph = "lock-open",
        variant = "secondary",
        onClick = function()
          send(state.EVENT_UNLOCK)
        end,
      }))
    end
    table.insert(children, ui.row({ gap = 8, align = "center" }, actions))
  end

  if why ~= nil then
    table.insert(children, ui.label({ key = "why", text = why, color = "on_surface/0.6", fontSize = 12 }))
  end
  if status.initNeeded == true then
    table.insert(children, ui.label({
      key = "init-explain",
      text = tr("panel.init.explain"),
      color = "on_surface/0.6",
      fontSize = 12,
    }))
  end
  if locked then
    table.insert(children, ui.label({ key = "locked", text = tr("panel.error.locked"), color = "error", fontSize = 12 }))
  end
  if status.stale == true then
    table.insert(children, ui.label({
      key = "stale",
      text = tr("panel.label.stale", { age = restic.ageLabel((tonumber(status.staleness) or 0) * 3600) }),
      color = "error",
      fontSize = 12,
    }))
  end

  table.insert(children, ui.separator({}))
  table.insert(children, lastRunLine())
  table.insert(children, checksLine())
  -- The verification block stays visible while a job runs (with its button disabled): it is the last
  -- result, and blanking it mid-job would hide the very thing the user opened the tab to read.
  table.insert(children, verifyBlock(running))
  table.insert(children, ui.label({
    key = "next-run",
    text = tr("panel.run.scheduled", { when = schedule.untilLabel(nowSec(), status.nextRun) }),
    color = "on_surface/0.5",
    fontSize = 12,
  }))

  local card = statsCard()
  if card ~= nil then
    table.insert(children, card)
  end
  return children
end

-- ── retention tab ────────────────────────────────────────────────────────────

local function retentionTab()
  local cfg = config()
  local children = {
    ui.label({
      key = "policy",
      text = tr("panel.retention.policy", {
        last = tostring(cfg.keepLast),
        daily = tostring(cfg.keepDaily),
        weekly = tostring(cfg.keepWeekly),
        monthly = tostring(cfg.keepMonthly),
      }),
    }),
  }

  if not restic.hasPolicy(cfg) then
    table.insert(children, ui.label({
      key = "no-policy",
      text = tr("panel.retention.no_policy"),
      color = "error",
      fontSize = 12,
    }))
    return children
  end

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      key = "preview",
      text = tr("panel.action.preview_removal"),
      glyph = "eye",
      variant = "secondary",
      onClick = function()
        send(state.EVENT_FORGET_DRY)
        render()
      end,
    }),
  }))

  if type(job) ~= "table" or job.kind ~= "forget-dry" then
    return children
  end

  if job.ok ~= true then
    table.insert(children, ui.label({
      key = "preview-failed",
      text = tr("panel.error.preview_failed"),
      color = "error",
      fontSize = 12,
    }))
    return children
  end

  -- Straight from the service (restic.summariseForgetDry): the panel does not re-sum anything.
  local keepCount = tonumber(job.keepCount) or 0
  local removeCount = tonumber(job.removeCount) or 0
  local remove = type(job.remove) == "table" and job.remove or {}

  table.insert(children, ui.column({ key = "preview-summary", gap = 4 }, {
    ui.label({
      key = "preview-counts",
      text = tr("panel.prune.keep_remove", { keep = tostring(keepCount), remove = tostring(removeCount) }),
    }),
    ui.label({
      key = "preview-note",
      text = tr("panel.prune.note"),
      color = "on_surface/0.5",
      fontSize = 12,
    }),
  }))

  if removeCount > 0 then
    table.insert(children, ui.label({
      key = "preview-remove-list-title",
      text = tr("panel.prune.remove_list"),
      color = "on_surface/0.7",
      fontSize = 12,
    }))
    local shown = 0
    for _, entry in ipairs(remove) do
      if shown >= MAX_REMOVE_ROWS then
        break
      end
      shown = shown + 1
      table.insert(children, ui.row({ key = "remove-" .. tostring(entry.id), gap = 8, align = "center" }, {
        ui.label({ text = tostring(entry.shortId or entry.id or "?"), fontSize = 11 }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = tostring(entry.time or "?"), color = "on_surface/0.5", fontSize = 11 }),
      }))
    end
    if job.truncated == true or #remove > shown then
      table.insert(children, ui.label({
        key = "preview-remove-truncated",
        text = tr("panel.prune.truncated", { shown = tostring(shown) }),
        color = "on_surface/0.5",
        fontSize = 11,
      }))
    end

    table.insert(children, ui.button({
      key = "prune",
      text = ui_state.confirmPrune
        and tr("panel.action.confirm_prune", { count = tostring(removeCount) })
        or tr("panel.action.prune"),
      variant = ui_state.confirmPrune and "destructive" or "outline",
      onClick = function()
        if ui_state.confirmPrune then
          send(state.EVENT_FORGET)
          ui_state.confirmPrune = false
          render()
        else
          ui_state.confirmPrune = true
          render()
        end
      end,
    }))
  end

  return children
end

-- ── log tab ──────────────────────────────────────────────────────────────────
--
-- [0.4.0] The tab used to render the service's raw lines, each with maxLines = 1: every scheduled
-- backup's log is a single 473-byte `--json` summary record, so the tab showed one clamped fragment
-- and nothing else (docs/CONTRACTS-0.4.0.md 1.1). It now renders the typed `display` lines the
-- service publishes (lib/logfmt.luau, frozen in 2.1) with the wording owned HERE -- the formatter
-- cannot call tr -- and keeps the raw lines behind a toggle for the record itself.

-- The formatter bounds its output; this bound keeps the panel's own work bounded too, because the
-- tab re-renders on every state publish.
local MAX_LOG_ROWS = 200

-- "?" is this panel's existing way of saying "the record does not carry this" (see the row meta and
-- the file listing). A log line is not a details card: a missing count reads as unknown, not as the
-- catalogue's "not recorded".
local function logNumber(value, format)
  local number = tonumber(value)
  if number == nil then
    return "?"
  end
  if format ~= nil then
    return string.format(format, number)
  end
  return tostring(number)
end

local function logBytes(value)
  if tonumber(value) == nil then
    return "?"
  end
  return restic.humanBytes(value)
end

-- restic's `percent_done` is a 0..1 fraction and this panel's own progress bar uses that scale, so a
-- fraction is rendered as a percentage. lib/logfmt.luau is another workstream's file and is not in
-- this worktree yet, so a value already expressed in percent is accepted as-is: of the two possible
-- readings this picks the one that cannot print 4200% for a job that is 42% done.
local function logPercent(value)
  local percent = tonumber(value)
  if percent == nil then
    return "?"
  end
  if percent <= 1 then
    percent = percent * 100
  end
  return string.format("%.0f", percent)
end

-- One typed Line -> the sentence the user reads plus the colour it deserves. nil means "this panel
-- cannot word this line": an unknown kind is a kind the panel does not understand, so it is shown
-- through the line's own `text` when it carries one and skipped when it does not -- never rendered
-- as "table: 0x...", never given a key nobody translated (en.json has no panel.logs.unknown).
local function displayLine(line)
  if type(line) ~= "table" then
    if type(line) == "string" and line ~= "" then
      -- Not the published shape, but it is still something the job said: show it verbatim.
      return line, "on_surface"
    end
    return nil, nil
  end
  local kind = line.kind
  if kind == "text" then
    if type(line.text) == "string" and line.text ~= "" then
      return line.text, "on_surface"
    end
    return nil, nil
  elseif kind == "progress" then
    return tr("panel.logs.progress", {
      percent = logPercent(line.percent),
      files = logNumber(line.filesDone) .. "/" .. logNumber(line.totalFiles),
      bytes = logBytes(line.bytesDone) .. " / " .. logBytes(line.totalBytes),
    }), "on_surface/0.7"
  elseif kind == "backup" then
    return tr("panel.logs.backup", {
      new = logNumber(line.filesNew),
      changed = logNumber(line.filesChanged),
      unchanged = logNumber(line.filesUnmodified),
      size = logBytes(line.bytesProcessed),
      added = logBytes(line.dataAdded),
      seconds = logNumber(line.durationSeconds, "%.1f"),
    }), "on_surface/0.7"
  elseif kind == "check" then
    -- en.json carries one suggestion key (panel.logs.check_repair, "· repair suggested") and none
    -- for a prune suggestion, so a prune suggestion is reported with the same sentence rather than
    -- dropped: a suggestion the user never sees is worse than slightly general wording. Reported to
    -- the lead as a missing key (panel.logs.check_prune).
    local text = tr("panel.logs.check", { errors = logNumber(line.errors) })
    if line.suggestRepair == true or line.suggestPrune == true then
      text = text .. tr("panel.logs.check_repair")
    end
    if (tonumber(line.errors) or 0) > 0 then
      return text, "error"
    end
    return text, "on_surface/0.7"
  elseif kind == "records" then
    -- `source` (ls / diff / find / stats) has no translation key. The count is what the line is for;
    -- the records themselves have their own views (Files, Diff).
    return tr("panel.logs.records", { count = logNumber(line.count) }), "on_surface/0.5"
  elseif kind == "error" then
    local message = type(line.message) == "string" and line.message or "?"
    return tr("panel.logs.error", { message = message }), "error"
  end
  if type(line.text) == "string" and line.text ~= "" then
    return line.text, "on_surface"
  end
  return nil, nil
end

-- The button names the view that IS on screen and switches to the other one, exactly like the sort
-- toggle above. Formatted is the default: the raw lines are what the tab was complained about.
-- Both glyph names are Tabler names and stay string literals, so the source-invariants audit checks
-- them ("undo" and "arrow-up-down" are not in the set and rendered as blanks).
local function logModeButton()
  local glyph = "text-wrap"
  if ui_state.logRaw then
    glyph = "code"
  end
  return ui.button({
    key = "logs-mode",
    text = ui_state.logRaw and tr("panel.logs.raw") or tr("panel.logs.formatted"),
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      ui_state.logRaw = not ui_state.logRaw
      render()
    end,
  })
end

local function logTab()
  local children = {}
  local refresh = ui.button({
    key = "logs-refresh",
    text = tr("panel.action.refresh"),
    glyph = "refresh",
    variant = "secondary",
    controlSize = "sm",
    onClick = function()
      send(state.EVENT_LOGS)
    end,
  })

  if type(joblog) ~= "table" then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ key = "joblog-empty", text = tr("panel.empty.logs"), color = "on_surface/0.6", flexGrow = 1 }),
      refresh,
    }))
    -- en.json carries no key for a hint here ("the log appears after a job runs"), so the empty
    -- state is left as it was and the missing key is reported to the lead rather than invented.
    return children
  end

  local verdict
  if joblog.cancelled == true then
    verdict = tr("panel.label.cancelled")
  elseif joblog.ok == true then
    verdict = tr("panel.label.ok")
  else
    verdict = tr("panel.label.failed")
  end
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({
      key = "joblog-header",
      text = table.concat({
        tostring(joblog.kind or "job"),
        agoLabel(joblog.at),
        verdict,
        tr("panel.logs.exit", { code = tostring(joblog.exitCode or 0) }),
      }, " · "),
      fontWeight = "bold",
      fontSize = 12,
      flexGrow = 1,
    }),
    logModeButton(),
    refresh,
  }))

  local lines = type(joblog.lines) == "table" and joblog.lines or {}
  local display = type(joblog.display) == "table" and joblog.display or nil
  local items = {}
  local shown = 0
  local cut = false

  -- Raw is the pre-0.4.0 view: the service's own lines. Formatted renders the typed display lines;
  -- a log published before the formatter existed carries no `display` at all, so Formatted falls
  -- back to the lines rather than showing an empty tab.
  if ui_state.logRaw or display == nil then
    for _, line in ipairs(lines) do
      if shown >= MAX_LOG_ROWS then
        cut = true
        break
      end
      shown = shown + 1
      -- NO maxLines clamp. One backup summary is a single long JSON record, and clamping it to one
      -- line is exactly what made this tab unreadable: it has to wrap.
      table.insert(items, ui.label({ text = tostring(line), fontSize = 11 }))
    end
  else
    for _, line in ipairs(display) do
      if shown >= MAX_LOG_ROWS then
        cut = true
        break
      end
      local text, color = displayLine(line)
      if text ~= nil then
        shown = shown + 1
        -- No clamp here either: a hook's output line or a long error has to wrap.
        table.insert(items, ui.label({ text = tostring(text), color = color, fontSize = 11 }))
      end
    end
    -- The folded count describes the Formatted view only: it says how many progress/record lines
    -- were folded into the lines above. Raw shows those lines themselves, where the note would
    -- describe nothing.
    local folded = tonumber(joblog.collapsed) or 0
    if folded > 0 then
      table.insert(items, ui.label({
        key = "logs-folded",
        text = tr("panel.logs.folded", { count = tostring(folded) }),
        color = "on_surface/0.5",
        fontSize = 11,
      }))
    end
  end
  if #items == 0 then
    table.insert(items, ui.label({ text = tr("panel.empty.logs"), color = "on_surface/0.5", fontSize = 12 }))
  end
  table.insert(children, ui.scroll({ key = "joblog", flexGrow = 1, gap = 2, padding = 6, stickToBottom = true }, items))

  if joblog.truncated == true or cut then
    table.insert(children, ui.label({
      key = "joblog-truncated",
      text = tr("panel.logs.truncated", { lines = tostring(shown) }),
      color = "on_surface/0.5",
      fontSize = 11,
    }))
  end
  return children
end

-- ── render ───────────────────────────────────────────────────────────────────

local function showTab(id)
  if ui_state.tab ~= id then
    -- Leaving a tab drops every half-finished confirmation: a stale destructive button must never
    -- survive a tab switch.
    ui_state.restoreDraft = nil
    ui_state.forgetDraft = nil
    ui_state.confirmPrune = false
    ui_state.message = nil
    -- The row expansion belongs to a row on the snapshots tab; leaving the tab closes it. The Log
    -- tab's Formatted/Raw choice is a view preference, not a pending step, so it stays.
    ui_state.openRow = nil
  end
  ui_state.tab = id
  if id == "run" then
    -- The stats card can only be as fresh as the service makes it, and the service refreshes
    -- read-only data on request (it skips refreshes while a job holds the lock).
    send(state.EVENT_STATS)
  end
  render()
end

local function tabChip(id, label)
  return ui.button({
    key = "tab-" .. id,
    text = label,
    variant = ui_state.tab == id and "primary" or "ghost",
    onClick = function()
      showTab(id)
    end,
  })
end

function render()
  local body
  if ui_state.tab == "run" then
    body = runTab()
  elseif ui_state.tab == "retention" then
    body = retentionTab()
  elseif ui_state.tab == "log" then
    body = logTab()
  else
    body = snapshotsTab()
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "archive", size = 15, color = "primary" }),
      ui.label({ text = tr("panel.title"), fontWeight = "bold" }),
      -- Already redacted by the service; never redacted again here.
      ui.label({
        text = status.repoConfigured == true and status.repository or tr("panel.label.not_configured"),
        color = "on_surface/0.5",
        fontSize = 12,
        maxWidth = 380,
        maxLines = 1,
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        key = "close",
        text = tr("panel.action.close"),
        variant = "ghost",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.row({ key = "tabs", gap = 6 }, {
      tabChip("snapshots", tr("panel.tabs.snapshots")),
      tabChip("run", tr("panel.tabs.run")),
      tabChip("retention", tr("panel.tabs.retention")),
      tabChip("log", tr("panel.tabs.logs")),
    }),
  }
  for _, node in ipairs(body) do
    table.insert(children, node)
  end
  if ui_state.message ~= nil then
    table.insert(children, ui.label({ key = "message", text = ui_state.message, color = "on_surface/0.6", fontSize = 12 }))
  end
  if status.error ~= nil and status.error ~= "" then
    table.insert(children, ui.label({ key = "error", text = status.error, color = "error", fontSize = 12 }))
  end

  panel.render(ui.column({ padding = 16, gap = 12, flexGrow = 1 }, children))
end

function onOpen()
  status = state.migrate(noctalia.state.get(state.KEY_STATUS))
  snapshots = noctalia.state.get(state.KEY_SNAPSHOTS)
  job = noctalia.state.get(state.KEY_JOB)
  joblog = noctalia.state.get(state.KEY_JOBLOG)
  stats = noctalia.state.get(state.KEY_STATS)
  files = noctalia.state.get(state.KEY_FILES)
  diff = noctalia.state.get(state.KEY_DIFF)
  -- A fresh open starts with no pending destructive step.
  ui_state.confirmPrune = false
  ui_state.restoreDraft = nil
  ui_state.forgetDraft = nil
  ui_state.message = nil
  ui_state.openRow = nil
  render()
end

function update()
  if status.busy == true or status.phase == "running" then
    render()
  end
end

noctalia.state.watch(state.KEY_STATUS, function(value)
  status = state.migrate(value)
  render()
end)

noctalia.state.watch(state.KEY_SNAPSHOTS, function(value)
  snapshots = value
  render()
end)

noctalia.state.watch(state.KEY_JOB, function(value)
  job = value
  render()
end)

noctalia.state.watch(state.KEY_JOBLOG, function(value)
  joblog = value
  render()
end)

noctalia.state.watch(state.KEY_STATS, function(value)
  stats = value
  render()
end)

noctalia.state.watch(state.KEY_FILES, function(value)
  files = value
  render()
end)

noctalia.state.watch(state.KEY_DIFF, function(value)
  diff = value
  render()
end)

render()
