--!nonstrict
-- Binary resolution and path helpers.
--
-- The Noctalia daemon runs with a bare system PATH (verified for agent-harness: no
-- ~/.local/bin, no user runtime directories), and its `sh -lc` may not source the user's
-- interactive shell config. We therefore search known per-user locations, then a probed
-- login-shell PATH, then the daemon PATH — the probe augments, never replaces.

local M = {}

local probedPath = nil

function M.setSearchPath(path)
  if type(path) == "string" and path ~= "" then
    probedPath = path
  end
end

function M.homeDir()
  return noctalia.getenv("HOME") or ""
end

function M.expandPath(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  if path:sub(1, 1) == "~" then
    return M.homeDir() .. path:sub(2)
  end
  return path
end

function M.searchDirs()
  local dirs = {}
  local seen = {}
  local function add(dir)
    if type(dir) == "string" and dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end

  local home = M.homeDir()
  if home ~= "" then
    add(home .. "/.local/bin")
    add(home .. "/.local/sbin")
  end
  for dir in (probedPath or ""):gmatch("[^:]+") do
    add(dir)
  end
  for dir in (noctalia.getenv("PATH") or ""):gmatch("[^:]+") do
    add(dir)
  end
  return dirs
end

function M.resolveBinary(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  if name:find("/") then
    return noctalia.fileExists(name) and name or nil
  end
  for _, dir in ipairs(M.searchDirs()) do
    local candidate = dir .. "/" .. name
    if noctalia.fileExists(candidate) then
      local info = noctalia.fileInfo(candidate)
      if info ~= nil and not info.isDir then
        return candidate
      end
    end
  end
  return nil
end

-- Directory holding the resolved binary; also where its helper tools usually live.
function M.binDir(binaryPath)
  if type(binaryPath) ~= "string" then
    return ""
  end
  return binaryPath:match("^(.*)/[^/]+$") or ""
end

return M
