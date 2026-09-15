# Restic Snapshots 0.4.0 — frozen contracts & workstream map

Read this before writing code. It freezes interfaces, names the owner of every file, and records the
three defects being fixed with the evidence for each.

## 1. What is broken, and the evidence

The user reported three things. Each was diagnosed against the running shell before any code changed.

### 1.1 "The log doesn't actually show any output, just this one static line"

**Cause: the Log tab renders restic's raw `--json` output, one clamped line per record.**
Every scheduled backup's log file is a *single* 473-byte line:

```
{"message_type":"summary","files_new":0,"files_changed":0,"files_unmodified":173,...,"total_bytes_processed":860367,"total_duration":1.1677,"backup_start":"...","snapshot_id":"..."}
```

The service publishes that as `lines`, and the panel renders each entry as
`ui.label({ text = line, maxLines = 1 })` — one long JSON blob, visually clipped. Nothing is
*broken*; the log is simply never made readable. A listing job is worse: 261 lines of `ls --json`.

### 1.2 "The three dots beside a snapshot don't function"

**Cause: the host refuses `panel.openContextMenu` outside a pointer context, and the dots button
calls it from `onClick`.** `src/scripting/plugin_bindings.cpp`:

```cpp
if (context == nullptr
    || !context->snapshot.pointerContext.has_value()
    || context->snapshot.pointerContext->serial == 0) {
  lua_pushboolean(L, 0);   // silently returns false
  return 1;
}
```

The API doc is explicit: `onRightClick` is "the only place panel.openContextMenu may be called".
So the right-click path works and the left-click path can never work. A left click must therefore
open something the *panel itself* renders.

**Also missing:** the menu has no Details entry, and "forget this snapshot" is the only destructive
action (it does have a two-step confirmation — that must be preserved).

### 1.3 "an option in the config for whether the panel is attached or centred"

**Cause: the option exists but is injected unlabelled.** `injectStandardPanelShellSettings` adds a
setting named `{panel_entry_id}_placement` (so `browser_placement`) *unless the plugin already
declares that key*, and reads it at open time:

```cpp
config.placement = panelPlacementFromString(
    settingString(settings, placementKey, entry.panelPlacementDefault), PanelPlacement::Floating);
```

Valid values are exactly `"attached"` and `"floating"` (`panelPlacementFromString`); a floating
panel's on-screen position comes from `{id}_position` with values
`auto|center|top_left|top_center|top_right|center_left|center_right|bottom_left|bottom_center|bottom_right`.
Declaring both keys with `label_key`s gives the user a labelled, discoverable option.

## 2. Frozen interfaces

### 2.1 `lib/logfmt.luau` (new, pure — no host calls, no `noctalia.*`)

```lua
M.format(text, opts) -> { display = { Line }, collapsed = number, raw = { string } }
```

`opts = { maxLines = 60, maxWidth = 220, rawLines = 200 }` (all optional).

`Line` is a **typed** table so the panel owns the wording (the formatter cannot call `tr`):

| kind | fields | meaning |
|---|---|---|
| `text` | `text` | a plain line, verbatim: hook markers, hook output, anything not JSON, unknown JSON rendered compactly |
| `progress` | `percent`, `filesDone`, `totalFiles`, `bytesDone`, `totalBytes` | restic `message_type == "status"` |
| `backup` | `filesNew`, `filesChanged`, `filesUnmodified`, `dirsNew`, `dirsChanged`, `dataAdded`, `bytesProcessed`, `durationSeconds` | `message_type == "summary"` from a backup |
| `check` | `errors`, `brokenPacks`, `suggestRepair`, `suggestPrune` | `message_type == "summary"` from a check |
| `records` | `count`, `source` | a folded record stream (`ls`, `diff`, `find`, `stats`: one line per record) |
| `error` | `message`, `code` | `message_type == "error"`, or a record carrying a top-level `error` |

Rules (all testable against the fixtures in `tests/fixtures/`):

* Only the **last** `status` line becomes a `progress` line; the others are counted in `collapsed`.
  A run with one status line reports `collapsed = 0`.
* `records` lines are counted, never emitted one per record — the panel has dedicated Files and Diff
  views for that. Prefer the object's own count field when the stream carries one (`ls`/`diff` do
  not; count the lines seen and say so).
* An `error` line is **never** dropped or folded, and neither is a `text` line.
* Output is bounded: at most `maxLines` entries, with `collapsed` telling the truth about what was
  folded. Work scales with the number of lines, never with bytes walked one at a time (the host's
  per-callback CPU budget — see §4).
* `raw` is the input split into lines, bounded to `rawLines` (the panel's Raw view).
* Malformed JSON, an empty line, a partial line, and a nil/!string input must all be handled without
  raising: a log viewer that crashes on a log is worse than no viewer.

### 2.2 `KEY_JOBLOG` (additive; existing fields keep their meaning)

```
{ kind, at, ok, cancelled, exitCode, truncated,       -- unchanged
  lines = { string },                                  -- unchanged: raw lines (the Raw view)
  display = { Line },                                  -- NEW: logfmt output
  collapsed = number }                                 -- NEW: folded progress/record lines
```

### 2.3 Service behaviour

* Publish `display` and `collapsed` in **both** places that currently set `KEY_JOBLOG`
  (`finishJob` and `publishJobLog`/`republishJobLog`), and on `initialise()`'s republish.
* While a job is **running**, refresh `KEY_JOBLOG` (bounded, from the same tail limits) as the poll
  observes growth, so the Log tab is live. Do not publish on ticks when nothing changed, and never
  from a tick when no job is active.

### 2.4 Panel behaviour

* **Log tab**: render `display` by default with real wrapping (no `maxLines = 1` clamping of JSON);
  a toggle switches to `lines` (Raw); show `collapsed` with `panel.logs.folded` when non-zero; keep
  the refresh button and the existing empty state (plus its hint).
* **Snapshot rows**: the trailing dots button opens an **in-panel action sheet** on left click,
  rendered beneath that row — a column of the existing actions plus `panel.action.details`. The
  native right-click context menu stays exactly as it is (`onRightClick` → `openMenu`). Clicking the
  dots again closes the sheet; so does running an action that changes the view.
* **Details** renders a card from the row (no new service call): snapshot id (short + full),
  captured (absolute local time **and** relative), host, tags, paths, files processed, bytes
  processed, data added. A field the row does not carry renders `panel.details.none`, never a
  fabricated zero.
* **Delete** is the existing two-step flow: the sheet's delete entry sets the same draft state the
  context menu already sets (`ui_state.forgetDraft`) and shows the existing confirmation. No
  destructive action may ever happen from a single click.

### 2.5 Manifest

`[[setting]]` entries `browser_placement` (floating|attached, default floating) and
`browser_position` (the ten positions, default center), each with `label_key` +
`description_key` and `options = [{ value, label_key }]`. Declaring them stops the host injecting
unlabelled ones. `plugin_api` stays 30.

### 2.6 Translation keys

Prepared in `translations/en.json` by the lead. Use **only** these (plus existing ones):

`panel.action.details`, `panel.logs.formatted`, `panel.logs.raw`, `panel.logs.progress`,
`panel.logs.backup`, `panel.logs.check`, `panel.logs.check_repair`, `panel.logs.records`,
`panel.logs.folded`, `panel.logs.error`, `panel.details.title`, `panel.details.captured`,
`panel.details.host`, `panel.details.tags`, `panel.details.paths`, `panel.details.files`,
`panel.details.bytes`, `panel.details.added`, `panel.details.snapshot_id`, `panel.details.none`,
`settings.browser_placement.*`, `settings.browser_position.*`.

Missing a string you need? **Report it, do not invent a key** — the panel's tests read the real
`en.json`, so an invented key fails the gate.

## 3. Workstreams and file ownership

| # | Branch | Worktree | Owns | Deliverable |
|---|---|---|---|---|
| A | `feat/logfmt` | `/home/ian/work/.wt-lg` | `plugin/restic-snapshots/lib/logfmt.luau`, `plugin/restic-snapshots/service.luau`, `tests/lua/logfmt_test.lua`, `tests/lua/service_test.lua`, `tests/test_logfmt.py` | the formatter and its wiring into the published log |
| B | `feat/panel-menu` | `/home/ian/work/.wt-pm` | `plugin/restic-snapshots/panel.luau`, `tests/lua/panel_render_test.lua` | the Log tab rendering and the snapshot action sheet + Details |

Nobody touches: `plugin.toml`, `translations/en.json`, `lib/state.luau`, `lib/store.luau`,
`lib/restic.luau`, `lib/jobs.luau`, `tests/lua/harness.lua`, `tests/fixtures/` (all lead-owned and
already prepared). A and B share no file, so they can run at the same time.

## 4. Ground rules (each of these cost a real failure; do not relearn them)

1. **Per-callback CPU budget.** A per-character string walk blew it on a 97 KB log and killed a
   service `update()` tick. Bound every loop by lines/records, never by bytes walked singly.
   `tests/test_source_invariants.py` fails on the per-character pattern — keep it passing.
2. **Glyph names are Tabler names** and must stay string literals. Audit before finishing:
   `python3 /tmp/glyph_audit.py plugin/restic-snapshots`.
3. **The shell logs to `~/.cache/noctalia/noctalia.log`**, not journalctl.
4. **IPC needs the entry**: `noctalia msg plugin carlocamacho/restic-snapshots:service all <event>`.
   The entry-less form answers "no plugin entry matched".
5. **Do not drive the live service** and do not edit `settings.toml`: the user's plugin is live and
   backing up hourly. Work in your worktree; read-only restic commands are fine.
6. **Bounded everything**: the panel renders on every state change, so no unbounded list, string or
   loop may reach it.
7. Gate: `bash /tmp/restic-gate.sh <your worktree> --quiet` must be green (13 suites + manifest
   lint + the python suite). Never weaken an existing assertion; only add.
8. Fixtures (authentic, captured from restic 0.19.1 on this machine) live in `tests/fixtures/`:
   `backup-progress.jsonl` (3 real status lines + summary), `backup-unchanged.jsonl`,
   `backup-summary.jsonl` (a real 473-byte job log), `check-summary.jsonl`, `error.jsonl`,
   `hooks.txt` (hook markers + output), `ls-list.jsonl` (40 `ls --json` lines),
   `ls-real.jsonl` (30 lines). Read them from LUA by `noctalia.readFile` (the harness maps them) or
   inline the text — your choice, but the tests must use the **real** shapes, not invented ones.

## 5. Report

State: files changed, the exact commands you ran and their results, what you could **not** verify,
and any decision the contract did not cover. Give a commit hash on your branch. Do not merge,
rebase, or push.
