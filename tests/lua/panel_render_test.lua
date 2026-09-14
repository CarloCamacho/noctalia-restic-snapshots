--!nonstrict
-- Real render-tree assertions for the panel entry.
-- Run from the repo root:  lua5.4 tests/lua/panel_render_test.lua

package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")

H.install("plugin/restic-snapshots")

H.stateValues["restic_status"] = {
  schema = 2,
  updatedAt = 1788874602,
  available = true,
  version = "0.19.1",
  repository = "/tmp/repo",
  repoConfigured = true,
  mode = "plugin",
  phase = "idle",
  lastRun = { at = 1788874502, ok = true, files = 12, bytes = 4096, added = 2048 },
  nextRun = 1788878202,
  snapshotCount = 2,
  busy = false,
  error = "",
}
H.stateValues["restic_snapshots"] = {
  schema = 2,
  updatedAt = 1788874602,
  snapshots = {
    { id = "abc123", shortId = "abc12345", time = "2026-09-08T22:15:06+08:00", hostname = "host",
      tags = { "noctalia" }, filesProcessed = 4, bytesProcessed = 2048 },
    { id = "def456", shortId = "def45678", time = "2026-09-08T21:00:00+08:00", hostname = "host",
      tags = {}, filesProcessed = 3, bytesProcessed = 1024 },
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

onOpen()
local text = H.text(H.tree)
check("panel renders a header", text:find("Restic Snapshots") ~= nil, text)
check("panel shows the repository", text:find("/tmp/repo") ~= nil)
check("panel has three tabs", text:find("Snapshots") and text:find("Run") and text:find("Retention"))
check("snapshot list shows a timestamp", text:find("2026%-09%-08") ~= nil, text)
check("snapshot list shows tags", text:find("noctalia") ~= nil, text)

local restoreButtons = H.findAll(H.tree, function(node)
  return node.type == "button" and node.props.text == "Restore"
end)
check("each snapshot has a restore button", #restoreButtons == 2, "#restore=" .. #restoreButtons)

-- Run tab
local runTab = H.findAll(H.tree, function(node)
  return node.type == "button" and node.props.key == "tab-run"
end)[1]
check("run tab chip exists", runTab ~= nil)
runTab.props.onClick()
check("run tab shows a backup button", H.text(H.tree):find("Back up now") ~= nil, H.text(H.tree))
check("run tab shows the last run", H.text(H.tree):find("Last run succeeded") ~= nil, H.text(H.tree))
check("run tab shows the next run", H.text(H.tree):find("Next scheduled run") ~= nil)

-- Running state replaces the controls with progress
H.stateValues["restic_status"].phase = "running"
H.stateValues["restic_status"].job = { kind = "backup", percent = 0.5, filesDone = 2, totalFiles = 4,
  bytesDone = 1024, totalBytes = 2048 }
render()
check("running shows progress", H.find(H.tree, H.byType("progress")) ~= nil)
check("running offers cancel", H.text(H.tree):find("Cancel") ~= nil, H.text(H.tree))
H.stateValues["restic_status"].phase = "idle"
H.stateValues["restic_status"].job = nil

-- Retention tab
local retentionTab = H.findAll(H.tree, function(node)
  return node.type == "button" and node.props.key == "tab-retention"
end)[1]
check("retention tab chip exists", retentionTab ~= nil)
retentionTab.props.onClick()
check("retention shows the policy", H.text(H.tree):find("Keep: 7 last") ~= nil, H.text(H.tree))
check("retention offers a preview", H.text(H.tree):find("Preview removal") ~= nil)

-- Prune is two-step: no destructive button until a preview exists
check("no prune button before preview", H.text(H.tree):find("Prune now") == nil, H.text(H.tree))

H.stateValues["restic_job"] = {
  kind = "forget-dry",
  ok = true,
  groups = { { keep = { {}, {} }, remove = { {} } } },
}
H.stateValues["__watch_restic_job"](H.stateValues["restic_job"])
check("preview counts keep and remove", H.text(H.tree):find("Would keep 2, remove 1") ~= nil, H.text(H.tree))

local prune = H.findAll(H.tree, function(node)
  return node.type == "button" and node.props.key == "prune"
end)[1]
check("prune appears after preview", prune ~= nil)
if prune ~= nil then
  prune.props.onClick()
  check("first prune click asks for confirmation", H.text(H.tree):find("Confirm: prune 1") ~= nil, H.text(H.tree))
end

print(string.format("\n%s -- %d failure(s)", failures == 0 and "ALL PASS" or "FAILURES", failures))
os.exit(failures == 0 and 0 or 1)
