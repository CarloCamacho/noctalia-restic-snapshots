--!nonstrict
-- Snapshot browser, manual run, dry-run-gated retention, and the last job's log.
--
-- [0.2.0] Four tabs (Snapshots / Run / Retention / Log). Both destructive flows are two-step and
-- both steps live in `ui_state`, which is cleared whenever the tab changes, so a confirmation
-- left over from another tab can never be clicked. Restore previews before it confirms: the
-- one-click restore was the review finding that produced 0.2.0.
--
-- Invariants this file keeps (see docs/CONTRACTS-0.2.0.md 4.8):
--   * `status.repository` is ALREADY redacted by the service -- the panel never redacts it again.
--   * a retention preview is NOT re-summed: keepCount / removeCount / remove come straight from
--     restic.summariseForgetDry via the service, the panel only renders them.
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

local ui_state = {
  tab = "snapshots",
  filterIndex = 0,       -- 0 all snapshots, 1 this host only, 2 tagged <configured tag>
  query = "",
  sort = "newest",       -- newest | oldest
  confirmPrune = false,  -- retention second step
  restoreDraft = nil,    -- { snapshot = <id> } restore confirm, revealed only after a preview
  forgetDraft = nil,     -- { snapshot = <id> } forget-one confirm
  message = nil,
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

-- "This host only" needs a hostname and the status shape deliberately carries none -- the service
-- publishes display fields only. This plugin's own snapshots are exactly the ones carrying the
-- configured backup tag, so the hostname of the newest tagged snapshot is this host's; with no
-- tagged snapshot at all the newest snapshot's hostname is the best answer available, so the
-- filter is never a silent no-op. Reported to the lead: the service could publish the local
-- hostname outright and this inference could go away.
local function localHostname(list, tag)
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

  if actionId == "copy_id" then
    noctalia.copyToClipboard(id)
    ui_state.message = tr("panel.message.copied_id", { id = id })
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
    -- The trailing dots button opens the same menu from the left click and the right click.
    ui.button({
      key = "menu-" .. id,
      glyph = "dots-vertical",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        openMenu(row)
      end,
      onRightClick = function()
        openMenu(row)
      end,
    }),
  })
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

local function diffSection()
  if type(diff) ~= "table" or diff.ok == false then
    return {}
  end
  -- Counts only: the path lists are bounded in lib/restic and deliberately not rendered.
  return {
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
        added = tostring(diff.added or 0),
        removed = tostring(diff.removed or 0),
        changed = tostring(diff.changed or 0),
      }),
      fontSize = 12,
    }),
  }
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
      table.insert(items, snapshotRow(row))
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
    refresh,
  }))

  local lines = type(joblog.lines) == "table" and joblog.lines or {}
  local items = {}
  for _, line in ipairs(lines) do
    table.insert(items, ui.label({ text = tostring(line), fontSize = 11, maxLines = 1 }))
  end
  if #items == 0 then
    table.insert(items, ui.label({ text = tr("panel.empty.logs"), color = "on_surface/0.5", fontSize = 12 }))
  end
  table.insert(children, ui.scroll({ key = "joblog", flexGrow = 1, gap = 2, padding = 6, stickToBottom = true }, items))

  if joblog.truncated == true then
    table.insert(children, ui.label({
      key = "joblog-truncated",
      text = tr("panel.logs.truncated", { lines = tostring(#lines) }),
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
