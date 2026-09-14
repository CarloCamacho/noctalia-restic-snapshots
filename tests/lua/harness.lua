-- Minimal Noctalia host stub so plugin entries can be loaded and driven under Lua 5.4.
-- Implements only the host surface these entries use.
--
-- [0.2.0] Extended for the restic 0.2.0 work: JSON encode handles nested tables/arrays, fileInfo
-- reports real sizes for files placed in H.files (so "does this grow?" logic is testable),
-- mtimes are settable via H.mtimes for sweep tests, and the newer API members the entries now
-- touch (tr, copyToClipboard, openSettings, processMatches, panel.openContextMenu) are stubbed.

local H = {}

H.config = {
  restic_bin = "restic",
  repository = "/tmp/repo",
  password_file = "/tmp/pass",
  backup_paths = { "/tmp/data" },
  backup_tags = { "noctalia" },
  exclude_file = "",
  env_file = "",
  mode = "plugin",
  interval_minutes = 60,
  job_timeout_minutes = 180,
  check_interval_hours = 0,
  stale_after_hours = 0,
  keep_last = 7,
  keep_daily = 7,
  keep_weekly = 4,
  keep_monthly = 6,
  restore_target = "/tmp/restore",
  restore_allow_roots = {},
  check_subset = "1/100",
  show_count = false,
  show_staleness = true,
}

H.env = { HOME = "/home/tester", PATH = "/usr/bin:/bin" }
H.tree = nil
H.commands = {}
H.pending = {}
H.logs = {}
H.files = {}
H.mtimes = {}        -- [path] = epoch seconds (or ms); drives jobs.sweep tests
H.published = {}
H.stateValues = {}   -- key -> value returned by state.get
H.jsonMap = {}       -- raw string -> decoded table (canned json.decode)
H.decodeFn = nil     -- optional function(text) fallback for json.decode
H.contextMenu = nil
H.clipboard = nil

local dirStack = {}

local function normalize(path)
  path = path:gsub("/%.%/", "/")
  path = path:gsub("//+", "/")
  return path
end

-- ── JSON encode (recursive; the entries encode nested payloads) ──────────────

local function isArray(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  if count == 0 then
    return true
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

local function encodeValue(value)
  local kind = type(value)
  if kind == "string" then
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif kind ~= "table" then
    return "null"
  end
  local parts = {}
  if isArray(value) then
    for _, item in ipairs(value) do
      table.insert(parts, encodeValue(item))
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    table.insert(parts, string.format('"%s":%s', tostring(key), encodeValue(item)))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function H.install(plugin_dir)
  H.plugin_dir = plugin_dir
  H.tree = nil
  H.commands = {}
  H.pending = {}
  H.logs = {}
  H.files = {}
  H.mtimes = {}
  H.published = {}
  H.stateValues = {}
  H.contextMenu = nil
  H.clipboard = nil

  _G.noctalia = {
    log = function(msg) table.insert(H.logs, tostring(msg)) end,
    nowMs = function() return H.nowMs or 1788874602000 end,
    getConfig = function(key) return H.config[key] end,
    getenv = function(name) return H.env[name] end,
    expandPath = function(path) return path end,
    fileExists = function(path) return path:match("/restic$") ~= nil or path:match("^/tmp") ~= nil end,
    fileInfo = function(path)
      local contents = H.files[path]
      if contents ~= nil then
        return { size = #contents, mtime = H.mtimes[path] or 0, isDir = false }
      end
      if path:match("/restic$") then
        return { size = 1, mtime = 0, isDir = false }
      end
      return { size = 0, mtime = 0, isDir = true }
    end,
    listDir = function() return {} end,
    pluginDataDir = function() return "/tmp/restic-data" end,
    mkdirAll = function() return true end,
    readFile = function(path) return H.files[path] end,
    writeFile = function(path, contents) H.files[path] = contents; return true end,
    removeFile = function(path) H.files[path] = nil; return true end,
    commandExists = function() return true end,
    notify = function(...) table.insert(H.logs, "notify: " .. tostring(select(1, ...))) end,
    notifyError = function(...) table.insert(H.logs, "error: " .. tostring(select(1, ...))) end,
    setUpdateInterval = function() end,
    togglePanel = function() end,
    runAsync = function(cmd, cb)
      table.insert(H.commands, cmd)
      if cb then table.insert(H.pending, cb) end
      return true
    end,
    formatTime = function() return "12:00" end,
    -- [0.2.0] additions
    tr = function(key) return key end,
    trp = function(key) return key end,
    copyToClipboard = function(text) H.clipboard = text; return true end,
    openSettings = function() H.openedSettings = true end,
    processMatches = function(onResult) if onResult then onResult(false) end; return true end,
    fuzzyScore = function(pattern, text)
      if tostring(text):find(tostring(pattern), 1, true) then return 1 end
      return nil
    end,
    state = {
      get = function(key) return H.stateValues[key] end,
      set = function(key, value) H.published[key] = value; H.stateValues[key] = value end,
      watch = function(key, cb) H.stateValues["__watch_" .. key] = cb end,
    },
    json = {
      decode = function(text)
        if H.jsonMap[text] ~= nil then return H.jsonMap[text] end
        if type(H.decodeFn) == "function" then return H.decodeFn(text) end
        return nil
      end,
      encode = function(value) return encodeValue(value or {}) end,
    },
    string = { trim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end },
  }

  _G.ui = setmetatable({}, {
    __index = function(_, kind)
      return function(props, children)
        return { type = kind, props = props or {}, children = children or {} }
      end
    end,
  })

  _G.panel = {
    render = function(tree) H.tree = tree end,
    close = function() H.closed = true end,
    setNeedsFrameTick = function() end,
    setWantsSecondTicks = function() end,
    openContextMenu = function(request) H.contextMenu = request; return true end,
  }
  _G.barWidget = {
    render = function(tree) H.tree = tree end,
    setText = function(v) H.barText = v end,
    setGlyph = function(v) H.barGlyph = v end,
    setTooltip = function(rows) H.tooltip = rows end,
    clearTooltip = function() H.tooltip = nil end,
    isVertical = function() return false end,
  }
  _G.shortcut = {
    setLabel = function(v) H.shortcutLabel = v end,
    setIcon = function(a, b) H.shortcutIcon = { a, b } end,
    setActive = function(v) H.shortcutActive = v end,
    setEnabled = function(v) H.shortcutEnabled = v end,
  }

  local realRequire = require
  _G.require = function(name)
    if type(name) == "string" and name:sub(1, 2) == "./" then
      local base = dirStack[#dirStack] or H.plugin_dir
      local path = normalize(base .. "/" .. name:sub(3))
      local chunk, err = loadfile(path)
      if chunk == nil then
        error("require failed for " .. path .. ": " .. tostring(err))
      end
      table.insert(dirStack, path:match("^(.*)/[^/]+$") or ".")
      local ok, result = pcall(chunk)
      table.remove(dirStack)
      if not ok then
        error(result)
      end
      return result
    end
    return realRequire(name)
  end
end

function H.load(entry)
  local path = H.plugin_dir .. "/" .. entry
  local chunk, err = loadfile(path)
  if chunk == nil then
    error("loadfile failed: " .. tostring(err))
  end
  table.insert(dirStack, path:match("^(.*)/[^/]+$") or ".")
  local ok, result = pcall(chunk)
  table.remove(dirStack)
  if not ok then
    error(result)
  end
  return result
end

function H.find(node, pred)
  if node == nil then return nil end
  if pred(node) then return node end
  for _, child in ipairs(node.children or {}) do
    local hit = H.find(child, pred)
    if hit ~= nil then return hit end
  end
  return nil
end

function H.findAll(node, pred, out)
  out = out or {}
  if node == nil then return out end
  if pred(node) then table.insert(out, node) end
  for _, child in ipairs(node.children or {}) do
    H.findAll(child, pred, out)
  end
  return out
end

function H.byType(kind)
  return function(node) return node.type == kind end
end

function H.text(node)
  local parts = {}
  local function walk(n)
    if n == nil then return end
    if n.props then
      if n.props.text then table.insert(parts, tostring(n.props.text)) end
      if n.props.name then table.insert(parts, tostring(n.props.name)) end
    end
    for _, child in ipairs(n.children or {}) do walk(child) end
  end
  walk(node)
  return table.concat(parts, " | ")
end

-- Buttons (and other clickable nodes) whose key starts with `prefix`.
function H.byKey(prefix)
  return function(node)
    return type(node.props) == "table" and type(node.props.key) == "string"
      and node.props.key:sub(1, #prefix) == prefix
  end
end

-- Run the onClick of the first node matching pred, if it has one.
function H.click(node, pred)
  local hit = H.find(node, pred)
  if hit == nil or type(hit.props.onClick) ~= "function" then
    return false
  end
  hit.props.onClick()
  return true
end

return H
