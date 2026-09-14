--!nonstrict
-- Real render-tree assertions for the panel entry (Restic Snapshots 0.2.0, four tabs).
-- Run from the repo root:  lua5.4 tests/lua/panel_render_test.lua
--
-- [0.2.0] Updated for the new contract: four tabs (Log was added), the retention preview reads
-- keepCount / removeCount / remove (the old `groups` fixture is gone), and every string now comes
-- from translations/en.json through noctalia.tr.

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.install("plugin/restic-snapshots")

-- ── translations ─────────────────────────────────────────────────────────────
-- noctalia.tr resolves keys against translations/en.json, but the harness stub returns the key
-- unchanged, so a text assertion would only ever see "panel.action.restore". Read the real
-- catalogue and do the same {name} substitution, so the checks below assert the strings a user
-- actually sees.
-- REQUESTED holds the keys this workstream needs that en.json does not carry yet (translations are
-- owned by another workstream; they are listed in the final report). When a key lands in en.json,
-- that value wins and nothing here changes.

local REQUESTED = {
  ["panel.filter.newest"] = "Newest first",
  ["panel.filter.oldest"] = "Oldest first",
  ["panel.label.snapshot_count"] = "{shown} of {total} snapshots",
  ["panel.label.ago"] = "{age} ago",
  ["panel.label.installed"] = "installed",
  ["panel.row.meta"] = "{host} · {files} files · {size}",
  ["panel.retention.policy"] = "Keep: {last} last · {daily} daily · {weekly} weekly · {monthly} monthly",
  ["panel.retention.no_policy"] = "Set at least one keep-* rule in the plugin settings.",
  ["panel.prune.note"] = "Removal only runs after you confirm below.",
  ["panel.prune.truncated"] = "removal list truncated to the first {shown} snapshots",
  ["panel.restore.preview_missing"] = "Preview first: no restore preview is loaded for this snapshot.",
  ["panel.message.copied_id"] = "Copied snapshot id {id}",
  ["panel.logs.exit"] = "exit {code}",
  ["panel.diff.header"] = "Diff {from} → {to}",
  ["panel.diff.counts"] = "{added} added · {removed} removed · {changed} changed",
  ["panel.diff.no_previous"] = "No older snapshot to diff against.",
}

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

local function tr(key, subst)
  local template = CATALOGUE[key] or REQUESTED[key]
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

noctalia.tr = tr
noctalia.trp = function(key, count, subst)
  return tr(key, subst)
end

-- ── fixtures ─────────────────────────────────────────────────────────────────

H.stateValues["restic_status"] = {
  schema = 2,
  updatedAt = 1788874602,
  available = true,
  version = "0.19.1",
  repository = "/tmp/repo",
  repoConfigured = true,
  mode = "plugin",
  phase = "idle",
  busy = false,
  lastRun = { at = 1788874502, ok = true, files = 12, bytes = 4096, added = 2048 },
  nextRun = 1788878202,
  snapshotCount = 3,
  newestSnapshotAt = 1788873300,
  staleness = 40,
  stale = false,
  error = "",
}
-- Three snapshots on two hosts, the plugin's own ones tagged "noctalia" (the configured tag).
H.stateValues["restic_snapshots"] = {
  schema = 2,
  updatedAt = 1788874602,
  snapshots = {
    { id = "aaa111", shortId = "aaa11111", time = "2026-09-08T22:15:06+08:00", hostname = "host",
      tags = { "noctalia" }, paths = { "/tmp/data" }, filesProcessed = 4, bytesProcessed = 2048 },
    { id = "bbb222", shortId = "bbb22222", time = "2026-09-08T21:00:00+08:00", hostname = "nas",
      tags = {}, paths = { "/srv" }, filesProcessed = 3, bytesProcessed = 1024 },
    { id = "ccc333", shortId = "ccc33333", time = "2026-09-08T20:00:00+08:00", hostname = "host",
      tags = { "noctalia", "weekly" }, paths = { "/etc" }, filesProcessed = 9, bytesProcessed = 4096 },
  },
}

H.load("panel.luau")

local failures = 0
local function check(name, condition, detail)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
  end
end

-- Any node by its exact key: the filter select, the text input, the tab chips and the action
-- buttons all key their nodes so the render tree can be driven from a test.
local function nodeByKey(key)
  return H.find(H.tree, function(node)
    return type(node.props) == "table" and node.props.key == key
  end)
end

local function rowCount()
  return #H.findAll(H.tree, H.byKey("row-"))
end

local function lastCommand()
  return table.concat(H.commands[#H.commands] or {}, " ")
end

local function publish(key, value)
  H.stateValues[key] = value
  local watch = H.stateValues["__watch_" .. key]
  if watch ~= nil then
    watch(value)
  end
end

local function clickTab(id)
  local chip = nodeByKey("tab-" .. id)
  if chip == nil then
    error("no tab chip for " .. id)
  end
  chip.props.onClick()
end

onOpen()

-- ── snapshots tab ────────────────────────────────────────────────────────────

local text = H.text(H.tree)
check("panel renders a header", text:find("Restic Snapshots", 1, true) ~= nil, text)
check("panel shows the repository", text:find("/tmp/repo", 1, true) ~= nil)
check("panel has four tabs", text:find("Snapshots", 1, true) ~= nil and text:find("Run", 1, true) ~= nil
  and text:find("Retention", 1, true) ~= nil and text:find("Log", 1, true) ~= nil, text)
check("log tab chip exists", nodeByKey("tab-log") ~= nil)
check("snapshot list shows a timestamp", text:find("2026-09-08", 1, true) ~= nil, text)
check("snapshot list shows tags", text:find("noctalia", 1, true) ~= nil, text)
check("snapshot row shows host, file count and size",
  text:find("nas · 3 files · 1.0 KiB", 1, true) ~= nil, text)

local restoreButtons = H.findAll(H.tree, function(node)
  return node.type == "button" and node.props.text == "Restore"
end)
check("each snapshot has a visible restore button", #restoreButtons == 3, "#restore=" .. #restoreButtons)
check("each snapshot has a dots menu button",
  #H.findAll(H.tree, H.byKey("menu-")) == 3)

-- The filter select offers the three documented options.
local select = nodeByKey("filter-select")
check("filter select exists", select ~= nil)
check("filter select offers three options", select ~= nil and #select.props.options == 3,
  select ~= nil and table.concat(select.props.options, "/"))
check("filter select names the configured tag",
  select ~= nil and select.props.options[3] == "tagged noctalia", select ~= nil and select.props.options[3])
check("filter starts on all snapshots", select ~= nil and select.props.selectedIndex == 0)

-- ── context menu ─────────────────────────────────────────────────────────────

local dots = nodeByKey("menu-aaa111")
check("dots button keyed by snapshot id exists", dots ~= nil)
dots.props.onClick()
local request = H.contextMenu
check("dots click opens a context menu", request ~= nil)
check("context menu activates onContextAction", request ~= nil and request.onActivate == "onContextAction",
  request ~= nil and request.onActivate)
check("context menu carries the snapshot id", request ~= nil and request.context == "aaa111")
check("context menu is bounded to 12 rows", request ~= nil and request.maxVisible == 12)
local ids = {}
for _, item in ipairs(request ~= nil and request.items or {}) do
  if item.id ~= nil then
    table.insert(ids, item.id)
  end
end
check("context menu has the six frozen items",
  table.concat(ids, ",") == "restore_preview,restore,files,diff_prev,copy_id,forget_one", table.concat(ids, ","))
check("context menu labels come from the frozen keys",
  request.items[1].label == "Preview restore" and request.items[4].label == "Files"
    and request.items[6].label == "Copy snapshot id" and request.items[8].label == "Forget this snapshot",
  request.items[1].label)

H.contextMenu = nil
dots.props.onRightClick()
check("dots right-click opens the same menu",
  H.contextMenu ~= nil and H.contextMenu.context == "aaa111")
check("onContextAction is a global the host can call", type(onContextAction) == "function")

-- ── restore: preview first, confirm second ───────────────────────────────────

check("no restore confirm before any preview", nodeByKey("restore-confirm") == nil)

nodeByKey("restore-aaa111").props.onClick()
check("restore click sends a dry run", lastCommand():find("restore-dry-run", 1, true) ~= nil, lastCommand())
check("restore dry run names the snapshot and target",
  lastCommand():find("aaa111", 1, true) ~= nil and lastCommand():find("/tmp/restore", 1, true) ~= nil,
  lastCommand())
check("no confirm while the preview is missing", nodeByKey("restore-confirm") == nil)
check("the drawer says the preview is missing",
  H.text(H.tree):find("Preview first: no restore preview", 1, true) ~= nil, H.text(H.tree))

publish("restic_job", {
  kind = "restore-dry", at = 1788874602, ok = true,
  snapshot = "aaa111", target = "/tmp/restore", files = 42,
})
text = H.text(H.tree)
check("preview header states files and target",
  text:find("would restore 42 files into /tmp/restore", 1, true) ~= nil, text)
check("confirm appears only after the preview", nodeByKey("restore-confirm") ~= nil)
check("confirm names the target", text:find("Confirm: restore into /tmp/restore", 1, true) ~= nil, text)

local before = #H.commands
nodeByKey("restore-confirm").props.onClick()
check("confirm sends the real restore",
  lastCommand():find("restore", 1, true) ~= nil and lastCommand():find("restore-dry-run", 1, true) == nil,
  lastCommand())
check("the confirm button is gone after the restore", nodeByKey("restore-confirm") == nil)
check("confirming sent exactly one extra command", #H.commands == before + 1, tostring(#H.commands - before))

-- A failed preview must never reveal the confirm.
nodeByKey("restore-aaa111").props.onClick()
publish("restic_job", { kind = "restore-dry", at = 1788874602, ok = false, snapshot = "aaa111", files = 0 })
check("a failed preview keeps the confirm hidden", nodeByKey("restore-confirm") == nil)
check("a failed preview says so",
  H.text(H.tree):find("Preview failed", 1, true) ~= nil, H.text(H.tree))

-- The menu's "Restore now" reaches the confirm step without re-running the preview.
publish("restic_job", {
  kind = "restore-dry", at = 1788874602, ok = true,
  snapshot = "aaa111", target = "/tmp/restore", files = 42,
})
before = #H.commands
onContextAction("restore", "aaa111")
check("restore now reveals the confirm from a loaded preview", nodeByKey("restore-confirm") ~= nil)
check("restore now does not re-run the preview", #H.commands == before, tostring(#H.commands - before))

-- Copy id uses the clipboard; nothing else.
H.clipboard = nil
onContextAction("copy_id", "aaa111")
check("copy snapshot id uses the clipboard", H.clipboard == "aaa111", tostring(H.clipboard))
check("copy snapshot id confirms in the panel",
  H.text(H.tree):find("Copied snapshot id aaa111", 1, true) ~= nil, H.text(H.tree))

-- Files: the request goes out, the listing comes back bounded.
before = #H.commands
onContextAction("files", "aaa111")
check("files asks for a listing",
  lastCommand():find("ls", 1, true) ~= nil and lastCommand():find("aaa111", 1, true) ~= nil, lastCommand())
publish("restic_files", {
  snapshot = "aaa111", at = 1788874602, ok = true, truncated = true,
  entries = {
    { path = "/tmp/data/a.txt", type = "file", size = 2048 },
    { path = "/tmp/data/b.txt", type = "file", size = 1024 },
  },
})
text = H.text(H.tree)
check("files listing renders paths", text:find("/tmp/data/a.txt", 1, true) ~= nil, text)
check("files listing renders sizes", text:find("1.0 KiB", 1, true) ~= nil, text)
check("files listing announces truncation", text:find("listing truncated", 1, true) ~= nil, text)

-- Diff with previous: the older neighbour in publication order.
before = #H.commands
onContextAction("diff_prev", "aaa111")
check("diff uses the older neighbour",
  lastCommand():find("diff", 1, true) ~= nil and lastCommand():find("bbb222", 1, true) ~= nil
    and lastCommand():find("aaa111", 1, true) ~= nil, lastCommand())
publish("restic_diff", {
  from = "bbb222", to = "aaa111", added = 3, removed = 1, changed = 2,
  truncated = false, at = 1788874602, ok = true,
})
check("diff renders its counts",
  H.text(H.tree):find("3 added · 1 removed · 2 changed", 1, true) ~= nil, H.text(H.tree))
onContextAction("diff_prev", "ccc333")
check("diff with no older snapshot says so",
  H.text(H.tree):find("No older snapshot to diff against", 1, true) ~= nil, H.text(H.tree))

-- ── forget one: two-step, names the id ───────────────────────────────────────

onContextAction("forget_one", "bbb222")
check("forget one asks for a second click", nodeByKey("forget-confirm") ~= nil)
check("forget confirm names the snapshot id",
  H.text(H.tree):find("Confirm: forget bbb222", 1, true) ~= nil, H.text(H.tree))
check("forget one sends nothing before the confirm",
  lastCommand():find("forget-one", 1, true) == nil, lastCommand())
nodeByKey("forget-confirm").props.onClick()
check("forget confirm sends forget-one with the id",
  lastCommand():find("forget-one", 1, true) ~= nil and lastCommand():find("bbb222", 1, true) ~= nil, lastCommand())
check("the forget confirmation is gone afterwards", nodeByKey("forget-confirm") == nil)

-- A pending confirmation must not survive a tab switch.
onContextAction("forget_one", "aaa111")
check("forget confirmation is pending", nodeByKey("forget-confirm") ~= nil)
clickTab("run")
clickTab("snapshots")
check("a tab switch drops the pending forget confirmation", nodeByKey("forget-confirm") == nil)

-- ── filtering and sorting ────────────────────────────────────────────────────

check("all three snapshots render by default", rowCount() == 3, tostring(rowCount()))
nodeByKey("filter-select").props.onChange("1")
check("this host only hides the other host", rowCount() == 2, tostring(rowCount()))
nodeByKey("filter-select").props.onChange("2")
check("tagged filter keeps the tagged snapshots", rowCount() == 2, tostring(rowCount()))
nodeByKey("filter-select").props.onChange("0")
check("back to all snapshots", rowCount() == 3, tostring(rowCount()))

nodeByKey("filter-text").props.onChange("nas")
check("the text filter narrows the rows", rowCount() == 1, tostring(rowCount()))
check("the text filter keeps the right row",
  H.text(H.tree):find("bbb222", 1, true) ~= nil, H.text(H.tree))
nodeByKey("filter-text").props.onChange("")
check("clearing the text filter restores the rows", rowCount() == 3, tostring(rowCount()))

local order = H.findAll(H.tree, H.byKey("row-"))
check("rows start newest first", order[1].props.key == "row-aaa111", order[1].props.key)
nodeByKey("sort").props.onClick()
order = H.findAll(H.tree, H.byKey("row-"))
check("the sort toggle reverses the order", order[1].props.key == "row-ccc333", order[1].props.key)
nodeByKey("sort").props.onClick()
order = H.findAll(H.tree, H.byKey("row-"))
check("the sort toggle goes back to newest first", order[1].props.key == "row-aaa111", order[1].props.key)

-- ── run tab ──────────────────────────────────────────────────────────────────

clickTab("run")
check("switching to the run tab asks for stats", lastCommand():find("stats", 1, true) ~= nil, lastCommand())
text = H.text(H.tree)
check("run tab shows a backup button", text:find("Back up now", 1, true) ~= nil, text)
check("run tab shows the last run", text:find("Last run succeeded", 1, true) ~= nil, text)
check("run tab shows the next run", text:find("Next scheduled run", 1, true) ~= nil, text)
check("run tab has no stats card until stats are published", nodeByKey("stats-refresh") == nil)

publish("restic_stats", {
  totalBytes = 2048, totalFileCount = 7, snapshotsCount = 3,
  updatedAt = 1788874602, ok = true,
})
text = H.text(H.tree)
check("stats card shows the repository size",
  text:find("Repository size", 1, true) ~= nil and text:find("2.0 KiB", 1, true) ~= nil, text)
check("stats card shows the file count",
  text:find("Files in repository", 1, true) ~= nil and text:find("7", 1, true) ~= nil, text)
check("stats card shows the snapshot count",
  text:find("Snapshots in repository", 1, true) ~= nil and text:find("3", 1, true) ~= nil, text)

nodeByKey("stats-refresh").props.onClick()
check("stats refresh asks the service", lastCommand():find("stats", 1, true) ~= nil, lastCommand())

-- Every unavailable action states exactly why.
H.stateValues["restic_status"].available = false
render()
check("no binary states why", H.text(H.tree):find("restic is not installed", 1, true) ~= nil, H.text(H.tree))
check("no binary disables the backup button", nodeByKey("backup").props.enabled == false)
H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].repoConfigured = false
render()
check("no repository states why",
  H.text(H.tree):find("Set the repository and password file", 1, true) ~= nil, H.text(H.tree))
H.stateValues["restic_status"].repoConfigured = true
H.stateValues["restic_status"].mode = "observe"
render()
check("observe mode states why", H.text(H.tree):find("observe mode", 1, true) ~= nil, H.text(H.tree))
H.stateValues["restic_status"].mode = "plugin"
H.config.backup_paths = {}
render()
check("no backup paths states why",
  H.text(H.tree):find("No backup paths are configured", 1, true) ~= nil, H.text(H.tree))
check("no backup paths disables the backup button", nodeByKey("backup").props.enabled == false)
H.config.backup_paths = { "/tmp/data" }
render()
check("a configured plugin offers an enabled backup button", nodeByKey("backup").props.enabled == true)

-- Initialise and stale lock.
H.stateValues["restic_status"].initNeeded = true
render()
check("init button appears when the repository is not initialised", nodeByKey("init") ~= nil)
check("init explains itself",
  H.text(H.tree):find("Initialise it to start backing up", 1, true) ~= nil, H.text(H.tree))
H.stateValues["restic_status"].initNeeded = false
H.stateValues["restic_status"].error = "repository is locked by another restic process"
render()
check("a lock offers the unlock button", nodeByKey("unlock") ~= nil)
check("the lock reason is shown",
  H.text(H.tree):find("locked by another restic process", 1, true) ~= nil, H.text(H.tree))
H.stateValues["restic_status"].error = ""
render()
check("no unlock button when nothing is locked", nodeByKey("unlock") == nil)

-- A cancelled run is not a failure.
H.stateValues["restic_status"].lastRun = { at = 1788874502, ok = false, cancelled = true, files = 2, bytes = 1024, added = 512 }
render()
check("run tab distinguishes a cancelled run",
  H.text(H.tree):find("Last run cancelled", 1, true) ~= nil, H.text(H.tree))
H.stateValues["restic_status"].lastRun = { at = 1788874502, ok = false, files = 2, bytes = 1024, added = 512 }
render()
check("run tab distinguishes a failed run",
  H.text(H.tree):find("Last run failed", 1, true) ~= nil, H.text(H.tree))

-- Running state replaces the controls with live progress.
H.stateValues["restic_status"].phase = "running"
H.stateValues["restic_status"].busy = true
H.stateValues["restic_status"].job = { kind = "backup", percent = 0.5, filesDone = 2, totalFiles = 4,
  bytesDone = 1024, totalBytes = 2048 }
render()
text = H.text(H.tree)
check("running shows a progress bar", H.find(H.tree, H.byType("progress")) ~= nil)
check("running shows the percent", text:find("50%", 1, true) ~= nil, text)
check("running shows files and bytes", text:find("2 / 4", 1, true) ~= nil and text:find("1.0 KiB / 2.0 KiB", 1, true) ~= nil, text)
check("running offers cancel", nodeByKey("cancel") ~= nil, text)
nodeByKey("cancel").props.onClick()
check("cancel asks the service to cancel", lastCommand():find("cancel", 1, true) ~= nil, lastCommand())
H.stateValues["restic_status"].phase = "idle"
H.stateValues["restic_status"].busy = false
H.stateValues["restic_status"].job = nil
render()

-- ── log tab ──────────────────────────────────────────────────────────────────

publish("restic_joblog", {
  kind = "backup", at = 1788874500, ok = false, cancelled = false, exitCode = 1,
  lines = { "saved 12 files", "error: repository is already locked" },
  truncated = true,
})
clickTab("log")
text = H.text(H.tree)
check("log header names the job kind", text:find("backup", 1, true) ~= nil, text)
check("log header shows the verdict", text:find("failed", 1, true) ~= nil, text)
check("log header shows the exit code", text:find("exit 1", 1, true) ~= nil, text)
check("log tab renders the tail lines",
  text:find("saved 12 files", 1, true) ~= nil and text:find("error: repository is already locked", 1, true) ~= nil, text)
check("log lines render inside a scroll",
  H.find(H.tree, function(node) return node.type == "scroll" and node.props.key == "joblog" end) ~= nil)
check("log tab announces truncation", text:find("log truncated to the last 2 lines", 1, true) ~= nil, text)
nodeByKey("logs-refresh").props.onClick()
check("log refresh asks for a republish", lastCommand():find("job-log", 1, true) ~= nil, lastCommand())

-- A cancelled job reads as cancelled, not as a failure.
publish("restic_joblog", {
  kind = "backup", at = 1788874500, ok = false, cancelled = true, exitCode = 130,
  lines = { "backup cancelled" }, truncated = false,
})
text = H.text(H.tree)
check("a cancelled job reads as cancelled", text:find("cancelled", 1, true) ~= nil, text)
check("no truncation notice when nothing was dropped", text:find("log truncated", 1, true) == nil, text)

-- ── retention tab ────────────────────────────────────────────────────────────

publish("restic_job", nil)
clickTab("retention")
text = H.text(H.tree)
check("retention shows the policy", text:find("Keep: 7 last", 1, true) ~= nil, text)
check("retention offers a preview", text:find("Preview removal", 1, true) ~= nil, text)
check("no prune button before a preview", nodeByKey("prune") == nil)

-- The preview shape is the service's (restic.summariseForgetDry output); the old `groups` fixture
-- is gone and the panel must NOT re-sum anything.
publish("restic_job", {
  kind = "forget-dry", at = 1788874602, ok = true,
  keepCount = 2, removeCount = 2,
  remove = {
    { id = "ddd444", shortId = "ddd44444", time = "2026-09-01T10:00:00+08:00" },
    { id = "eee555", shortId = "eee55555", time = "2026-09-02T10:00:00+08:00" },
  },
  truncated = true,
})
text = H.text(H.tree)
check("preview counts keep and remove", text:find("Would keep 2, remove 2", 1, true) ~= nil, text)
check("preview lists the snapshots that would go",
  text:find("ddd44444", 1, true) ~= nil and text:find("2026-09-01T10:00:00+08:00", 1, true) ~= nil
    and text:find("eee55555", 1, true) ~= nil, text)
check("preview list truncation is announced",
  text:find("removal list truncated", 1, true) ~= nil, text)
check("preview explains that nothing runs yet",
  text:find("Removal only runs after you confirm below", 1, true) ~= nil, text)

local prune = nodeByKey("prune")
check("prune appears after the preview", prune ~= nil)
check("prune starts as the first step", prune.props.text == "Prune now", prune.props.text)
prune.props.onClick()
check("first prune click asks for confirmation",
  H.text(H.tree):find("Confirm: prune 2 snapshots", 1, true) ~= nil, H.text(H.tree))

clickTab("snapshots")
clickTab("retention")
check("a tab switch drops the pending prune confirmation",
  H.text(H.tree):find("Confirm: prune", 1, true) == nil, H.text(H.tree))

-- A failed preview never offers prune.
publish("restic_job", { kind = "forget-dry", at = 1788874602, ok = false })
text = H.text(H.tree)
check("a failed preview says so", text:find("Preview failed", 1, true) ~= nil, text)
check("a failed preview offers no prune", nodeByKey("prune") == nil)

-- No policy: nothing to preview.
H.config.keep_last = 0
H.config.keep_daily = 0
H.config.keep_weekly = 0
H.config.keep_monthly = 0
render()
check("an empty policy says so",
  H.text(H.tree):find("Set at least one keep-* rule", 1, true) ~= nil, H.text(H.tree))
check("an empty policy offers no preview", nodeByKey("preview") == nil)
H.config.keep_last = 7
H.config.keep_daily = 7
H.config.keep_weekly = 4
H.config.keep_monthly = 6
render()

-- ── empty states ─────────────────────────────────────────────────────────────

H.stateValues["restic_status"].lastRun = nil
clickTab("run")
check("run tab says when no run was recorded",
  H.text(H.tree):find("No run recorded yet", 1, true) ~= nil, H.text(H.tree))
H.stateValues["restic_status"].lastRun = { at = 1788874502, ok = true, files = 12, bytes = 4096, added = 2048 }

publish("restic_snapshots", { schema = 2, updatedAt = 0, snapshots = {} })
clickTab("snapshots")
text = H.text(H.tree)
check("an empty repository shows the empty state", text:find("No snapshots yet", 1, true) ~= nil, text)
check("an empty repository renders no rows", rowCount() == 0, tostring(rowCount()))

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
