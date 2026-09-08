--!nonstrict
-- Snapshot browser, manual run, and dry-run-gated retention.

local restic = require("./lib/restic.luau")
local schedule = require("./lib/schedule.luau")
local state = require("./lib/state.luau")

local status = state.migrate(noctalia.state.get(state.KEY_STATUS))
local snapshots = noctalia.state.get(state.KEY_SNAPSHOTS)
local preview = noctalia.state.get(state.KEY_JOB)

local ui_state = {
  tab = "snapshots",
  confirmPrune = false,
  message = nil,
}

local SERVICE = "carlocamacho/restic-snapshots:service"

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

local function rows()
  if type(snapshots) ~= "table" or type(snapshots.snapshots) ~= "table" then
    return {}
  end
  return snapshots.snapshots
end

-- ── tabs ─────────────────────────────────────────────────────────────────────

local function tabChip(id, label)
  return ui.button({
    key = "tab-" .. id,
    text = label,
    variant = ui_state.tab == id and "primary" or "ghost",
    onClick = function()
      ui_state.tab = id
      ui_state.confirmPrune = false
      render()
    end,
  })
end

-- ── snapshots tab ────────────────────────────────────────────────────────────

local function snapshotsTab()
  local children = {}
  local list = rows()

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({
      text = string.format("%d snapshot%s", #list, #list == 1 and "" or "s"),
      color = "on_surface/0.7",
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ key = "refresh", text = "Refresh", glyph = "refresh", variant = "secondary",
      onClick = function() send(state.EVENT_REFRESH) end }),
  }))

  if #list == 0 then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 6 }, {
      ui.glyph({ name = "archive-off", size = 28, color = "on_surface/0.5" }),
      ui.label({ text = "No snapshots yet", color = "on_surface/0.7" }),
      ui.label({ text = "Configure a repository and paths, then run a backup.", color = "on_surface/0.4", fontSize = 12 }),
    }))
    return children
  end

  local items = {}
  local shown = 0
  for _, snapshot in ipairs(list) do
    if shown < 60 then
      shown = shown + 1
      local tags = ""
      if type(snapshot.tags) == "table" and #snapshot.tags > 0 then
        tags = " · " .. table.concat(snapshot.tags, ",")
      end
      table.insert(items, ui.row({ gap = 8, align = "center", padding = 6 }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = tostring(snapshot.time or "?") .. tags, fontSize = 12 }),
          ui.label({
            text = string.format("%s · %s files · %s",
              tostring(snapshot.hostname or "?"),
              tostring(snapshot.filesProcessed or "?"),
              restic.humanBytes(snapshot.bytesProcessed)),
            color = "on_surface/0.5",
            fontSize = 11,
          }),
        }),
        ui.button({
          key = "restore-" .. tostring(snapshot.shortId),
          text = "Restore",
          variant = "secondary",
          controlSize = "sm",
          onClick = function()
            send(state.EVENT_RESTORE, noctalia.json.encode({ snapshot = snapshot.id }) or nil)
            ui_state.message = "Restoring " .. tostring(snapshot.shortId) .. " into the restore target…"
            render()
          end,
        }),
      }))
    end
  end

  table.insert(children, ui.scroll({ flexGrow = 1, gap = 2 }, items))
  return children
end

-- ── run tab ──────────────────────────────────────────────────────────────────

local function runTab()
  local children = {}
  local running = status.phase == "running"
  local job = status.job

  if running then
    local percent = tonumber(job and job.percent) or 0
    table.insert(children, ui.column({ gap = 6 }, {
      ui.label({ text = string.format("%s · %.0f%%", tostring(job and job.kind or "job"), percent * 100) }),
      ui.progress({ progress = percent, height = 6 }),
      ui.label({
        text = string.format("%s / %s files · %s / %s",
          tostring(job and job.filesDone or "?"), tostring(job and job.totalFiles or "?"),
          restic.humanBytes(job and job.bytesDone), restic.humanBytes(job and job.totalBytes)),
        color = "on_surface/0.6",
        fontSize = 12,
      }),
    }))
    table.insert(children, ui.row({ gap = 8 }, {
      ui.button({ key = "cancel", text = "Cancel", variant = "destructive",
        onClick = function() send(state.EVENT_CANCEL) end }),
    }))
    return children
  end

  local canBackup = status.available and status.repoConfigured and status.mode == "plugin"
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.button({ key = "backup", text = "Back up now", glyph = "archive", variant = "primary",
      enabled = canBackup, onClick = function() send(state.EVENT_BACKUP) end }),
    ui.button({ key = "check", text = "Check repository", glyph = "shield-check", variant = "secondary",
      enabled = status.available and status.repoConfigured,
      onClick = function() send(state.EVENT_CHECK) end }),
  }))

  if not canBackup then
    local why
    if not status.available then
      why = "restic is not installed"
    elseif not status.repoConfigured then
      why = "set the repository and password file in the plugin settings"
    else
      why = "the plugin is in observe mode"
    end
    table.insert(children, ui.label({ text = why, color = "on_surface/0.5", fontSize = 12 }))
  end

  local last = status.lastRun
  table.insert(children, ui.separator({}))
  if last == nil then
    table.insert(children, ui.label({ text = "No run recorded yet.", color = "on_surface/0.6" }))
  else
    table.insert(children, ui.column({ gap = 4 }, {
      ui.label({ text = (last.ok and "Last run succeeded" or "Last run failed") .. " · "
        .. restic.ageLabel(nowSec() - (last.at or nowSec())) .. " ago" }),
      ui.label({
        text = string.format("%s files · %s processed · %s added",
          tostring(last.files or "?"), restic.humanBytes(last.bytes), restic.humanBytes(last.added)),
        color = "on_surface/0.6",
        fontSize = 12,
      }),
    }))
  end
  table.insert(children, ui.label({
    text = "Next scheduled run " .. schedule.untilLabel(nowSec(), status.nextRun),
    color = "on_surface/0.5",
    fontSize = 12,
  }))
  return children
end

-- ── retention tab ────────────────────────────────────────────────────────────

local function retentionTab()
  local children = {}
  local cfg = restic.config({
    keep_last = noctalia.getConfig("keep_last"),
    keep_daily = noctalia.getConfig("keep_daily"),
    keep_weekly = noctalia.getConfig("keep_weekly"),
    keep_monthly = noctalia.getConfig("keep_monthly"),
  })

  table.insert(children, ui.label({
    text = string.format("Keep: %d last · %d daily · %d weekly · %d monthly",
      cfg.keepLast, cfg.keepDaily, cfg.keepWeekly, cfg.keepMonthly),
  }))

  if not restic.hasPolicy(cfg) then
    table.insert(children, ui.label({ text = "Set at least one keep-* rule in the plugin settings.", color = "error", fontSize = 12 }))
    return children
  end

  table.insert(children, ui.row({ gap = 8 }, {
    ui.button({ key = "preview", text = "Preview removal", glyph = "eye", variant = "secondary",
      onClick = function()
        send(state.EVENT_FORGET_DRY)
        ui_state.message = "Previewing what would be removed…"
        render()
      end }),
  }))

  if type(preview) == "table" and preview.kind == "forget-dry" then
    if preview.ok ~= true then
      table.insert(children, ui.label({ text = "Preview failed — see the log.", color = "error", fontSize = 12 }))
    else
      local groups = preview.groups
      local keepCount, removeCount = 0, 0
      if type(groups) == "table" then
        for _, group in ipairs(groups) do
          keepCount = keepCount + #(group.keep or {})
          removeCount = removeCount + #(group.remove or {})
        end
      end
      table.insert(children, ui.column({ gap = 4 }, {
        ui.label({ text = string.format("Would keep %d, remove %d", keepCount, removeCount) }),
        ui.label({ text = "Removal only runs after you confirm below.", color = "on_surface/0.5", fontSize = 12 }),
      }))
      if removeCount > 0 then
        table.insert(children, ui.button({
          key = "prune",
          text = ui_state.confirmPrune and "Confirm: prune " .. tostring(removeCount) .. " snapshots" or "Prune now",
          variant = ui_state.confirmPrune and "destructive" or "outline",
          onClick = function()
            if ui_state.confirmPrune then
              send(state.EVENT_FORGET)
              ui_state.confirmPrune = false
              ui_state.message = "Pruning…"
              render()
            else
              ui_state.confirmPrune = true
              render()
            end
          end,
        }))
      end
    end
  end

  return children
end

-- ── render ───────────────────────────────────────────────────────────────────

function render()
  local header = {
    ui.glyph({ name = "archive", size = 15, color = "primary" }),
    ui.label({ text = "Restic Snapshots", fontWeight = "bold" }),
    ui.label({
      text = status.repoConfigured and status.repository or "no repository",
      color = "on_surface/0.5",
      fontSize = 12,
      maxWidth = 380,
      maxLines = 1,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ key = "close", text = "Close", variant = "ghost", onClick = function() panel.close() end }),
  }

  local body = {}
  if ui_state.tab == "snapshots" then
    body = snapshotsTab()
  elseif ui_state.tab == "run" then
    body = runTab()
  else
    body = retentionTab()
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, header),
    ui.row({ gap = 6 }, {
      tabChip("snapshots", "Snapshots"),
      tabChip("run", "Run"),
      tabChip("retention", "Retention"),
    }),
  }
  for _, node in ipairs(body) do
    table.insert(children, node)
  end
  if ui_state.message ~= nil then
    table.insert(children, ui.label({ text = ui_state.message, color = "on_surface/0.6", fontSize = 12 }))
  end
  if status.error ~= nil and status.error ~= "" then
    table.insert(children, ui.label({ text = status.error, color = "error", fontSize = 12 }))
  end

  panel.render(ui.column({ padding = 16, gap = 12, flexGrow = 1 }, children))
end

function onOpen()
  status = state.migrate(noctalia.state.get(state.KEY_STATUS))
  snapshots = noctalia.state.get(state.KEY_SNAPSHOTS)
  preview = noctalia.state.get(state.KEY_JOB)
  ui_state.message = nil
  render()
end

function update()
  if status.phase == "running" then
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
  preview = value
  render()
end)
