--!nonstrict
-- Built-in backup templates — the "sources" half of a restore kit.
--
-- A template is a named, curated list of `~`-relative paths. It exists so that restoring a
-- desktop does not begin with the user hunting through a home directory to remember which
-- dotfiles matter. `lib/restic.luau`'s `config()` expands the `~`, merges the template's paths
-- with any explicit `backup_paths`, and de-duplicates the result — this module is pure data and
-- lookup, so it is unit-testable without the host.
--
-- Deliberate limits:
--   * A template contributes paths ONLY. It does not add backup tags: restic groups retention by
--     host + paths + tags, so silently adding a tag would split an existing repository's snapshots
--     into separate retention groups. The user's `backup_tags` stay authoritative.
--   * Paths are captured as a subset, not as a whole home directory: caches, downloads, media and
--     credentials (`.ssh`, `.gnupg`) are excluded by construction, because they are either large,
--     regenerable, or secrets that should not ride along in a backup a user may later share.
--   * A path that does not exist is left for restic to skip (it warns and continues as long as at
--     least one source exists), so one template works on a machine that has only some of them.

local M = {}

-- The id that means "use `backup_paths` exactly as written", i.e. no template. It is a sentinel
-- rather than a list entry so that it can never collide with a real template id.
M.CUSTOM = "custom"

M.LIST = {
  {
    id = "cachyos-system-restore",
    name_key = "templates.cachyos_system_restore.name",
    description_key = "templates.cachyos_system_restore.description",
    paths = {
      "~/.config/hypr",
      "~/.config/noctalia",
      "~/.config/hyprfm",
      "~/.config/kitty",
      "~/.config/alacritty",
      "~/.config/btop",
      "~/.config/fish",
      "~/.config/uwsm",
      "~/.config/systemd/user",
      "~/.config/autostart",
      "~/.config/satty",
      "~/.config/llama-swap",
      "~/.config/mimeapps.list",
      "~/.local/bin",
      "~/.local/share/applications",
      "~/.bashrc",
      "~/.bash_profile",
      "~/.zshrc",
      "~/.gitconfig",
    },
  },
}

local byId = {}
for _, template in ipairs(M.LIST) do
  byId[template.id] = template
end

-- The descriptor for `id`, or nil when `id` is absent or unknown. `nil` is the signal callers use
-- to mean "no template" — an unknown id is treated exactly like an unset one, so a settings file
-- naming a template this build no longer ships degrades to `backup_paths` rather than to no
-- sources at all.
function M.get(id)
  if type(id) ~= "string" then
    return nil
  end
  return byId[id]
end

-- Every template id, in declaration order. The manifest's select and the tests both read this so
-- the two can never drift apart.
function M.ids()
  local out = {}
  for _, template in ipairs(M.LIST) do
    table.insert(out, template.id)
  end
  return out
end

return M
