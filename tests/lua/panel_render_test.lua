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
-- [0.4.0] The LEFT click can never open the native menu: the host refuses panel.openContextMenu
-- outside a live pointer context (src/scripting/plugin_bindings.cpp returns false) and the API doc
-- names onRightClick as its only legal caller (docs/CONTRACTS-0.4.0.md 1.2). So the menu is
-- asserted through the right click -- the one pointer context that works -- and the left click's
-- in-panel sheet is asserted in its own section at the end of this file. This check used to read
-- "dots click opens a context menu", which asserted the defect the contract removes.
dots.props.onRightClick()
local request = H.contextMenu
check("the dots button opens the native context menu", request ~= nil)
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

-- ── run tab: the last check and the last verification (0.3.0) ────────────────
-- status.checks = { lastAt, lastOk, numErrors } and status.verify = { lastAt, lastOk, checked,
-- matched, failed, detail } are the published shapes (lib/state.luau, contract 5.2). Neither was
-- rendered before 0.3.0: a check that reported errors only ever appeared in the Log tab, and a
-- verification result existed nowhere in the UI at all.

local function nodeText(key)
  local node = nodeByKey(key)
  if node == nil then
    return nil
  end
  return tostring(node.props.text)
end

-- Never checked, never verified: both lines say so, and the button is offered from the start (an
-- empty result must not be the only way to ask for one).
H.stateValues["restic_status"].checks = nil
H.stateValues["restic_status"].verify = nil
render()
check("run tab says a check has never run",
  nodeText("checks-value") == "never", tostring(nodeText("checks-value")))
check("run tab labels the check line from the frozen key",
  H.text(H.tree):find("Last check", 1, true) ~= nil, H.text(H.tree))
check("run tab says nothing was ever verified",
  nodeText("verify-verdict") == "never", tostring(nodeText("verify-verdict")))
check("run tab labels the verification line from the frozen key",
  H.text(H.tree):find("Last verified", 1, true) ~= nil, H.text(H.tree))
check("no counts line before a verification", nodeByKey("verify-counts") == nil)
check("no detail line before a verification", nodeByKey("verify-detail") == nil)

local verifyButton = nodeByKey("verify-now")
check("the verify button exists", verifyButton ~= nil)
check("the verify button reads from the frozen key",
  verifyButton ~= nil and verifyButton.props.text == "Verify restore", verifyButton ~= nil and verifyButton.props.text)
check("the verify button is enabled when a verification can run",
  verifyButton ~= nil and verifyButton.props.enabled == true)

local beforeVerify = #H.commands
verifyButton.props.onClick()
local verifyArgv = H.commands[#H.commands] or {}
check("the verify button sends verify-restore",
  table.concat(verifyArgv, " "):find("verify-restore", 1, true) ~= nil, table.concat(verifyArgv, " "))
check("verify sent exactly one command", #H.commands == beforeVerify + 1, tostring(#H.commands - beforeVerify))
check("verify sends no payload", #verifyArgv == 6, table.concat(verifyArgv, " "))

H.stateValues["restic_status"].available = false
render()
check("the verify button is disabled without restic", nodeByKey("verify-now").props.enabled == false)
H.stateValues["restic_status"].available = true
H.stateValues["restic_status"].repoConfigured = false
render()
check("the verify button is disabled without a repository", nodeByKey("verify-now").props.enabled == false)
H.stateValues["restic_status"].repoConfigured = true
render()

-- A passed verification: when it ran, that it passed, and the counts.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = true, checked = 4, matched = 4, failed = 0,
  detail = "4 of 4 files matched",
}
render()
check("a passed verification renders when it ran and that it passed",
  nodeText("verify-verdict") == "6m ago · ok", tostring(nodeText("verify-verdict")))
check("a passed verification renders its counts",
  nodeText("verify-counts") == "4 of 4 files matched", tostring(nodeText("verify-counts")))
check("a passed verification is not coloured as a failure",
  nodeByKey("verify-verdict").props.color == "on_surface", nodeByKey("verify-verdict").props.color)
check("a clean pass repeats nothing in a detail line", nodeByKey("verify-detail") == nil)

-- A failed verification: a failure, in the error colour, with the mismatch detail the service sent.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = false, checked = 3, matched = 1, failed = 2,
  detail = "2 of 3 checked files do not match the backup: /home/ian/dots/x: differs",
}
render()
check("a failed verification renders as failed",
  nodeText("verify-verdict") == "6m ago · failed", tostring(nodeText("verify-verdict")))
check("a failed verification uses the error colour",
  nodeByKey("verify-verdict").props.color == "error", nodeByKey("verify-verdict").props.color)
check("a failed verification renders the matched count",
  nodeText("verify-counts") == "1 of 3 files matched", tostring(nodeText("verify-counts")))
check("a failed verification renders the failed count as its own line",
  nodeText("verify-failed") == "2 of 3 files did not match", tostring(nodeText("verify-failed")))
check("a failed verification names the mismatch",
  H.text(H.tree):find("do not match the backup: /home/ian/dots/x", 1, true) ~= nil, H.text(H.tree))
check("the failed detail is coloured as a failure",
  nodeByKey("verify-detail").props.color == "error", nodeByKey("verify-detail").props.color)

-- The honesty case: checked > 0 but nothing was compared (every file skipped, because the live copy
-- legitimately changed or was gone). The service publishes lastOk = true for this on purpose, and the
-- panel must NOT read that as a verification.
local SKIPPED_DETAIL = "3 file(s) restored and read back, but none could be compared with a live file"
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = true, checked = 3, matched = 0, failed = 0,
  detail = SKIPPED_DETAIL,
}
render()
check("an all-skipped verification shows the counts as zero matched",
  nodeText("verify-counts") == "0 of 3 files matched", tostring(nodeText("verify-counts")))
check("an all-skipped verification does not claim a success verdict",
  nodeText("verify-verdict") == "6m ago", tostring(nodeText("verify-verdict")))
check("an all-skipped verification is not coloured as a success",
  nodeByKey("verify-counts").props.color == "tertiary", nodeByKey("verify-counts").props.color)
check("an all-skipped verification shows the service's own detail sentence",
  H.text(H.tree):find(SKIPPED_DETAIL, 1, true) ~= nil, H.text(H.tree))
check("an all-skipped verification never reads as N verified",
  H.text(H.tree):find("3 of 3 files matched", 1, true) == nil
    and H.text(H.tree):find("files verified", 1, true) == nil, H.text(H.tree))

-- Nothing could be checked at all: a failure with a reason, and no "0 of 0 files matched" line that
-- would read like a pass.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = false, checked = 0, matched = 0, failed = 0,
  detail = "there is no snapshot to verify",
}
render()
check("a verification that could not run reads as failed",
  nodeText("verify-verdict") == "6m ago · failed", tostring(nodeText("verify-verdict")))
check("a verification that could not run renders no counts line", nodeByKey("verify-counts") == nil)
check("a verification that could not run shows the reason",
  H.text(H.tree):find("there is no snapshot to verify", 1, true) ~= nil, H.text(H.tree))

-- Exactly the checked - matched - failed arithmetic: 5 checked, 2 matched, 1 failed, 2 skipped. The
-- frozen shape carries no `skipped` field and en.json has no key for one (reported to the lead:
-- `panel.label.verified_skipped` does not exist), so the panel states the two counts it has and the
-- remainder is the difference between them.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = true, checked = 5, matched = 2, failed = 1,
  detail = "1 of 5 checked files do not match the backup: /home/ian/dots/y",
}
render()
check("a partly failed verification reports the matched count",
  nodeText("verify-counts") == "2 of 5 files matched", tostring(nodeText("verify-counts")))
check("a partly failed verification reports the failed count",
  nodeText("verify-failed") == "1 of 5 files did not match", tostring(nodeText("verify-failed")))

-- While a job is in flight the button is disabled (not hidden) and the last result stays readable.
H.stateValues["restic_status"].verify = {
  lastAt = 1788874202, lastOk = true, checked = 4, matched = 4, failed = 0, detail = "",
}
H.stateValues["restic_status"].phase = "running"
H.stateValues["restic_status"].busy = true
render()
check("the verify button is disabled while a job is in flight",
  nodeByKey("verify-now").props.enabled == false)
check("the last verification stays rendered while a job is in flight",
  nodeText("verify-counts") == "4 of 4 files matched", tostring(nodeText("verify-counts")))
H.stateValues["restic_status"].phase = "idle"
H.stateValues["restic_status"].busy = false
render()

-- The integrity check: when it last ran and what it found.
H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = true, numErrors = 0 }
render()
check("the check line renders when it ran and that it passed",
  nodeText("checks-value") == "1h ago · ok", tostring(nodeText("checks-value")))
check("a passing check is not coloured as a problem",
  nodeByKey("checks-value").props.color == "on_surface", nodeByKey("checks-value").props.color)

H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = false, numErrors = 3 }
render()
check("a check that reported errors reads as failed",
  nodeText("checks-value") == "1h ago · failed · 3 errors", tostring(nodeText("checks-value")))
check("a check that reported errors uses the error colour",
  nodeByKey("checks-value").props.color == "error", nodeByKey("checks-value").props.color)

-- An error count beside a lastOk of true must still not read as green: "ok · 3 errors" would
-- contradict itself.
H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = true, numErrors = 3 }
render()
check("errors outrank a lastOk of true",
  nodeText("checks-value") == "1h ago · failed · 3 errors", tostring(nodeText("checks-value")))
check("an errored check is never green",
  nodeByKey("checks-value").props.color == "error", nodeByKey("checks-value").props.color)

H.stateValues["restic_status"].checks = { lastAt = 1788871002, lastOk = false }
render()
check("a check with no summary and no errors still reads as failed",
  nodeText("checks-value") == "1h ago · failed", tostring(nodeText("checks-value")))

-- ── diff: the changed paths (0.3.0) ──────────────────────────────────────────
-- KEY_DIFF used to render counts only. The paths come from restic.parseDiff as addedPaths /
-- removedPaths / changedPaths and are bounded exactly like the file listing: MAX_DIFF_ROWS rows, and
-- whatever was left out is stated.

clickTab("snapshots")

local function diffPaths(count, prefix)
  local list = {}
  for index = 1, count do
    table.insert(list, string.format("%s/p%d.txt", prefix, index))
  end
  return list
end

publish("restic_diff", {
  from = "bbb222", to = "aaa111", added = 1, removed = 1, changed = 1,
  truncated = false, at = 1788874602, ok = true,
  addedPaths = { "/tmp/data/new.txt" },
  removedPaths = { "/srv/gone.txt" },
  changedPaths = { "/etc/hosts" },
})
text = H.text(H.tree)
check("diff renders the changed paths heading",
  text:find("Changed paths", 1, true) ~= nil, text)
check("diff lists an added path", text:find("/tmp/data/new.txt", 1, true) ~= nil, text)
check("diff lists a removed path", text:find("/srv/gone.txt", 1, true) ~= nil, text)
check("diff lists a changed path", text:find("/etc/hosts", 1, true) ~= nil, text)
local pathRows = H.findAll(H.tree, H.byKey("diff-path-"))
check("diff renders one row per path", #pathRows == 3, tostring(#pathRows))
check("diff markers name the direction",
  pathRows[1].children[1].props.text == "+" and pathRows[2].children[1].props.text == "-"
    and pathRows[3].children[1].props.text == "~",
  pathRows[1].children[1].props.text .. pathRows[2].children[1].props.text .. pathRows[3].children[1].props.text)
check("diff does not announce a cut when nothing was dropped",
  nodeByKey("diff-more") == nil and nodeByKey("diff-truncated") == nil)

-- More paths than the bound: the list is cut and the panel says how many it left out.
local many = diffPaths(15, "/tmp/data/many")
publish("restic_diff", {
  from = "bbb222", to = "aaa111", added = 15, removed = 0, changed = 0,
  truncated = false, at = 1788874602, ok = true,
  addedPaths = many, removedPaths = {}, changedPaths = {},
})
pathRows = H.findAll(H.tree, H.byKey("diff-path-"))
check("the diff path list is bounded to 12 rows", #pathRows == 12, tostring(#pathRows))
check("the diff says how many paths it left out",
  nodeText("diff-more") == "and 3 more", tostring(nodeText("diff-more")))
check("a bounded diff list is not also announced as parser-truncated", nodeByKey("diff-truncated") == nil)
check("the dropped paths are absent from the tree",
  H.text(H.tree):find("many/p13.txt", 1, true) == nil, "p13 leaked into the tree")

-- truncated = true with everything the panel was handed already shown: the parser dropped paths, so
-- how many are missing is unknown and the panel states only the number it listed.
publish("restic_diff", {
  from = "bbb222", to = "aaa111", added = 2, removed = 0, changed = 0,
  truncated = true, at = 1788874602, ok = true,
  addedPaths = { "/tmp/data/a.txt", "/tmp/data/b.txt" }, removedPaths = {}, changedPaths = {},
})
check("a parser-truncated diff list is announced",
  nodeText("diff-truncated") == "listing truncated to the first 2 entries", tostring(nodeText("diff-truncated")))
check("a parser-truncated diff list names no invented remainder", nodeByKey("diff-more") == nil)
check("a parser-truncated diff still lists what it has",
  H.text(H.tree):find("/tmp/data/b.txt", 1, true) ~= nil, H.text(H.tree))

-- The paths may arrive under the count names instead; the counts then come from the lists themselves
-- rather than rendering "table: 0x...".
publish("restic_diff", {
  from = "bbb222", to = "aaa111", truncated = false, at = 1788874602, ok = true,
  added = { "/tmp/data/under-count.txt" }, removed = {}, changed = {},
})
text = H.text(H.tree)
check("diff reads paths published under the count names",
  text:find("/tmp/data/under-count.txt", 1, true) ~= nil, text)
check("diff counts a list published under a count name",
  nodeText("diff-counts") == "1 added · 0 removed · 0 changed", tostring(nodeText("diff-counts")))

-- ── "this host only" reads /etc/hostname (0.3.0) ─────────────────────────────
-- The old filter inferred the host from the newest tagged snapshot. restic records the host of the
-- machine that MADE a snapshot, and one repository can hold snapshots from several machines, so the
-- inference could silently select the wrong host. /etc/hostname is the machine's own answer.

nodeByKey("filter-select").props.onChange("1")
H.files["/etc/hostname"] = nil
render()
check("this host only falls back to the inference when /etc/hostname is unreadable",
  rowCount() == 2, tostring(rowCount()))
H.files["/etc/hostname"] = "\n"
render()
check("this host only falls back when /etc/hostname is blank", rowCount() == 2, tostring(rowCount()))
H.files["/etc/hostname"] = "cachyos-x8664\n"
render()
check("this host only uses /etc/hostname, not a snapshot's hostname",
  rowCount() == 0, tostring(rowCount()))
H.files["/etc/hostname"] = "nas\n"
render()
check("this host only trims and matches the file exactly",
  rowCount() == 1, tostring(rowCount()))
check("this host only keeps the row the file names",
  H.text(H.tree):find("bbb222", 1, true) ~= nil, H.text(H.tree))
H.files["/etc/hostname"] = "/etc/hostname's own host\n" -- never a hostname a snapshot carries
render()
check("a rowless hostname is not silently ignored", rowCount() == 0, tostring(rowCount()))
H.files["/etc/hostname"] = nil
nodeByKey("filter-select").props.onChange("0")
check("back to all snapshots after the hostname checks", rowCount() == 3, tostring(rowCount()))

-- ── log tab ──────────────────────────────────────────────────────────────────
--
-- [0.4.0] The service publishes WHERE the log is (logPath) and nothing else, so the tab reads the
-- file itself. These checks drive the header, the scroll and the refresh button; the Formatted/Raw
-- rendering over the real fixtures, the malformed-log behaviour, the read bound and the cache each
-- get their own section at the end of this file.

local FIRST_LOG_PATH = "/tmp/restic-data/jobs/first.jsonl"
H.files[FIRST_LOG_PATH] = "saved 12 files\nerror: repository is already locked\n"
H.mtimes[FIRST_LOG_PATH] = 1000
publish("restic_joblog", {
  kind = "backup", at = 1788874500, ok = false, cancelled = false, exitCode = 1,
  logPath = FIRST_LOG_PATH,
})
clickTab("log")
text = H.text(H.tree)
check("log header names the job kind", text:find("backup", 1, true) ~= nil, text)
check("log header shows the verdict", text:find("failed", 1, true) ~= nil, text)
check("log header shows the exit code", text:find("exit 1", 1, true) ~= nil, text)
check("log tab renders the log the payload points at",
  text:find("saved 12 files", 1, true) ~= nil
    and text:find("error: repository is already locked", 1, true) ~= nil, text)
check("log lines render inside a scroll",
  H.find(H.tree, function(node) return node.type == "scroll" and node.props.key == "joblog" end) ~= nil)
check("a log this small is not announced as truncated", nodeByKey("joblog-truncated") == nil, text)
nodeByKey("logs-refresh").props.onClick()
check("log refresh asks for a republish", lastCommand():find("job-log", 1, true) ~= nil, lastCommand())

-- A cancelled job reads as cancelled, not as a failure.
publish("restic_joblog", {
  kind = "backup", at = 1788874500, ok = false, cancelled = true, exitCode = 130,
  logPath = FIRST_LOG_PATH,
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

-- ── [0.4.0] the snapshot action sheet (left click) ───────────────────────────
-- The host refuses panel.openContextMenu outside a live pointer context
-- (src/scripting/plugin_bindings.cpp) and the API doc names onRightClick as its only legal caller,
-- so a left click on the dots can never open the native menu. It opens a sheet the PANEL renders,
-- beneath the row. The right-click path is unchanged (asserted above).

-- The same three rows as the fixture near the top of this file (the empty-state check emptied the
-- list), rebuilt per call so one check can vary a single field without touching another.
local function publishRows(mutate)
  local rows = {
    { id = "aaa111", shortId = "aaa11111", time = "2026-09-08T22:15:06+08:00", hostname = "host",
      tags = { "noctalia" }, paths = { "/tmp/data" }, filesProcessed = 4, bytesProcessed = 2048 },
    { id = "bbb222", shortId = "bbb22222", time = "2026-09-08T21:00:00+08:00", hostname = "nas",
      tags = {}, paths = { "/srv" }, filesProcessed = 3, bytesProcessed = 1024 },
    { id = "ccc333", shortId = "ccc33333", time = "2026-09-08T20:00:00+08:00", hostname = "host",
      tags = { "noctalia", "weekly" }, paths = { "/etc" }, filesProcessed = 9, bytesProcessed = 4096 },
  }
  if mutate ~= nil then
    mutate(rows)
  end
  publish("restic_snapshots", { schema = 2, updatedAt = 1788874602, snapshots = rows })
  return rows
end

publishRows()
clickTab("snapshots")
check("the three snapshots are back for the sheet checks", rowCount() == 3, tostring(rowCount()))
check("no sheet is open before the dots are clicked", nodeByKey("sheet-aaa111") == nil)

-- The earlier context-menu checks leave a request in the harness slot: clear it, so the check below
-- proves the LEFT click does not set one.
H.contextMenu = nil
nodeByKey("menu-aaa111").props.onClick()
check("a left click on the dots opens the in-panel sheet", nodeByKey("sheet-aaa111") ~= nil)
check("a left click never asks the host for the native menu it cannot open", H.contextMenu == nil,
  tostring(H.contextMenu ~= nil))

local SHEET_ACTIONS = { "details", "files", "diff_prev", "restore", "copy_id", "forget_one" }
local missingEntries = {}
for _, action in ipairs(SHEET_ACTIONS) do
  if nodeByKey("sheet-" .. action .. "-aaa111") == nil then
    table.insert(missingEntries, action)
  end
end
check("the sheet offers every action", #missingEntries == 0, table.concat(missingEntries, ","))
check("the sheet labels its entries from the catalogue keys",
  nodeText("sheet-details-aaa111") == "Details"
    and nodeText("sheet-files-aaa111") == "Files"
    and nodeText("sheet-diff_prev-aaa111") == "Diff with previous"
    and nodeText("sheet-restore-aaa111") == "Restore"
    and nodeText("sheet-copy_id-aaa111") == "Copy snapshot id"
    and nodeText("sheet-forget_one-aaa111") == "Forget this snapshot",
  tostring(nodeText("sheet-details-aaa111")))

local sheetRow = nodeByKey("entry-aaa111")
check("the sheet renders beneath its own row",
  sheetRow ~= nil and H.find(sheetRow, H.byKey("row-")) ~= nil
    and H.find(sheetRow, H.byKey("sheet-")) ~= nil)
check("another row carries no sheet",
  nodeByKey("entry-bbb222") ~= nil and H.find(nodeByKey("entry-bbb222"), H.byKey("sheet-")) == nil)

-- Per-row and predictable: one row is expanded at a time, and a second click on the same dots
-- closes whatever that row had open.
nodeByKey("menu-bbb222").props.onClick()
check("opening another row's sheet closes the first",
  nodeByKey("sheet-aaa111") == nil and nodeByKey("sheet-bbb222") ~= nil)
nodeByKey("menu-bbb222").props.onClick()
check("clicking the dots again closes the sheet", nodeByKey("sheet-bbb222") == nil)

-- Every entry routes through the same code path the native menu uses.
local beforeSheet = #H.commands
nodeByKey("menu-aaa111").props.onClick()
nodeByKey("sheet-files-aaa111").props.onClick()
check("the Files entry asks for the listing and closes the sheet",
  nodeByKey("sheet-aaa111") == nil and lastCommand():find("ls", 1, true) ~= nil
    and lastCommand():find("aaa111", 1, true) ~= nil, lastCommand())
check("the Files entry sent exactly one command", #H.commands == beforeSheet + 1, tostring(#H.commands - beforeSheet))

nodeByKey("menu-aaa111").props.onClick()
nodeByKey("sheet-diff_prev-aaa111").props.onClick()
check("the Diff entry diffs against the older neighbour and closes the sheet",
  nodeByKey("sheet-aaa111") == nil and lastCommand():find("diff", 1, true) ~= nil
    and lastCommand():find("bbb222", 1, true) ~= nil, lastCommand())

H.clipboard = nil
nodeByKey("menu-aaa111").props.onClick()
nodeByKey("sheet-copy_id-aaa111").props.onClick()
check("the Copy id entry uses the clipboard and closes the sheet",
  H.clipboard == "aaa111" and nodeByKey("sheet-aaa111") == nil, tostring(H.clipboard))

-- Restore from the sheet still previews before it confirms: one click can never restore.
publish("restic_job", nil)
nodeByKey("menu-aaa111").props.onClick()
nodeByKey("sheet-restore-aaa111").props.onClick()
check("the Restore entry closes the sheet and opens the restore drawer",
  nodeByKey("sheet-aaa111") == nil and nodeByKey("restore-draft") ~= nil)
check("the Restore entry still has no confirm button before a preview",
  nodeByKey("restore-confirm") == nil)
nodeByKey("draft-dismiss").props.onClick()
check("the restore drawer closes again", nodeByKey("restore-draft") == nil)

check("an unknown action does not crash the panel", pcall(onContextAction, "not-an-action", "aaa111"))

-- ── [0.4.0] Details: built from the row, nothing fetched ─────────────────────

nodeByKey("menu-bbb222").props.onClick()
nodeByKey("sheet-details-bbb222").props.onClick()
check("the Details entry closes the sheet and opens the card",
  nodeByKey("sheet-bbb222") == nil and nodeByKey("details-bbb222") ~= nil)
check("the card titles itself from the catalogue key",
  nodeText("details-title") == "Snapshot details", tostring(nodeText("details-title")))
local cardText = H.text(nodeByKey("details-bbb222"))
check("the card names its fields from the catalogue keys",
  cardText:find("Snapshot ID", 1, true) ~= nil and cardText:find("Captured", 1, true) ~= nil
    and cardText:find("Host", 1, true) ~= nil and cardText:find("Tags", 1, true) ~= nil
    and cardText:find("Paths", 1, true) ~= nil and cardText:find("Files processed", 1, true) ~= nil
    and cardText:find("Bytes processed", 1, true) ~= nil and cardText:find("Data added", 1, true) ~= nil,
  cardText)
check("the card renders the short and the full id",
  nodeText("details-id-bbb222-value") == "bbb22222 · bbb222", tostring(nodeText("details-id-bbb222-value")))
check("the card renders the capture time absolutely and relatively",
  nodeText("details-captured-bbb222-value") == "2026-09-08T21:00:00+08:00 · 36m ago",
  tostring(nodeText("details-captured-bbb222-value")))
check("the card renders the row's host",
  nodeText("details-host-bbb222-value") == "nas", tostring(nodeText("details-host-bbb222-value")))
check("the card renders the row's paths",
  nodeText("details-paths-bbb222-value") == "/srv", tostring(nodeText("details-paths-bbb222-value")))
check("the card renders the row's real file and byte counts",
  nodeText("details-files-bbb222-value") == "3" and nodeText("details-bytes-bbb222-value") == "1.0 KiB",
  tostring(nodeText("details-files-bbb222-value")) .. " / " .. tostring(nodeText("details-bytes-bbb222-value")))
-- A field the row does not carry: the catalogue's own wording, never a fabricated 0 and never "nil".
check("a byte field the row does not carry renders panel.details.none",
  nodeText("details-added-bbb222-value") == "not recorded", tostring(nodeText("details-added-bbb222-value")))
check("an empty tag list renders panel.details.none",
  nodeText("details-tags-bbb222-value") == "not recorded", tostring(nodeText("details-tags-bbb222-value")))
check("the card never renders the string nil", cardText:find("nil", 1, true) == nil, cardText)

-- A real 0 the row carries is a value and renders as one.
publishRows(function(rows)
  rows[1].filesProcessed = 0
  rows[1].bytesProcessed = 0
end)
nodeByKey("menu-aaa111").props.onClick()
nodeByKey("sheet-details-aaa111").props.onClick()
check("a real zero the row carries renders as zero",
  nodeText("details-files-aaa111-value") == "0" and nodeText("details-bytes-aaa111-value") == "0 B",
  tostring(nodeText("details-files-aaa111-value")) .. " / " .. tostring(nodeText("details-bytes-aaa111-value")))
check("a field the row lacks still renders panel.details.none",
  nodeText("details-added-aaa111-value") == "not recorded", tostring(nodeText("details-added-aaa111-value")))
check("the tags the row carries are listed",
  nodeText("details-tags-aaa111-value") == "noctalia", tostring(nodeText("details-tags-aaa111-value")))

-- The card's own buttons use the same code path as the menu and the sheet.
beforeSheet = #H.commands
nodeByKey("details-files-aaa111").props.onClick()
check("the card's Files button asks for the listing",
  lastCommand():find("ls", 1, true) ~= nil and lastCommand():find("aaa111", 1, true) ~= nil, lastCommand())
check("the card stays open while its own buttons act", nodeByKey("details-aaa111") ~= nil)
H.clipboard = nil
nodeByKey("details-copy-aaa111").props.onClick()
check("the card's Copy id button uses the clipboard", H.clipboard == "aaa111", tostring(H.clipboard))
nodeByKey("details-dismiss-aaa111").props.onClick()
check("the card closes again", nodeByKey("details-aaa111") == nil)

-- ── [0.4.0] Delete from the sheet is the existing two-step flow ──────────────
-- A single click must never forget a snapshot: the sheet's delete entry sets only the same draft the
-- context menu sets, and the existing confirmation has to appear.

publish("restic_job", nil)
publishRows()
clickTab("snapshots")
nodeByKey("menu-ccc333").props.onClick()
check("the delete entry is in the sheet", nodeByKey("sheet-forget_one-ccc333") ~= nil)
local beforeDelete = #H.commands
nodeByKey("sheet-forget_one-ccc333").props.onClick()
check("the delete entry sends nothing on its own", #H.commands == beforeDelete,
  tostring(#H.commands - beforeDelete))
check("the delete entry opens the existing confirmation", nodeByKey("forget-confirm") ~= nil)
check("the confirmation names the snapshot",
  H.text(H.tree):find("Confirm: forget ccc333", 1, true) ~= nil, H.text(H.tree))
check("the sheet closes when the delete entry runs", nodeByKey("sheet-ccc333") == nil)
nodeByKey("forget-confirm").props.onClick()
check("only the confirmation forgets the snapshot",
  lastCommand():find("forget-one", 1, true) ~= nil and lastCommand():find("ccc333", 1, true) ~= nil,
  lastCommand())

-- A pending confirmation must still not survive a tab switch, and a tab switch closes the sheet.
nodeByKey("menu-aaa111").props.onClick()
clickTab("run")
clickTab("snapshots")
check("a tab switch closes the action sheet", nodeByKey("sheet-aaa111") == nil)

-- ── [0.4.0] the Log tab: the panel reads, formats and caches the log itself ────
-- 0.4.0 fixed the tab that showed one clamped JSON line, and then had to be fixed again: the service
-- used to format the log and publish its TEXT from its update() tick, and on a 97 KB `ls --json` job
-- the host killed that callback ("script callback 'update' exceeded its CPU budget"). The service
-- now publishes { kind, at, ok, cancelled, exitCode, logPath } -- a reference -- and the panel reads
-- the file itself, formats it with lib/logfmt.luau (frozen in docs/CONTRACTS-0.4.0.md 2.1) and
-- caches by (path, size, mtime). Every log below is a REAL restic 0.19.1 capture from
-- tests/fixtures/, placed where the payload points, exactly as the runner leaves it on disk.

local function fixture(name)
  local handle = io.open("tests/fixtures/" .. name, "rb")
  if handle == nil then
    error("missing fixture tests/fixtures/" .. name)
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

-- The file the payload points at, and the payload itself: metadata plus the log's PATH.
local LOG_PATH = "/tmp/restic-data/jobs/token.jsonl"

local function publishLog(overrides)
  local log = {
    kind = "backup", at = 1788874500, ok = true, cancelled = false, exitCode = 0, logPath = LOG_PATH,
  }
  for key, value in pairs(overrides or {}) do
    log[key] = value
  end
  publish("restic_joblog", log)
  return log
end

-- Put a fixture where the payload points and re-render, the way a job writing its log does.
local function showLog(name)
  H.files[LOG_PATH] = fixture(name)
  H.mtimes[LOG_PATH] = 1000
  publishLog({})
end

-- Any label whose text is exactly this string, so a check can assert the rendered sentence itself.
local function labelWith(value)
  local hit = nil
  for _, node in ipairs(H.findAll(H.tree, H.byType("label"))) do
    if node.props.text == value then
      hit = node
    end
  end
  return hit
end

clickTab("log")

-- The real progress fixture: three status lines and the summary, folded as the contract requires.
showLog("backup-progress.jsonl")
check("a raw --json progress stream reads as a progress line",
  labelWith("84% · 3362/4000 files · 210.6 MiB / 250.0 MiB") ~= nil, H.text(H.tree))
check("the summary that closes the run reads as its own sentence",
  labelWith("4000 new · 0 changed · 0 unchanged · 250.0 MiB processed · 251.4 MiB added · 1.1s") ~= nil,
  H.text(H.tree))
check("the earlier status lines are counted, not listed",
  nodeText("logs-folded") == "2 lines folded", tostring(nodeText("logs-folded")))
check("the Formatted view does not render the raw JSON record",
  H.text(H.tree):find("message_type", 1, true) == nil, H.text(H.tree))

-- The user's own complaint (contract 1.1): a scheduled backup's whole log is ONE 473-byte record.
showLog("backup-summary.jsonl")
check("the 473-byte one-line log now reads as a sentence",
  labelWith("0 new · 0 changed · 173 unchanged · 840.2 KiB processed · 0 B added · 1.2s") ~= nil,
  H.text(H.tree))
check("a one-line log folds nothing", nodeByKey("logs-folded") == nil)

-- A listing job: 40 ls records must never become 40 rows.
showLog("ls-list.jsonl")
check("a 40-record ls listing is folded into one counted line",
  labelWith("40 records (ls)") ~= nil, H.text(H.tree))
check("the folded records are counted",
  nodeText("logs-folded") == "39 lines folded", tostring(nodeText("logs-folded")))
check("no individual ls record reaches the view",
  H.text(H.tree):find("cachyos-dotfiles", 1, true) == nil, H.text(H.tree))

-- An error line is never folded away, and reads as a problem.
showLog("error.jsonl")
local errorLine = labelWith("error: Fatal: unable to open config file: stat /tmp/nope/config: "
  .. "no such file or directory")
check("a real restic error line is rendered, not folded", errorLine ~= nil, H.text(H.tree))
check("an error line is coloured as a problem",
  errorLine ~= nil and errorLine.props.color == "error")

-- A hook log is plain text: every line is shown verbatim.
showLog("hooks.txt")
check("a hook log renders its own lines verbatim",
  labelWith("== pre-backup command ==") ~= nil and labelWith("pruned 3 old dumps") ~= nil,
  H.text(H.tree))
check("a log line wraps instead of being clamped to one line",
  labelWith("pruned 3 old dumps") ~= nil and labelWith("pruned 3 old dumps").props.maxLines == nil)
check("the mode button names the view that is on screen",
  nodeText("logs-mode") == "Formatted", tostring(nodeText("logs-mode")))

-- ── Raw: the log's own lines, unclamped ─────────────────────────────────────
-- The pre-0.4.0 view, kept for the record itself: the same file, split into its lines, with no
-- maxLines clamp -- clamping every line to one is what made a 473-byte summary unreadable.

showLog("backup-summary.jsonl")
nodeByKey("logs-mode").props.onClick()
check("the toggle switches to Raw", nodeText("logs-mode") == "Raw", tostring(nodeText("logs-mode")))
check("Raw renders the raw --json record itself",
  H.text(H.tree):find("message_type", 1, true) ~= nil, H.text(H.tree))
check("Raw hides the formatted wording",
  H.text(H.tree):find("840.2 KiB processed", 1, true) == nil, H.text(H.tree))
local rawLabel = nil
for _, node in ipairs(H.findAll(H.tree, H.byType("label"))) do
  if node.props.text ~= nil and tostring(node.props.text):find("message_type", 1, true) ~= nil then
    rawLabel = node
  end
end
check("a raw line wraps instead of being clamped to one line",
  rawLabel ~= nil and rawLabel.props.maxLines == nil,
  rawLabel ~= nil and tostring(rawLabel.props.maxLines))
check("the log still scrolls and still offers a refresh",
  nodeByKey("joblog") ~= nil and nodeByKey("logs-refresh") ~= nil)

nodeByKey("logs-mode").props.onClick()
check("the toggle switches back to Formatted", nodeText("logs-mode") == "Formatted",
  tostring(nodeText("logs-mode")))
check("Formatted renders the translated lines again",
  labelWith("0 new · 0 changed · 173 unchanged · 840.2 KiB processed · 0 B added · 1.2s") ~= nil,
  H.text(H.tree))
local summaryLabel = labelWith("0 new · 0 changed · 173 unchanged · 840.2 KiB processed · 0 B added · 1.2s")
check("a formatted line wraps too", summaryLabel ~= nil and summaryLabel.props.maxLines == nil)

-- ── a check's own summary ───────────────────────────────────────────────────
showLog("check-summary.jsonl")
local checkLine = labelWith("0 errors")
check("a check summary reads as an error count, not as a backup", checkLine ~= nil, H.text(H.tree))
check("a passed check is not coloured as a problem",
  checkLine ~= nil and checkLine.props.color ~= "error")

-- restic's check summary when it wants attention: the field names are the ones logfmt reads and the
-- fixtures carry (`suggest_repair_index` / `suggest_prune`), with a non-zero error count.
H.files[LOG_PATH] = '{"message_type":"summary","num_errors":3,"broken_packs":2,'
  .. '"suggest_repair_index":true,"suggest_prune":true}\n'
H.mtimes[LOG_PATH] = 1050
publishLog({})
check("a check line with a suggested repair and prune says so",
  labelWith("3 errors · repair suggested · prune suggested") ~= nil, H.text(H.tree))
check("a check line with errors is coloured as a problem",
  labelWith("3 errors · repair suggested · prune suggested") ~= nil
    and labelWith("3 errors · repair suggested · prune suggested").props.color == "error")

-- ── a malformed log is a message, never a crash ─────────────────────────────
-- A log viewer that crashes on a log is worse than no viewer (contract 2.1): half a JSON record, a
-- bare brace, plain text, a blank line, an unknown message type and an error record whose own JSON
-- was cut. Everything here is rendered as the line it is, nothing is invented, nothing is folded.
H.files[LOG_PATH] = '{"message_type":"summary","files_new":3\n'
  .. '{\n'
  .. 'not json at all\n'
  .. '\n'
  .. '{"message_type":"quantum","what":1}\n'
  .. '{"message_type":"error"\n'
  .. '{"message_type":"error","error":{"message":"a real error"},"code":7}\n'
H.mtimes[LOG_PATH] = 1100
publishLog({})
check("the render survives a malformed log", nodeByKey("joblog") ~= nil)
check("an unreadable JSON line is shown as the line it is",
  labelWith('{"message_type":"summary","files_new":3') ~= nil
    and labelWith("not json at all") ~= nil, H.text(H.tree))
check("an unknown message type is shown verbatim, and invents nothing",
  labelWith('{"message_type":"quantum","what":1}') ~= nil
    and H.text(H.tree):find("panel.logs", 1, true) == nil
    and H.text(H.tree):find("table:", 1, true) == nil, H.text(H.tree))
check("a real error record inside a malformed log still reads as an error",
  labelWith("error: a real error") ~= nil, H.text(H.tree))

-- The last line of a live log has no newline yet: still a line, and the numbers the record does not
-- carry read as unknown rather than as a fabricated zero.
H.files[LOG_PATH] = '{"message_type":"status","percent_done":0.5,"files_done":1,"total_files":2}'
H.mtimes[LOG_PATH] = 1200
publishLog({})
check("a status line with no trailing newline still renders",
  labelWith("50% · 1/2 files · ? / ?") ~= nil, H.text(H.tree))

-- One pathological line must not become nine kilobytes of text in the panel.
H.files[LOG_PATH] = "{" .. string.rep("z", 9000) .. "}\n"
H.mtimes[LOG_PATH] = 1300
publishLog({})
check("an enormous line is clamped, and says so",
  H.text(H.tree):find("...", 1, true) ~= nil
    and H.text(H.tree):find(string.rep("z", 300), 1, true) == nil, H.text(H.tree))

-- ── the cache: (path, size, mtime) ──────────────────────────────────────────
-- The tab re-renders on every state publish -- and the service republishes the log reference as a
-- live run grows, which is how the view stays live -- so a render that cannot show anything new must
-- not re-read the file. Same path, same size and same mtime is the whole test.

H.files[LOG_PATH] = fixture("hooks.txt")
H.mtimes[LOG_PATH] = 1400
publishLog({})
local cached = H.text(H.tree)
check("the fixture renders before the cache check",
  cached:find("pruned 3 old dumps", 1, true) ~= nil, cached)

-- Same length, same mtime, different bytes: if the panel re-read the file it would show the swap.
local swapped = (fixture("hooks.txt"):gsub("post%-backup", "post-BACKUP"))
check("the swap keeps the file's length", #swapped == #H.files[LOG_PATH], tostring(#swapped))
H.files[LOG_PATH] = swapped
publishLog({})
check("a re-render with an unchanged (path, size, mtime) does not re-read the log",
  H.text(H.tree) == cached, H.text(H.tree))

-- Touching the file the way a job does: the same bytes, a new mtime.
H.mtimes[LOG_PATH] = 1500
publishLog({})
check("a bumped mtime re-reads the log",
  H.text(H.tree):find("post-BACKUP", 1, true) ~= nil, H.text(H.tree))

-- Another path is another log, whatever the numbers say.
local OTHER_PATH = "/tmp/restic-data/jobs/other.jsonl"
H.files[OTHER_PATH] = fixture("error.jsonl")
H.mtimes[OTHER_PATH] = 1500
publishLog({ logPath = OTHER_PATH })
check("a payload pointing at another log reads that one",
  H.text(H.tree):find("unable to open config file", 1, true) ~= nil, H.text(H.tree))

-- ── the panel's own bounds ──────────────────────────────────────────────────
-- The panel bounds its own list too, and says so when it cuts: this is its guard against an
-- unbounded re-render (it renders on every publish). BOTH views keep the LAST rows -- the newest
-- output is what a log tab is for, and the formatter's own bound drops from the head too.
local manyLines = {}
for index = 1, 300 do
  manyLines[index] = "line " .. tostring(index)
end
H.files[LOG_PATH] = table.concat(manyLines, "\n") .. "\n"
H.mtimes[LOG_PATH] = 1600
publishLog({})
check("the panel's own log bound is honest about what it cut",
  nodeText("joblog-truncated") == "log truncated to the last 200 lines",
  tostring(nodeText("joblog-truncated")))
check("the bound keeps the newest rows and drops the oldest",
  labelWith("line 300") ~= nil and labelWith("line 100") == nil, H.text(H.tree))

-- And the read itself is bounded to the last 16 KiB, with the partial first line dropped exactly as
-- lib/jobs.luau's readLog does. The file is built so that its final 16384 bytes start 20 bytes into
-- its first line, and so that the tail is short enough in lines (198) to be inside the view window:
-- if the fragment were not dropped, "FRAGMENTVALUE" would be the first row on screen.
local cutLine = string.rep("x", 19) .. "FRAGMENTVALUE"   -- the bound lands 20 bytes into this line
local secondRow = "SECOND-ROW"
local lastRow = "FINAL-ROW"
local middle = string.rep(string.rep("m", 82) .. "\n", 195) .. string.rep("m", 163) .. "\n"
local rest = secondRow .. "\n" .. middle .. lastRow .. "\n"
local bigLog = cutLine .. "\n" .. rest
check("the bounded-log fixture is the size the arithmetic claims",
  #bigLog == 16403 and #rest == 16370, tostring(#bigLog) .. "/" .. tostring(#rest))
H.files[LOG_PATH] = bigLog
H.mtimes[LOG_PATH] = 1700
publishLog({})
check("a log bigger than the read bound is read as its last 16 KiB",
  labelWith(secondRow) ~= nil and labelWith(cutLine) == nil
    and nodeText("joblog-truncated") ~= nil, H.text(H.tree))
check("the partial first line the bound cut in half is dropped, not shown",
  labelWith("FRAGMENTVALUE") == nil, "FRAGMENTVALUE is rendered")

-- ── the empty state: a missing or unreadable log is a message ────────────────
H.files[LOG_PATH] = nil
H.mtimes[LOG_PATH] = nil
publishLog({})
check("a swept log renders the empty state",
  nodeText("joblog-empty") == "No job log yet.", tostring(nodeText("joblog-empty")))
check("the empty state keeps its hint",
  nodeText("joblog-empty-hint") == "A job's output appears here once it has run.",
  tostring(nodeText("joblog-empty-hint")))
check("the run's own header survives the missing log",
  H.text(H.tree):find("backup", 1, true) ~= nil and H.text(H.tree):find("exit 0", 1, true) ~= nil,
  H.text(H.tree))
check("no view toggle is offered for nothing", nodeByKey("logs-mode") == nil)
check("the empty state still offers a refresh", nodeByKey("logs-refresh") ~= nil)

-- An empty file says the same thing as no file.
H.files[LOG_PATH] = ""
H.mtimes[LOG_PATH] = 1800
publishLog({})
check("an empty log renders the empty state",
  nodeText("joblog-empty") == "No job log yet.", tostring(nodeText("joblog-empty")))

-- A read that fails outright must not raise out of a render. The failure is cached with the same
-- (path, size, mtime) key as any other result -- an unchanged file that could not be read will not
-- read either on the next render -- so the render that follows a restored read and an unchanged file
-- still shows the empty state, and only a changed file re-reads.
H.files[LOG_PATH] = fixture("hooks.txt")
H.mtimes[LOG_PATH] = 1900
local realRead = noctalia.readFile
noctalia.readFile = function() error("simulated unreadable file") end
publishLog({})
check("a read that raises renders the empty state instead of breaking the panel",
  nodeText("joblog-empty") == "No job log yet.", tostring(nodeText("joblog-empty")))
noctalia.readFile = realRead
publishLog({})
check("an unreadable, unchanged log is not re-read either",
  nodeText("joblog-empty") == "No job log yet.", tostring(nodeText("joblog-empty")))
H.mtimes[LOG_PATH] = 1950
publishLog({})
check("the log renders again once the file changes and the read works",
  labelWith("pruned 3 old dumps") ~= nil, H.text(H.tree))

-- A payload with no logPath yet (a job that has not written its log) is the same empty state, and a
-- run in flight still reads as running rather than as a failure with a fabricated exit code.
publish("restic_joblog", {
  kind = "backup", at = 1788874500, ok = false, cancelled = false, exitCode = nil,
})
check("a payload with no logPath yet renders the empty state, not a broken panel",
  nodeText("joblog-empty") == "No job log yet.", tostring(nodeText("joblog-empty")))
check("a run in flight still reads as running",
  H.text(H.tree):find("running", 1, true) ~= nil, H.text(H.tree))
check("a run in flight shows no fabricated exit code",
  H.text(H.tree):find("exit ", 1, true) == nil, H.text(H.tree))

publish("restic_joblog", nil)
check("the log tab keeps its empty state",
  nodeText("joblog-empty") == "No job log yet.", tostring(nodeText("joblog-empty")))
check("the empty state still offers a refresh", nodeByKey("logs-refresh") ~= nil)
check("no mode toggle before a log exists", nodeByKey("logs-mode") == nil)

-- ── the history strip, the hero and the countdown (0.5.0) ─────────────────────
-- The strip is the repository's shape: one bar per snapshot, as tall as the bytes that snapshot
-- actually added. These checks pin the two things that make it worth having -- a bar per snapshot,
-- and the raised bar on the snapshot that changed -- because a strip whose bars do not track
-- dataAdded is decoration, not information.

H.config.keep_last = 7
H.config.keep_daily = 7
H.config.keep_weekly = 4
H.config.keep_monthly = 6
publishRows(function(rows)
  rows[1].dataAdded = 8192 -- newest, and the only one that changed
  rows[2].dataAdded = 0
  rows[3].dataAdded = 0
end)
clickTab("snapshots")

local strip = nodeByKey("history-strip")
check("the history strip renders once there is history", strip ~= nil)
local bars = strip ~= nil and H.findAll(strip, H.byType("box")) or {}
check("the strip has one bar per snapshot", #bars == 3, tostring(#bars))
-- The strip runs oldest to newest, so aaa111 -- the newest row, the one that added data -- is last.
check("only the snapshot that added data gets a raised bar",
  bars[1] ~= nil and bars[3] ~= nil and bars[3].props.height > bars[1].props.height,
  tostring(bars[1] and bars[1].props.height) .. " vs " .. tostring(bars[3] and bars[3].props.height))
check("the raised bar carries the accent role",
  bars[3] ~= nil and bars[3].props.fill == "primary", tostring(bars[3] and bars[3].props.fill))
check("a snapshot that added nothing gets a dim bar instead",
  bars[1] ~= nil and bars[1].props.fill ~= "primary", tostring(bars[1] and bars[1].props.fill))
check("the hero reports what was stored and what was walked, not one number for both",
  tostring(nodeText("history-stored")):find("8.0 KiB", 1, true) ~= nil
    and tostring(nodeText("history-stored")):find("7.0 KiB", 1, true) ~= nil,
  tostring(nodeText("history-stored")))
check("the hero says a repository that stopped growing is the good outcome",
  tostring(nodeText("history-note")):find("good outcome", 1, true) ~= nil,
  tostring(nodeText("history-note")))
check("a row calls out the bytes it added", H.text(H.tree):find("+8.0 KiB", 1, true) ~= nil, H.text(H.tree))

-- The headline is recency now, so the absolute date has to survive somewhere or the panel has lost
-- the one fact you need when you are hunting for "the snapshot from Tuesday".
local rowText = tostring(H.text(nodeByKey("row-aaa111")))
check("the row headline leads with recency beside the clock time",
  rowText:find("ago", 1, true) ~= nil and rowText:find("22:15:06", 1, true) ~= nil, rowText)
check("the absolute date survives as a day heading",
  nodeByKey("day-2026-09-08") ~= nil and nodeText("day-2026-09-08") == "2026-09-08",
  tostring(nodeText("day-2026-09-08")))
check("the day heading appears once for the day, not once per row",
  #H.findAll(H.tree, H.byKey("day-")) == 1, tostring(#H.findAll(H.tree, H.byKey("day-"))))

-- The vocabulary's own signals for an active tab and for dismiss.
check("the active tab uses selected rather than repainting itself primary",
  nodeByKey("tab-snapshots") ~= nil and nodeByKey("tab-snapshots").props.selected == true
    and nodeByKey("tab-snapshots").props.variant == "ghost",
  tostring(nodeByKey("tab-snapshots") and nodeByKey("tab-snapshots").props.variant))
check("close is the x glyph rather than the word Close",
  nodeByKey("close") ~= nil and nodeByKey("close").props.glyph == "x",
  tostring(nodeByKey("close") and nodeByKey("close").props.glyph))

-- The action sheet is contained: a bare column stretches its children and a button centres its
-- content, which is how the sheet came to render as a full-width stack of centred buttons.
nodeByKey("menu-aaa111").props.onClick()
check("the action sheet is a bounded surface, not a stretched stack",
  nodeByKey("sheet-aaa111") ~= nil and nodeByKey("sheet-aaa111").props.width == 250
    and nodeByKey("sheet-aaa111").props.fill ~= nil,
  tostring(nodeByKey("sheet-aaa111") and nodeByKey("sheet-aaa111").props.width))
check("the sheet's entries left-align their labels",
  nodeByKey("sheet-details-aaa111") ~= nil
    and nodeByKey("sheet-details-aaa111").props.contentAlign == "start",
  tostring(nodeByKey("sheet-details-aaa111") and nodeByKey("sheet-details-aaa111").props.contentAlign))
clickTab("snapshots")

-- ── the countdown (0.5.0) ─────────────────────────────────────────────────────

clickTab("run")
local countdown = nodeByKey("countdown")
check("the run tab fills the interval to the next backup",
  countdown ~= nil and tonumber(countdown.props.progress) ~= nil,
  tostring(countdown and countdown.props.progress))
check("the countdown reads as part of the way there, not as empty or full",
  countdown ~= nil and countdown.props.progress > 0 and countdown.props.progress < 1,
  tostring(countdown and countdown.props.progress))

H.stateValues["restic_status"].phase = "running"
H.stateValues["restic_status"].busy = true
render()
check("a running job replaces the countdown rather than sharing the row with it",
  nodeByKey("countdown") == nil)
H.stateValues["restic_status"].phase = "idle"
H.stateValues["restic_status"].busy = false
render()

-- ── the prune note only when a confirmation can follow it ─────────────────────

clickTab("retention")
publish("restic_job", {
  kind = "forget-dry", at = 1788874602, ok = true,
  keepCount = 22, removeCount = 0, remove = {}, truncated = false,
})
check("a preview that removes nothing still reports its counts",
  H.text(H.tree):find("Would keep 22, remove 0", 1, true) ~= nil, H.text(H.tree))
check("no note pointing at a confirmation that cannot appear",
  nodeByKey("preview-note") == nil)
check("no prune button when there is nothing to remove", nodeByKey("prune") == nil)

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
