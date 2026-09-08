--!nonstrict
-- Control-center tile: back up now.

local state = require("./lib/state.luau")

local status = state.migrate(noctalia.state.get(state.KEY_STATUS))

local function send(event)
  return noctalia.runAsync({
    "noctalia", "msg", "plugin", "carlocamacho/restic-snapshots:service", "all", event,
  }, nil, 10000)
end

function update()
  local running = status.phase == "running"
  shortcut.setLabel("Backup")
  shortcut.setIcon("archive", "archive-off")
  shortcut.setActive(running)
  shortcut.setEnabled(status.available == true and status.repoConfigured == true)
end

function onClick()
  send(state.EVENT_BACKUP)
end

noctalia.state.watch(state.KEY_STATUS, function(value)
  status = state.migrate(value)
  update()
end)

update()
