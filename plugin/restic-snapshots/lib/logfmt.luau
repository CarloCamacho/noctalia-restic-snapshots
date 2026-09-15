--!nonstrict
-- Restic job logs, made readable: restic's raw `--json` stream -> typed Lines.
--
-- Why this module exists (docs/CONTRACTS-0.4.0.md 1.1): a scheduled backup's whole log file is ONE
-- 473-byte JSON line and an `ls` job's is one JSON object per entry, yet the Log tab renders each
-- entry as `ui.label({ text = line, maxLines = 1 })`. The result is a clipped blob with no
-- information in it. The formatting therefore has to happen once, in the service, so the panel
-- receives something it can actually render.
--
-- Two properties are load-bearing:
--
--   * PURE. No `noctalia.*` call and no file access -- not even `noctalia.json.decode`, which is
--     why the small object reader below exists. `noctalia.tr` is deliberately absent too: the
--     panel owns the wording (`panel.logs.*`), so the formatter must not produce sentences. Same
--     input, same output, always, and it can be exercised in plain Lua.
--   * BOUNDED BY LINES, never by bytes walked one at a time. This runs inside the service's
--     `update()` tick while a job is live, and the host budgets a callback's CPU (contract 4.1: a
--     per-character walk over a 97 KB log killed a tick). Structure and field probes are
--     `string.find` (C, one pass per line); a full JSON read happens only for the handful of lines
--     whose numbers are shown -- the last status line, one summary, a record carrying an error.
--
-- `M.format(text, opts) -> { display = { Line }, collapsed = number, raw = { string } }`
--
--   opts = { maxLines = 60, maxWidth = 220, rawLines = 200 }   (all optional; <= 0 means no bound)
--
-- Line kinds -- the panel renders these, this module never words them:
--
--   text     { text }                                  a plain line, verbatim (bounded to maxWidth)
--   progress { percent, filesDone, totalFiles, bytesDone, totalBytes }
--   backup   { filesNew, filesChanged, filesUnmodified, dirsNew, dirsChanged, dataAdded,
--              bytesProcessed, durationSeconds }
--   check    { errors, brokenPacks, suggestRepair, suggestPrune }
--   records  { count, source }                         a folded record stream (`ls`, `diff`)
--   error    { message, code }                         never dropped, never folded
--
-- `collapsed` counts every input line that is not a Line of its own: the folded status lines, the
-- folded record lines, blank lines, and lines cut by the maxLines bound. It is therefore the
-- honest "how much am I not showing you" number, not just "progress lines".

local M = {}

local DEFAULT_MAX_LINES = 60
local DEFAULT_MAX_WIDTH = 220
local DEFAULT_RAW_LINES = 200

-- A folded-away line (counted in `collapsed`, never rendered). A unique table so `==` identifies
-- it, and so it can hold no data of its own.
local DROPPED = {}
-- JSON null. Distinct from "the key was absent" because the contract requires a field the record
-- does not carry to stay absent rather than become a fabricated zero.
local NULL = {}

local BYTE_TAB, BYTE_LF, BYTE_CR, BYTE_SPACE = 9, 10, 13, 32
local BYTE_QUOTE, BYTE_COMMA, BYTE_COLON = 34, 44, 58
local BYTE_LBRACE, BYTE_RBRACE = 123, 125
local BYTE_LBRACKET, BYTE_RBRACKET = 91, 93
local BYTE_BACKSLASH, BYTE_LOWER_N = 92, 110
local BYTE_LOWER_T, BYTE_LOWER_F = 116, 102

-- One-object-per-line record streams, folded into a single counted line. The shapes are the ones
-- restic 0.19.1 actually emits and the fixtures in tests/fixtures pin them: `ls --json` writes a
-- snapshot header followed by one `struct_type == "node"` object per entry (the fixture carries
-- both the `struct_type` and the matching `message_type`), `diff --json` one
-- `message_type == "change"` object per path. Nothing else is guessed at: JSON that is not one of
-- these is shown, compactly, as a `text` line -- never silently swallowed.
local RECORD_SOURCE_BY_STRUCT = { node = "ls", snapshot = "ls" }
local RECORD_SOURCE_BY_MESSAGE = { node = "ls", snapshot = "ls", change = "diff" }

-- The escape sequences that change a byte. \uXXXX is copied verbatim (no crash, no loss).
local ESCAPES = {
  [34] = '"', [47] = "/", [92] = "\\",
  [98] = "\b", [102] = "\f", [110] = "\n", [114] = "\r", [116] = "\t",
}

-- ── small helpers ─────────────────────────────────────────────────────────────

local function positiveInteger(value, fallback)
  local number = tonumber(value)
  if number == nil then
    return fallback
  end
  return math.floor(number)
end

-- Strip what a renderer would not show anyway: surrounding blanks and a CR from a CRLF log.
local function trim(line)
  local text = line:gsub("^[ \t\r]+", "")
  return (text:gsub("[ \t\r]+$", ""))
end

-- Keep the head of an over-long line and say so with an ellipsis. One pathological line must not
-- become a megabyte of text in the panel.
local function clamp(text, limit)
  if limit <= 0 or #text <= limit then
    return text
  end
  if limit <= 3 then
    return text:sub(1, limit)
  end
  return text:sub(1, limit - 3) .. "..."
end

-- Is this a number restic sent us? Strings from JSON are never coerced into numbers.
local function number(value)
  if type(value) == "number" then
    return value
  end
  return nil
end

-- ── a reader for the objects restic emits ─────────────────────────────────────
--
-- Deliberately minimal and deliberately here rather than in the host: the module must be pure, and
-- only flat records (plus one nested `error.message`) are ever read. Failure is always `nil`, so a
-- partial or malformed line falls back to being shown as text instead of raising.

local decodeValue

local function skipSpace(text, position)
  local length = #text
  while position <= length do
    local byte = string.byte(text, position)
    if byte == BYTE_SPACE or byte == BYTE_TAB or byte == BYTE_LF or byte == BYTE_CR then
      position = position + 1
    else
      break
    end
  end
  return position
end

-- `position` is the index of the opening quote. Returns the string and the index after it, or nil
-- when the string never closes.
local function decodeString(text, position)
  local length = #text
  local index = position + 1
  local start = index
  local pieces = nil
  while index <= length do
    local byte = string.byte(text, index)
    if byte == BYTE_BACKSLASH then
      local following = string.byte(text, index + 1)
      if following == nil then
        return nil
      end
      pieces = pieces or {}
      table.insert(pieces, text:sub(start, index - 1))
      local replacement = ESCAPES[following]
      if replacement ~= nil then
        table.insert(pieces, replacement)
        index = index + 2
      elseif following == BYTE_LOWER_N and index + 5 <= length then
        -- \uXXXX, kept as written: it is not worth a code-point decoder for a log line.
        table.insert(pieces, text:sub(index, index + 5))
        index = index + 6
      else
        table.insert(pieces, text:sub(index, index + 1))
        index = index + 2
      end
      start = index
    elseif byte == BYTE_QUOTE then
      local tail = text:sub(start, index - 1)
      if pieces == nil then
        return tail, index + 1
      end
      table.insert(pieces, tail)
      return table.concat(pieces), index + 1
    else
      index = index + 1
    end
  end
  return nil
end

local function decodeObjectAt(text, position)
  local out = {}
  local length = #text
  position = skipSpace(text, position + 1)
  if string.byte(text, position) == BYTE_RBRACE then
    return out, position + 1
  end
  while true do
    if string.byte(text, position) ~= BYTE_QUOTE then
      return nil
    end
    local key, afterKey = decodeString(text, position)
    if key == nil then
      return nil
    end
    position = skipSpace(text, afterKey)
    if string.byte(text, position) ~= BYTE_COLON then
      return nil
    end
    local value, afterValue = decodeValue(text, position + 1)
    if afterValue == nil then
      return nil
    end
    if value ~= NULL then
      out[key] = value
    end
    position = skipSpace(text, afterValue)
    local byte = string.byte(text, position)
    if byte == BYTE_COMMA then
      position = skipSpace(text, position + 1)
    elseif byte == BYTE_RBRACE then
      return out, position + 1
    else
      return nil
    end
    if position > length then
      return nil
    end
  end
end

local function decodeArrayAt(text, position)
  local out = {}
  position = skipSpace(text, position + 1)
  if string.byte(text, position) == BYTE_RBRACKET then
    return out, position + 1
  end
  while true do
    local value, afterValue = decodeValue(text, position)
    if afterValue == nil then
      return nil
    end
    if value ~= NULL then
      table.insert(out, value)
    end
    position = skipSpace(text, afterValue)
    local byte = string.byte(text, position)
    if byte == BYTE_COMMA then
      position = skipSpace(text, position + 1)
    elseif byte == BYTE_RBRACKET then
      return out, position + 1
    else
      return nil
    end
  end
end

decodeValue = function(text, position)
  position = skipSpace(text, position)
  local byte = string.byte(text, position)
  if byte == nil then
    return nil
  elseif byte == BYTE_LBRACE then
    return decodeObjectAt(text, position)
  elseif byte == BYTE_LBRACKET then
    return decodeArrayAt(text, position)
  elseif byte == BYTE_QUOTE then
    return decodeString(text, position)
  elseif byte == BYTE_LOWER_T and text:find("^true", position) then
    return true, position + 4
  elseif byte == BYTE_LOWER_F and text:find("^false", position) then
    return false, position + 5
  elseif byte == BYTE_LOWER_N and text:find("^null", position) then
    return NULL, position + 4
  end
  local _, stop = text:find("^[-+%d.eE]+", position)
  if stop == nil then
    return nil
  end
  local literal = text:sub(position, stop)
  local value = tonumber(literal)
  if value == nil then
    return nil
  end
  return value, stop + 1
end

-- The whole line as a JSON object, or nil. A trailing newline or spaces are tolerated; trailing
-- junk after the object is not, because a truncated line must not be read as if it were complete.
local function decodeObject(text)
  local position = skipSpace(text, 1)
  if string.byte(text, position) ~= BYTE_LBRACE then
    return nil
  end
  local object, after = decodeObjectAt(text, position)
  if object == nil then
    return nil
  end
  return object
end

-- The string value of a top-level-ish field, without decoding the line. Values restic uses for the
-- keys this reads (`message_type`, `struct_type`) are plain identifiers, so this is one C scan.
local function fieldString(text, key)
  local value = text:match('"' .. key .. '"%s*:%s*"([%w_%-]*)')
  if value == nil or value == "" then
    return nil
  end
  return value
end

-- Does the record carry an `error`? Not decoded here -- just found, cheaply.
local function hasErrorField(text)
  return text:find('"error"%s*:%s*', 1) ~= nil
end

-- ── Line builders ─────────────────────────────────────────────────────────────

local function textLine(text, maxWidth)
  return { kind = "text", text = clamp(text, maxWidth) }
end

-- An error line is never dropped and never folded: a log viewer that hides an error is worse than
-- no viewer at all. When the record cannot be read, the record itself is the message.
local function errorLine(object, text, forced, maxWidth)
  local message = nil
  local code = nil
  if type(object) == "table" then
    local carried = object.error
    if type(carried) == "string" then
      message = carried
    elseif type(carried) == "table" and type(carried.message) == "string" then
      message = carried.message
    end
    code = number(object.code)
  end
  if (message == nil or message == "") and not forced then
    return nil
  end
  if message == nil or message == "" then
    message = text
  end
  return { kind = "error", message = clamp(message, maxWidth), code = code }
end

-- restic reports `percent_done` as a fraction; the panel prints "{percent}%", so it is scaled
-- here (rounded to two decimals so the number a test or an eye sees is the number restic meant).
local function percentOf(fraction)
  local value = number(fraction)
  if value == nil then
    return nil
  end
  return math.floor(value * 10000 + 0.5) / 100
end

local function progressLine(text)
  local object = decodeObject(text)
  if object == nil then
    return nil
  end
  return {
    kind = "progress",
    percent = percentOf(object.percent_done),
    filesDone = number(object.files_done),
    totalFiles = number(object.total_files),
    bytesDone = number(object.bytes_done),
    totalBytes = number(object.total_bytes),
  }
end

local function backupLine(object)
  return {
    kind = "backup",
    filesNew = number(object.files_new),
    filesChanged = number(object.files_changed),
    filesUnmodified = number(object.files_unmodified),
    dirsNew = number(object.dirs_new),
    dirsChanged = number(object.dirs_changed),
    dataAdded = number(object.data_added),
    bytesProcessed = number(object.total_bytes_processed),
    durationSeconds = number(object.total_duration),
  }
end

local function checkLine(object)
  return {
    kind = "check",
    errors = number(object.num_errors),
    brokenPacks = number(object.broken_packs),
    suggestRepair = object.suggest_repair_index == true,
    suggestPrune = object.suggest_prune == true,
  }
end

-- Which summary is this? A check reports `num_errors`/`broken_packs`/`suggest_*`; a backup
-- reports the file and byte counts. Anything else (a restore's summary, say) is not worded here:
-- it is shown as its own record, so an unknown summary is visible rather than mislabelled as a
-- backup. Field names are restic 0.19.1's, taken from the fixtures.
--
-- The markers are backup-only on purpose: `total_duration` and `total_bytes_processed` also appear
-- in a restore's summary (phase0-findings.md row 8), so keying on those would print a restore's
-- numbers under the backup wording.
local BACKUP_MARKERS = {
  "files_new", "files_changed", "files_unmodified", "dirs_new", "dirs_changed",
  "data_added", "total_files_processed",
}

local function summaryLine(object, text, maxWidth)
  if type(object) ~= "table" then
    return textLine(text, maxWidth)
  end
  if object.num_errors ~= nil or object.broken_packs ~= nil or object.suggest_prune ~= nil
      or object.suggest_repair_index ~= nil then
    return checkLine(object)
  end
  for _, field in ipairs(BACKUP_MARKERS) do
    if object[field] ~= nil then
      return backupLine(object)
    end
  end
  return textLine(text, maxWidth)
end

local function recordSource(text, messageType)
  local structType = fieldString(text, "struct_type")
  if structType ~= nil then
    -- An unmapped struct_type still names itself: the stream is folded either way, and saying
    -- what restic called it beats inventing a name for it.
    return RECORD_SOURCE_BY_STRUCT[structType] or structType
  end
  if messageType ~= nil then
    return RECORD_SOURCE_BY_MESSAGE[messageType]
  end
  return nil
end

-- ── the formatter ─────────────────────────────────────────────────────────────

-- Classify one JSON line into the pending list. Returns a tag the caller uses for folding:
-- "status" (the line waits until the caller knows it is the last one), "record" (counted, folded)
-- or "line" (already pushed).
local function classify(text, pending, maxWidth)
  local messageType = fieldString(text, "message_type")
  local object = nil
  local loaded = false
  local function decoded()
    if not loaded then
      object = decodeObject(text)
      loaded = true
    end
    return object
  end

  -- An error is emitted first and whatever else the record is: the numbers following it may still
  -- be shown, but the error can never be lost behind a count.
  local forced = messageType == "error"
  if forced or hasErrorField(text) then
    local line = errorLine(decoded(), text, forced, maxWidth)
    if line ~= nil then
      table.insert(pending, line)
    end
  end
  if forced then
    return "line"
  end

  if messageType == "status" then
    return "status"
  elseif messageType == "summary" then
    table.insert(pending, summaryLine(decoded(), text, maxWidth))
    return "line"
  end

  local source = recordSource(text, messageType)
  if source ~= nil then
    return "record", source
  end
  -- JSON that is neither a known message nor a known record: shown as it came, compactly, so an
  -- unanticipated shape is visible instead of swallowed.
  table.insert(pending, textLine(text, maxWidth))
  return "line"
end

-- Cut the display down to `limit` entries. The oldest derived line goes first (a summary is
-- context), then the oldest text line, and an error line is never cut: when only errors are left
-- the bound yields to them, because a hidden error is the one outcome the contract forbids.
local function bound(list, limit)
  if limit <= 0 or #list <= limit then
    return list, 0
  end
  local need = #list - limit
  local cut = {}
  local dropped = 0
  for pass = 1, 2 do
    for index = 1, #list do
      if dropped < need then
        local kind = list[index].kind
        local eligible
        if pass == 1 then
          eligible = kind ~= "text" and kind ~= "error"
        else
          eligible = kind == "text"
        end
        if eligible then
          cut[index] = true
          dropped = dropped + 1
        end
      end
    end
  end
  if dropped == 0 then
    return list, 0
  end
  local out = {}
  for index = 1, #list do
    if not cut[index] then
      table.insert(out, list[index])
    end
  end
  return out, dropped
end

-- `text` -> { display, collapsed, raw }. Never raises: a log viewer that crashes on a log is worse
-- than no viewer, so every unexpected shape (nil, a number, a partial line, an empty line, a
-- truncated object) has a defined, quiet result.
function M.format(text, opts)
  local result = { display = {}, collapsed = 0, raw = {} }
  if type(text) ~= "string" or text == "" then
    return result
  end
  local options = type(opts) == "table" and opts or {}
  local maxLines = positiveInteger(options.maxLines, DEFAULT_MAX_LINES)
  local maxWidth = positiveInteger(options.maxWidth, DEFAULT_MAX_WIDTH)
  local rawLines = positiveInteger(options.rawLines, DEFAULT_RAW_LINES)

  local pending = {}
  local raw = {}
  local rawCount = 0
  local folded = 0
  local recordCount = 0
  local recordIndex = nil
  local progressIndex = nil

  -- One pass over the newlines: the work scales with the number of lines, and a line is trimmed
  -- and probed (never walked byte by byte).
  local position = 1
  local length = #text
  while position <= length do
    local newline = text:find("\n", position, true)
    local stop = newline ~= nil and newline - 1 or length
    local rawLine = text:sub(position, stop)
    if newline == nil then
      position = length + 1
    else
      position = newline + 1
    end

    rawCount = rawCount + 1
    if rawLines <= 0 then
      table.insert(raw, rawLine)
    else
      -- A ring buffer: only the last `rawLines` lines are kept, and nothing is copied per line.
      raw[((rawCount - 1) % rawLines) + 1] = rawLine
    end

    local trimmed = trim(rawLine)
    if trimmed == "" then
      folded = folded + 1
    elseif string.byte(trimmed, 1) == BYTE_LBRACE then
      local tag, source = classify(trimmed, pending, maxWidth)
      if tag == "status" then
        -- Only the last status line is shown: it carries the newest numbers. The earlier ones are
        -- replaced by a folded marker (counted in the second pass below), so the progress line
        -- keeps its place in the stream.
        if progressIndex ~= nil then
          pending[progressIndex] = DROPPED
        end
        table.insert(pending, { __status = trimmed })
        progressIndex = #pending
      elseif tag == "record" then
        recordCount = recordCount + 1
        if recordIndex == nil then
          table.insert(pending, { __records = source })
          recordIndex = #pending
        else
          folded = folded + 1
        end
      end
    else
      table.insert(pending, textLine(rawLine, maxWidth))
    end
  end

  if rawLines > 0 and rawCount > rawLines then
    local ordered = {}
    for index = rawCount - rawLines + 1, rawCount do
      table.insert(ordered, raw[((index - 1) % rawLines) + 1])
    end
    raw = ordered
  end

  local display = {}
  for _, entry in ipairs(pending) do
    if entry == DROPPED then
      folded = folded + 1
    elseif entry.__status ~= nil then
      local line = progressLine(entry.__status)
      -- A status line whose own JSON cannot be read is still shown, as the text it is.
      table.insert(display, line or textLine(entry.__status, maxWidth))
    elseif entry.__records ~= nil then
      table.insert(display, { kind = "records", count = recordCount, source = entry.__records })
    else
      table.insert(display, entry)
    end
  end

  local bounded, cut = bound(display, maxLines)
  result.display = bounded
  result.collapsed = folded + cut
  result.raw = raw
  return result
end

return M
