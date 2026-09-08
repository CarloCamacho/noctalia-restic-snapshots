-- Minimal Noctalia host stub so plugin entries can be loaded and driven under Lua 5.4.
-- Implements only the host surface these entries use.

local H = {}

H.config = {
  restic_bin = "restic",
  repository = "/tmp/repo",
  password_file = "/tmp/pass",
  backup_paths = { "/tmp/data" },
  backup_tags = { "noctalia" },
  exclude_file = "",
  mode = "plugin",
  interval_minutes = 60,
  keep_last = 7,
  keep_daily = 7,
  keep_weekly = 4,
  keep_monthly = 6,
  restore_target = "/tmp/restore",
  check_subset = "1/100",
  show_count = false,
}

H.env = { HOME = "/home/tester", PATH = "/usr/bin:/bin" }
H.tree = nil
H.commands = {}
H.pending = {}
H.logs = {}
H.files = {}
H.published = {}
H.stateValues = {}   -- key -> value returned by state.get
H.jsonMap = {}       -- raw string -> decoded table (canned json.decode)

local dirStack = {}

local function normalize(path)
  path = path:gsub("/%.%/", "/")
  path = path:gsub("//+", "/")
  return path
end

function H.install(plugin_dir)
  H.plugin_dir = plugin_dir
  H.tree = nil
  H.commands = {}
  H.pending = {}
  H.logs = {}
  H.files = {}
  H.published = {}
  H.stateValues = {}

  _G.noctalia = {
    log = function(msg) table.insert(H.logs, tostring(msg)) end,
    nowMs = function() return 1788874602000 end,
    getConfig = function(key) return H.config[key] end,
    getenv = function(name) return H.env[name] end,
    expandPath = function(path) return path end,
    fileExists = function(path) return path:match("/restic$") ~= nil or path:match("^/tmp") ~= nil end,
    fileInfo = function(path)
      if path:match("/restic$") then return { size = 1, mtime = 0, isDir = false } end
      return { size = 0, mtime = 0, isDir = true }
    end,
    listDir = function() return {} end,
    pluginDataDir = function() return "/tmp/restic-data" end,
    mkdirAll = function() return true end,
    readFile = function(path) return H.files[path] end,
    writeFile = function(path, contents) H.files[path] = contents; return true end,
    removeFile = function() return true end,
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
    state = {
      get = function(key) return H.stateValues[key] end,
      set = function(key, value) H.published[key] = value; H.stateValues[key] = value end,
      watch = function(key, cb) H.stateValues["__watch_" .. key] = cb end,
    },
    json = {
      decode = function(s) return H.jsonMap[s] end,
      encode = function(value)
        -- Only used for small payloads in tests; good enough for { key = "value" }.
        local parts = {}
        for k, v in pairs(value or {}) do
          table.insert(parts, string.format('"%s":"%s"', k, tostring(v)))
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end,
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
  }
  _G.barWidget = {
    render = function(tree) H.tree = tree end,
    setText = function() end,
    setGlyph = function() end,
    setTooltip = function(rows) H.tooltip = rows end,
    clearTooltip = function() end,
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

return H
