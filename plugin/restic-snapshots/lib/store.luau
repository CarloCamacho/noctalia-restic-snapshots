--!nonstrict
-- Small persistent store for the things an in-memory service cannot afford to lose.
--
-- `noctalia.state` is in-memory only, so a service restart used to forget when the last backup
-- ran and when the next one was due. With the schedule re-armed from "now" on every load, that
-- meant a scheduled backup could be pushed forward forever and never fire. Everything that has
-- to outlive one service incarnation lives here, in pluginDataDir()/state.json.
--
-- Policy: written only on transitions (job finished, snapshots refreshed, settings changed) --
-- never from the update() tick, so the file is not rewritten every couple of seconds.

local M = {}

M.SCHEMA = 1

function M.filePath()
  local base = noctalia.pluginDataDir()
  if type(base) ~= "string" or base == "" then
    return nil
  end
  return base .. "/state.json"
end

-- Always returns a table. A missing, unreadable, malformed or older-schema file yields {}.
function M.load()
  local path = M.filePath()
  if path == nil or not noctalia.fileExists(path) then
    return {}
  end
  local text = noctalia.readFile(path)
  if type(text) ~= "string" or text == "" then
    return {}
  end
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  if tonumber(decoded.schema) ~= M.SCHEMA then
    return {}
  end
  return decoded
end

-- Overwrite the record. Returns the writeFile result (ok, err).
function M.replace(record)
  local path = M.filePath()
  if path == nil then
    return false, "no plugin data directory"
  end
  local payload = record or {}
  payload.schema = M.SCHEMA
  payload.updatedAt = math.floor(noctalia.nowMs() / 1000)
  local text, err = noctalia.json.encode(payload, true)
  if text == nil then
    return false, err
  end
  return noctalia.writeFile(path, text)
end

-- Shallow-merge a patch into the persisted record. Keys whose value is nil are ignored, so a
-- caller can patch a single field without having to reconstruct the whole record.
function M.patch(patch)
  local record = M.load()
  for key, value in pairs(patch or {}) do
    if value ~= nil then
      record[key] = value
    end
  end
  return M.replace(record)
end

return M
