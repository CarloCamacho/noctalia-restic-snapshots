# Restic Snapshots 0.5.0 — frozen contracts & workstream map

Read this before touching 0.5.0. It records what changed, the evidence for each change, and the
interfaces that must **not** drift.

## 1. Scope

0.4.0 made the panel readable. 0.5.0 makes the panel *say something*: the repository is a time
series, and it was being rendered as a table. Two defects are fixed in the same release because both
were found by the same pass and both are cheap; they are independent of the visual work.

Workstreams, in order:

| # | Workstream | Files | Gate |
| --- | --- | --- | --- |
| 1 | retention preview shape | `lib/restic.luau`, `service.luau`, `tests/lua/restic_pure_test.lua` | measured against the real job files, plus new unit checks |
| 2 | manifest shadowing | `plugin.toml` | `noctalia plugins lint` side by side with 0.4.0 |
| 3 | panel: strip, hero, headings, countdown | `panel.luau`, `translations/en.json` | `panel_render_test.lua` |
| 4 | widget: sparkline | `widget.luau` | `widget_render_test.lua` |
| 5 | release plumbing | `plugin.toml`, `catalog.toml`, `CHANGELOG.md`, `README.md` | `catalog.toml` version must equal `plugin.toml` version |

## 2. Defect 1 — the retention preview returned a confident zero

### Evidence

The panel showed **"Would keep 0, remove 0"** for a repository whose own `forget --dry-run --json`
output contains `"keep": [ … 2 snapshots … ], "remove": null`.

### Cause

Two parsers, one of which is never used in production:

- `restic.parseObject` decodes the **whole text** once — this is what `restic_pure_test.lua` used.
- `restic.parseJsonLines` decodes **one value per line** and wraps each in a table — this is what
  `service.luau:687` uses.

restic writes the entire forget array on a **single line**. So the service handed
`summariseForgetDry` the shape `{ array }`, not `array`:

```lua
if type(objects[1]) == "table" then groups = objects   -- satisfied by the WRAPPER
```

`groups` therefore became `{ array }`; iterating it yields the array as the only "group";
`group.keep` and `group.remove` are `nil`; `#asList(nil)` is 0. The function returned
`{ keepCount = 0, removeCount = 0 }` — non-nil, so the caller stayed on its success path. The prune
control is gated on `removeCount > 0`, so it could never render, whatever the policy.

### Fix, and the line that must not be crossed

- Unwrap `{ array }` at the boundary.
- A payload that is **neither** a group **nor** a list of groups is **not** "nothing to remove":
  return `nil`, so the caller reports a failure. `service.luau` publishes `ok = ok and preview ~= nil`.
- An **empty** payload stays a zero. That is restic saying nothing matched, it is drawn, and it is
  the honest answer. `restic_pure_test.lua` asserts this and the assertion is deliberate.

### Measured result (both real job files on this machine)

```
1a0a06085f1ea82fd.jsonl  (3390 bytes, 1 decoded value)
  objects[1]      : a table of 1 element   <- the wrapper, not the group
  0.4.0 reported  : keep 0, remove 0
  0.5.0 reports   : keep 2, remove 0       <- matches restic
```

`remove 0` is correct here: 22 snapshots under a keep-7/7/4/6 policy leaves nothing to forget. The
defect was never that a prune *should* have run — it was that the counts were unreadable and would
have read as zero for every policy, including one with removals.

## 3. Defect 2 — a shadow warning on every manifest load

```
[WRN] [plugin-manifest] plugin 'carlocamacho/restic-snapshots' entry 'browser'
      setting 'browser_placement' shadows a plugin-level setting; entry value wins
```

`plugin_panel_shell.cpp:98` — `if (!entry.panelPersistent && !hasSettingKey(entry, placementKey))` —
and `hasSettingKey` inspects **`entry.settings`**. A plugin-level `[[setting]]` is not visible to it,
so the host injected `browser_placement` regardless; `plugin_manifest.cpp:810` then compares entry
settings against plugin-level keys and warns on the collision.

0.4.0 declared these at plugin level **deliberately** (unlabelled injection was the reported bug), so
the fix is not to remove them but to move them: `[[panel.setting]]` on the `browser` entry satisfies
`hasSettingKey`, suppresses the injection, keeps the labelled control, and removes the warning.

**Do not move them back to plugin level.** `noctalia plugins lint` prints the two warnings on 0.4.0
and none on 0.5.0; that comparison is the regression test.

## 4. Visual work — the rules it follows

- **No new service state.** `summary.dataAdded` was already published per snapshot, so the strip, the
  hero and the sparkline are pure panel/widget work. If a change here needs a service change, the
  design is wrong.
- **The strip encodes two facts in one shape**: that a snapshot ran (a bar exists) and that it
  changed anything (the bar is tall and accented). A bytes bar chart with 22 zeros and one spike was
  considered and rejected — at that ratio it is a flat line, and it loses the "it ran" half.
- **Nothing is animated for its own sake.** The countdown bar and the running-job progress are the
  only moving elements, and the countdown is suppressed while a job runs rather than sitting beside it.
- **The sparkline floor is load-bearing.** `SPARK_FLOOR = 0.15` keeps a bar off zero, because with
  frequent backups most values are legitimately zero and a series pinned to the floor is
  indistinguishable from a graph that failed to draw. A flat repository must *read* as flat.
- **Recency in the headline, the absolute date in the day heading.** Removing the timestamp from the
  row is only acceptable because the date still exists one level up.
- **`table.insert`, never `and X or nil`.** Conditional children built with `and X or nil` leave nil
  holes and log `ui tree node is not a table` on every render — the defect 0.4.1 was released for.

## 5. Interfaces that did not change

Frozen, and asserted by tests:

- Every `[[setting]]` key read with `noctalia.getConfig`, and every `panel.state` key.
- Every node key the tests look up: `row-`, `menu-`, `restore-`, `sheet-`, `entry-`, `tab-`,
  `preview-`, `prune`, `close`, `verify-`, `stats-`, `checks-`, `logs-`, `details-`.
- `restic.summariseForgetDry(objects, limit)` → `{ keepCount, removeCount, remove, truncated }` or
  `nil`. The `nil` case is new in 0.5.0 and is the point.
- `widget.luau` reads `KEY_STATUS` for state and `KEY_SNAPSHOTS` for history. Neither payload changed.

## 6. Verification

```bash
python3 -m unittest discover -s tests
for f in tests/lua/*.lua; do lua5.4 "$f"; done
luac -p plugin/restic-snapshots/*.luau plugin/restic-snapshots/lib/*.luau
noctalia plugins lint plugin/restic-snapshots
```

Green on `release/0.5.0`: 100 Python tests (1 skipped), all **11** Lua suites, `luac -p` parsing all
13 `.luau` files, and lint reporting `0 errors, 0 warnings`.

New assertions in this release, and why each exists:

| Suite | Assertion |
| --- | --- |
| `restic_pure_test` | the `{ array }` wrapper is unwrapped, not read as one group — **the shape the service actually passes, which no test covered before** |
| `restic_pure_test` | a wrapped empty payload is still a zero |
| `restic_pure_test` | an unreadable non-empty payload is `nil`, never a false zero |
| `panel_render_test` | one bar per snapshot; only the snapshot that added data is raised and accented |
| `panel_render_test` | the hero reports stored **and** walked |
| `panel_render_test` | recency in the headline, the absolute date in a single day heading |
| `panel_render_test` | `selected` on the active tab; `x` glyph for close |
| `panel_render_test` | the action sheet is bounded and its entries left-align |
| `panel_render_test` | the countdown is part of the way there; a running job replaces it |
| `panel_render_test` | no prune note when no confirmation can follow it |
| `widget_render_test` | a point per snapshot, the changed one tallest, none at zero |
| `widget_render_test` | the series is ordered by time, whatever order the rows arrive in |
