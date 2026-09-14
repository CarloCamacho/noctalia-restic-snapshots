"""Tests for the restic command layer: argv builders, quoting, redaction and the validators.

Two layers, deliberately:

1. A **python mirror** of the frozen argv order (the shape `lib/restic.luau` must produce), and a
   **real cross-check**: a small Lua driver loads the actual `lib/restic.luau` through
   `tests/lua/harness.lua` with a stubbed host and prints what it builds, so a drift between the
   mirror and the library fails the test rather than passing silently.
2. Invariants that must hold whatever the implementation looks like: a hostile value survives a
   real POSIX shell round trip, a secret never survives `redactRepository`, and the restore-target
   validator refuses the dangerous destinations.

The parsers are asserted in `tests/lua/restic_pure_test.lua`, against verbatim restic 0.19.1
output captured on this machine (the parsers need a real JSON decoder, which the python side has
no access to).

The restore-verification helpers (0.3.0: which files to verify, where the scratch copy goes, and
the judgement of one comparison) are pure by design and are cross-checked here the same way the
argv builders are: the python mirror computes the expectation and the Lua driver prints what the
real library decided.

Run from the repo root:  python3 -m unittest discover -s tests
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(REPO, "plugin", "restic-snapshots", "lib", "restic.luau")
LUA = shutil.which("lua5.4")

HOSTILE = [
    "plain",
    "two words",
    "it's quoted",
    'double "quotes"',
    "semi;colon",
    "sub $(id -u)",
    "back `tick`",
    "newline\ninside",
    "glob * ? [a-z]",
    "amp & and &&",
    "redirect > file",
    "back\\slash",
    "unicode \u2713",
    "tab\there",
    "$HOME",
    "\r carriage",
    "empty''quote",
]

SNAPSHOT_ID = "bcd441d2560b76e9508748919f98f08480e6d703b7a297d3ffd7d0a0a80a5fce"
SNAPSHOT_ID_2 = "e29a0067ee7af2a20a89514bac24e85582a3155622351e33670ff1dbd8b93f44"
HOME = "/home/tester"

# The settings the python mirror and the Lua driver both start from.
SETTINGS = {
    "restic_bin": "/usr/bin/restic",
    "repository": "/srv/restic/repo",
    "password_file": "/run/secrets/restic-pass",
    "backup_paths": ["/home/tester/docs", "/etc"],
    "backup_tags": ["noctalia", "daily"],
    "exclude_file": "",
    "env_file": "",
    "mode": "plugin",
    "interval_minutes": 30,
    "job_timeout_minutes": 180,
    "check_interval_hours": 12,
    "stale_after_hours": 0,
    "keep_last": 7,
    "keep_daily": 7,
    "keep_weekly": 4,
    "keep_monthly": 6,
    "restore_target": "/home/tester/restore",
    "restore_allow_roots": ["/srv/staging"],
    "check_subset": "1/100",
    "verify_interval_hours": 6,
    "verify_file_count": 5,
}

# The listing a verification chooses from: regular files, a directory and a symlink without a size,
# an empty file, a file past the comparison bound, and a relative path that is not a path to
# compare with a live file. Mirrors what `restic ls --json` produces (parseLs entries).
VERIFY_ENTRIES = [
    {"name": "a", "type": "file", "path": "/data/a", "size": 10},
    {"name": "b", "type": "dir", "path": "/data/b"},
    {"name": "c", "type": "file", "path": "/data/c", "size": 0},
    {"name": "d", "type": "symlink", "path": "/data/d"},
    {"name": "e", "type": "file", "path": "/data/e", "size": 20},
    {"name": "f", "type": "file", "path": "/data/f", "size": 30},
    {"name": "g", "type": "file", "path": "/data/g", "size": 40},
    {"name": "h", "type": "file", "path": "/data/h", "size": 50},
    {"name": "i", "type": "file", "path": "/data/i", "size": 60},
    {"name": "j", "type": "file", "path": "/data/j", "size": 70},
    {"name": "k", "type": "file", "path": "/data/k", "size": 8 * 1024 * 1024},
    {"name": "l", "type": "file", "path": "relative/l", "size": 5},
]

VERIFY_MAX_BYTES = 4 * 1024 * 1024
VERIFY_FILES_MIN = 1
VERIFY_FILES_MAX = 25
VERIFY_FILES_DEFAULT = 3


def settings(**overrides):
    merged = dict(SETTINGS, **overrides)
    return merged


# ── the python mirror of the frozen argv order ───────────────────────────────
#
# `M.baseArgs` = bin [+ --password-file <path>] -r <repository>; every read-only command inserts
# `--no-lock` before the subcommand.


def shell_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def shell_argv(argv):
    return " ".join(shell_quote(item) for item in argv)


def base_args(cfg, bin_path=None):
    argv = [bin_path or cfg["restic_bin"]]
    if cfg["password_file"]:
        argv += ["--password-file", cfg["password_file"]]
    argv += ["-r", cfg["repository"]]
    return argv


def snapshots_args(cfg):
    return base_args(cfg) + ["--no-lock", "snapshots", "--json"]


def stats_args(cfg):
    return base_args(cfg) + ["--no-lock", "stats", "--json"]


def ls_args(cfg, snapshot):
    return base_args(cfg) + ["--no-lock", "ls", snapshot, "--json"]


def diff_args(cfg, from_id, to_id):
    return base_args(cfg) + ["--no-lock", "diff", from_id, to_id, "--json"]


def check_args(cfg, subset_override=None):
    subset = subset_override or cfg["check_subset"]
    argv = base_args(cfg) + ["check", "--json"]
    if subset:
        argv.append("--read-data-subset=" + subset)
    return argv


def backup_args(cfg):
    argv = base_args(cfg) + ["backup"] + list(cfg["backup_paths"]) + ["--json"]
    for tag in cfg["backup_tags"]:
        argv += ["--tag", tag]
    if cfg["exclude_file"]:
        argv += ["--exclude-file", cfg["exclude_file"]]
    return argv


def policy_args(cfg):
    argv = []
    for value, flag in ((cfg["keep_last"], "--keep-last"), (cfg["keep_daily"], "--keep-daily"),
                        (cfg["keep_weekly"], "--keep-weekly"), (cfg["keep_monthly"], "--keep-monthly")):
        if value and value > 0:
            argv += [flag, str(value)]
    return argv


def forget_args(cfg, dry_run=True):
    argv = base_args(cfg) + ["forget"] + policy_args(cfg)
    argv += ["--dry-run" if dry_run else "--prune", "--json"]
    return argv


def forget_one_args(cfg, snapshot_id):
    return base_args(cfg) + ["forget", snapshot_id, "--json"]


def restore_args(cfg, snapshot, target, includes=None, dry_run=False):
    argv = base_args(cfg) + ["restore", snapshot, "--target", target]
    for pattern in includes or []:
        argv += ["--include", pattern]
    if dry_run:
        argv.append("--dry-run")
    return argv + ["--json"]


def init_args(cfg):
    return base_args(cfg) + ["init", "--json"]


def unlock_args(cfg):
    return base_args(cfg) + ["unlock", "--remove-all", "--json"]


def human_bytes(value):
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    n = float(value)
    index = 0
    while n >= 1024 and index < len(units) - 1:
        n /= 1024
        index += 1
    return f"{int(n)} {units[index]}" if index == 0 else f"{n:.1f} {units[index]}"


# ── the python mirror of the restore-verification helpers (0.3.0) ────────────
# Same contract as the argv mirror above: an expectation computed here, cross-checked against what
# the real lib/restic.luau decides (the Lua driver emits it).


def verify_file_count(value):
    """M.config's clamp of verify_file_count (plugin.toml: min 1, max 25, default 3)."""
    try:
        count = int(value)
    except (TypeError, ValueError):
        count = 0
    if count < VERIFY_FILES_MIN:
        return VERIFY_FILES_DEFAULT
    if count > VERIFY_FILES_MAX:
        return VERIFY_FILES_MAX
    return count


def select_verify_files(entries, count, max_bytes=None):
    """M.selectVerifyFiles: regular files only, under the bound, spread evenly, content preferred."""
    want = verify_file_count(count)
    limit = max_bytes if isinstance(max_bytes, (int, float)) and max_bytes > 0 else VERIFY_MAX_BYTES
    usable, with_content = [], []
    skipped_empty = skipped_large = 0
    for entry in entries or []:
        if entry.get("type") != "file":
            continue
        path, size = entry.get("path"), entry.get("size")
        if not isinstance(path, str) or not path.startswith("/") or size is None:
            continue
        if size <= 0:
            skipped_empty += 1
            usable.append({"path": path, "size": size})
        elif size > limit:
            skipped_large += 1
        else:
            usable.append({"path": path, "size": size})
            with_content.append({"path": path, "size": size})
    pool = with_content if len(with_content) >= want else usable
    total = len(pool)
    picks = min(want, total)
    # Lua's index is math.floor((i - 0.5) * total / picks) + 1 (one-based)
    files = [pool[int((i - 0.5) * total / picks)] for i in range(1, picks + 1)]
    return {"files": files, "wanted": want, "available": total,
            "skippedEmpty": skipped_empty, "skippedLarge": skipped_large}


def verify_target(base, at):
    """M.verifyTarget: <restoreTarget>/.verify/<epoch>, or nothing when either part is unusable."""
    if not isinstance(base, str) or base == "":
        return None
    if not isinstance(at, (int, float)) or int(at) <= 0:
        return None
    return f"{base.rstrip('/')}/.verify/{int(at)}"


def mtime_seconds(value):
    """M.mtimeSeconds: epoch seconds; a millisecond value is recognised by magnitude."""
    if isinstance(value, str):
        try:
            value = float(value)
        except ValueError:
            return None
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
        return None
    if value >= 1e11:
        return int(value / 1000)
    return int(value)


# ── the Lua driver: the real library, driven through the test harness ─────────

LUA_DRIVER = r"""
package.path = "tests/lua/?.lua;" .. package.path
local H = dofile("tests/lua/harness.lua")
H.install("plugin/restic-snapshots")
H.env.HOME = %(home)r
local restic = H.load("lib/restic.luau")

local function emit(kind, name, value)
  io.write(kind .. "\t" .. name .. "\t" .. tostring(value) .. "\n")
end

local function emitArgv(name, argv, err)
  if argv == nil then
    emit("ERR", name, err)
    return
  end
  emit("ARGV", name, table.concat(argv, "\0"))
end

local BIN = "%(bin)s"
local cfg = restic.config(%(settings)s)
cfg.restoreTarget = "%(restore_target)s"

emitArgv("snapshots", restic.snapshotsArgs(cfg, BIN))
emitArgv("stats", restic.statsArgs(cfg, BIN))
emitArgv("ls", restic.lsArgs(cfg, BIN, "%(id1)s"))
emitArgv("diff", restic.diffArgs(cfg, BIN, "%(id1)s", "%(id2)s"))
emitArgv("check", restic.checkArgs(cfg, BIN))
emitArgv("check_override", restic.checkArgs(cfg, BIN, "3/7"))
emitArgv("backup", restic.backupArgs(cfg, BIN))
emitArgv("forget_dry", restic.forgetArgs(cfg, BIN, true))
emitArgv("forget_prune", restic.forgetArgs(cfg, BIN, false))
emitArgv("forget_one", restic.forgetOneArgs(cfg, BIN, "%(id1)s"))
emitArgv("forget_one_bad", restic.forgetOneArgs(cfg, BIN, "--host=evil"))
emitArgv("restore", restic.restoreArgs(cfg, BIN, "%(id1)s", "/home/tester/restore", { "/home/tester/docs/*" }))
emitArgv("restore_dry", restic.restoreArgs(cfg, BIN, "%(id1)s", "/home/tester/restore", nil, { dryRun = true }))
emitArgv("restore_bad_target", restic.restoreArgs(cfg, BIN, "%(id1)s", "relative/target"))
emitArgv("restore_bad_id", restic.restoreArgs(cfg, BIN, "latest", "/home/tester/restore"))
emitArgv("ls_bad_id", restic.lsArgs(cfg, BIN, "-x"))
emitArgv("init", restic.initArgs(cfg, BIN))
emitArgv("unlock", restic.unlockArgs(cfg, BIN))

-- ── restore verification (0.3.0) ─────────────────────────────────────────────

local verifyEntries = %(verify_entries)s

local function emitSelection(name, pick)
  local paths = {}
  for _, file in ipairs(pick.files) do
    table.insert(paths, file.path .. ":" .. tostring(file.size))
  end
  emit("SELECT", name, table.concat(paths, " ") .. "\0" .. tostring(pick.wanted) .. "\0"
    .. tostring(pick.available) .. "\0" .. tostring(pick.skippedEmpty) .. "\0"
    .. tostring(pick.skippedLarge))
end

emitSelection("default3", restic.selectVerifyFiles(verifyEntries, 3))
emitSelection("count1", restic.selectVerifyFiles(verifyEntries, 1))
emitSelection("count25", restic.selectVerifyFiles(verifyEntries, 25))
emitSelection("count0", restic.selectVerifyFiles(verifyEntries, 0))
emitSelection("count_nil", restic.selectVerifyFiles(verifyEntries, nil))
emitSelection("count99", restic.selectVerifyFiles(verifyEntries, 99))
emitSelection("tiny_bound", restic.selectVerifyFiles(verifyEntries, 3, 15))
emitSelection("bound_zero", restic.selectVerifyFiles(verifyEntries, 3, 0))
emitSelection("only_empty", restic.selectVerifyFiles({ { type = "file", path = "/data/c", size = 0 } }, 2))
emitSelection("no_files", restic.selectVerifyFiles({ { type = "dir", path = "/data/b" } }, 3))
emitSelection("no_entries", restic.selectVerifyFiles(nil, 3))

-- the settings clamp, straight out of M.config
emit("VERIFY", "max_bytes", restic.VERIFY_MAX_BYTES)
emit("VERIFY", "files_min", restic.VERIFY_FILES_MIN)
emit("VERIFY", "files_max", restic.VERIFY_FILES_MAX)
emit("VERIFY", "files_default", restic.VERIFY_FILES_DEFAULT)
emit("VERIFY", "count_nil", restic.config({}).verifyFileCount)
emit("VERIFY", "count_zero", restic.config({ verify_file_count = 0 }).verifyFileCount)
emit("VERIFY", "count_negative", restic.config({ verify_file_count = -5 }).verifyFileCount)
emit("VERIFY", "count_over", restic.config({ verify_file_count = 99 }).verifyFileCount)
emit("VERIFY", "count_string", restic.config({ verify_file_count = "4" }).verifyFileCount)
emit("VERIFY", "count_float", restic.config({ verify_file_count = 3.9 }).verifyFileCount)
emit("VERIFY", "interval_nil", restic.config({}).verifyIntervalHours)
emit("VERIFY", "interval_negative", restic.config({ verify_interval_hours = -3 }).verifyIntervalHours)
emit("VERIFY", "interval_string", restic.config({ verify_interval_hours = "6" }).verifyIntervalHours)

-- where the scratch copy goes
local function emitTarget(name, value)
  emit("VERIFY_TARGET", name, value == nil and "NIL" or value)
end
emitTarget("ok", restic.verifyTarget("/home/tester/restore", 1788874602))
emitTarget("trailing_slash", restic.verifyTarget("/home/tester/restore/", 7))
emitTarget("no_time", restic.verifyTarget("/home/tester/restore", nil))
emitTarget("zero_time", restic.verifyTarget("/home/tester/restore", 0))
emitTarget("no_base", restic.verifyTarget(nil, 1788874602))

-- the include list restic is handed: absolute paths only, one --include each, never a dry run
emitArgv("verify_restore", restic.verifyRestoreArgs(cfg, BIN, "%(id1)s",
  "/home/tester/restore/.verify/1788874602", {
    { path = "/home/tester/docs/a b" },
    { path = "/home/tester/docs/c" },
    { path = "relative/x" },
  }))
emitArgv("verify_restore_strings", restic.verifyRestoreArgs(cfg, BIN, "%(id1)s",
  "/home/tester/restore/.verify/1", { "/home/tester/docs/a", "relative/x" }))
emitArgv("verify_restore_none", restic.verifyRestoreArgs(cfg, BIN, "%(id1)s",
  "/home/tester/restore/.verify/1", {}))
emitArgv("verify_restore_bad_id", restic.verifyRestoreArgs(cfg, BIN, "latest",
  "/home/tester/restore/.verify/1", { "/home/tester/docs/a" }))

-- mtimes: seconds and milliseconds must never be confused
emit("MTIME", "seconds", tostring(restic.mtimeSeconds(1788874602)))
emit("MTIME", "float_seconds", tostring(restic.mtimeSeconds(1788874602.75)))
emit("MTIME", "milliseconds", tostring(restic.mtimeSeconds(1788874602000)))
emit("MTIME", "zero", tostring(restic.mtimeSeconds(0)))
emit("MTIME", "negative", tostring(restic.mtimeSeconds(-5)))
emit("MTIME", "nil", tostring(restic.mtimeSeconds(nil)))
emit("MTIME", "string", tostring(restic.mtimeSeconds("1788874602")))

-- the newest snapshot: invalid ids and unreadable times are never chosen
local newestRows = {
  { id = "aaaaaaaa", time = "2026-09-08T03:36:42+00:00" },
  { id = "not-hex", time = "2026-09-08T13:35:42+00:00" },
  { id = "bbbbbbbb", time = "2026-09-08T13:35:42+00:00" },
  { id = "cccccccc", time = "no timestamp here" },
}
local newest = restic.newestSnapshot(newestRows)
emit("NEWEST", "picks_the_newest_valid_row",
  tostring(newest ~= nil and newest.id or "NIL") .. "\0"
    .. tostring(newest ~= nil and newest.at or "NIL"))
emit("NEWEST", "empty", tostring(restic.newestSnapshot({}) == nil))
emit("NEWEST", "no_valid_row", tostring(
  restic.newestSnapshot({ { id = "zzz", time = "2026-09-08T13:35:42+00:00" } }) == nil))
emit("NEWEST", "nil_rows", tostring(restic.newestSnapshot(nil) == nil))

-- the judgement for one file: matched / failed / skipped, and why
local snapshotAt = 1788874542
local outcomeCases = {
  { "matched", { read = true, text = "same" },
    { exists = true, isFile = true, read = true, text = "same", mtime = snapshotAt - 60, size = 4 },
    { snapshotAt = snapshotAt } },
  { "failed_differs", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = true, text = "live", mtime = snapshotAt - 60, size = 4 },
    { snapshotAt = snapshotAt } },
  { "failed_unknown_snapshot_time", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = true, text = "live", mtime = snapshotAt - 60, size = 4 },
    { snapshotAt = nil } },
  { "failed_unknown_mtime", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = true, text = "live", mtime = nil, size = 4 },
    { snapshotAt = snapshotAt } },
  { "skipped_changed_wins_over_too_large", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = true, text = "live", mtime = snapshotAt + 60, size = 4 },
    { snapshotAt = snapshotAt, maxBytes = 100 } },
  { "skipped_changed_after", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = true, text = "live", mtime = snapshotAt + 60, size = 4 },
    { snapshotAt = snapshotAt } },
  { "skipped_changed_even_if_identical", { read = true, text = "same" },
    { exists = true, isFile = true, read = true, text = "same", mtime = snapshotAt + 60, size = 4 },
    { snapshotAt = snapshotAt } },
  { "skipped_gone", { read = true, text = "snapshot" },
    { exists = false, isFile = false, read = false, mtime = nil, size = nil },
    { snapshotAt = snapshotAt } },
  { "skipped_replaced_by_a_directory", { read = true, text = "snapshot" },
    { exists = true, isFile = false, read = false, mtime = snapshotAt, size = 0 },
    { snapshotAt = snapshotAt } },
  { "skipped_too_large", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = false, mtime = snapshotAt - 60, size = 10 },
    { snapshotAt = snapshotAt, maxBytes = 5 } },
  { "skipped_unreadable", { read = true, text = "snapshot" },
    { exists = true, isFile = true, read = false, mtime = snapshotAt - 60, size = 4 },
    { snapshotAt = snapshotAt } },
  { "failed_no_restored_copy", { read = false },
    { exists = true, isFile = true, read = true, text = "live", mtime = snapshotAt - 60, size = 4 },
    { snapshotAt = snapshotAt } },
  { "failed_restored_without_text", { read = true },
    { exists = true, isFile = true, read = true, text = "live", mtime = snapshotAt - 60, size = 4 },
    { snapshotAt = snapshotAt } },
}

for _, case in ipairs(outcomeCases) do
  local outcome = restic.verifyOutcome(case[2], case[3], case[4])
  emit("OUTCOME", case[1], tostring(outcome.status) .. "\0" .. tostring(outcome.reason))
end

-- config shape: every frozen key, with its value
local frozen = { "bin", "repository", "redactedRepository", "passwordFile", "paths", "tags",
  "excludeFile", "mode", "intervalMinutes", "keepLast", "keepDaily", "keepWeekly", "keepMonthly",
  "restoreTarget", "restoreAllowRoots", "checkSubset", "checkIntervalHours", "staleAfterHours",
  "jobTimeoutMinutes", "envFile", "verifyIntervalHours", "verifyFileCount" }
for _, key in ipairs(frozen) do
  local value = cfg[key]
  if value == nil then
    emit("MISSING", key, key)
  else
    emit("CONFIG", key, type(value) == "table" and table.concat(value, ",") or tostring(value))
  end
end

emit("QUOTE", "plain", restic.shellQuote("plain"))
emit("QUOTE", "hostile", restic.shellQuote("it's a $(dangerous) path"))
emit("ARGV_JOIN", "join", restic.shellArgv({ "a b", "c" }))

-- redaction, driven against the real function
local redactCases = {
  { "local", "/home/tester/backups" },
  { "tilde", "~/backups" },
  { "relative", "backups/2026" },
  { "url", "sftp://ian:sup3rs3cret@backup.example.com:/srv/restic" },
  { "scp", "sftp:ian:hunter2@host:/srv/repo" },
  { "query", "rest:https://backup.example.com/repo?token=abc123&user=ian" },
  { "token_segment", "rclone:remote:9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b" },
}
for _, case in ipairs(redactCases) do
  local once = restic.redactRepository(case[2])
  emit("REDACT", case[1], once)
  -- the widget is handed an already-redacted string; a second pass must not change it
  emit("REDACT_AGAIN", case[1], restic.redactRepository(once))
end

-- validators
emit("VALID", "id_real", restic.validSnapshotId("%(id1)s"))
emit("VALID", "id_short", restic.validSnapshotId("abc"))
emit("VALID", "id_uppercase", restic.validSnapshotId("ABCD1234"))
emit("VALID", "id_64", restic.validSnapshotId(string.rep("a", 64)))
emit("VALID", "id_65", restic.validSnapshotId(string.rep("a", 65)))
emit("VALID", "id_latest", restic.validSnapshotId("latest"))
emit("VALID", "id_flag", restic.validSnapshotId("--host=x"))
emit("VALID", "id_trailing_space", restic.validSnapshotId("%(id1)s "))

local targetCases = {
  { "staging_ok", "/home/tester/restore" },
  { "staging_sub", "/home/tester/restore/2026-09-14" },
  { "allow_root", "/srv/staging/restored" },
  { "relative", "relative/restore" },
  { "empty", "" },
  { "root", "/" },
  { "home", "/home/tester" },
  { "home_slash", "/home/tester/" },
  { "source", "/home/tester/docs" },
  { "source_sub", "/home/tester/docs/sub/file" },
  { "source_etc", "/etc/hosts" },
  { "dotdot_escape", "/home/tester/restore/../docs/x" },
  { "sibling_prefix", "/home/tester/docs-archive" },
  { "staging_sibling", "/home/tester/restore-old/x" },
  { "elsewhere", "/tmp/elsewhere" },
  { "prefix_only", "/home/tester/doc" },
  { "occupied", "/home/tester/restore/occupied" },
  { "new_dir", "/home/tester/restore/brand-new" },
}
H.files["/home/tester/restore/occupied"] = "already a file"
for _, case in ipairs(targetCases) do
  local ok, err = restic.validRestoreTarget(cfg, case[2])
  emit("TARGET", case[1], tostring(ok) .. "\0" .. tostring(err))
end
local okNil, errNil = restic.validRestoreTarget(cfg, nil)
emit("TARGET", "nil_path", tostring(okNil) .. "\0" .. tostring(errNil))
local okNoCfg, errNoCfg = restic.validRestoreTarget(nil, "/tmp/x")
emit("TARGET", "no_cfg", tostring(okNoCfg) .. "\0" .. tostring(errNoCfg))
"""


def lua_literal(value):
    """Render a python value as a Lua literal for the driver's settings table."""
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return "{" + ", ".join(lua_literal(item) for item in value) + "}"
    if isinstance(value, dict):
        body = ", ".join(f"{key} = {lua_literal(item)}" for key, item in sorted(value.items()))
        return "{" + body + "}"
    raise TypeError(f"unsupported setting type: {type(value)!r}")


def lua_settings(cfg):
    body = ", ".join(f"{key} = {lua_literal(value)}" for key, value in sorted(cfg.items()))
    return "{" + body + "}"


@unittest.skipUnless(LUA, "lua5.4 is not installed")
class TestLuaLibrary(unittest.TestCase):
    """Drives the real lib/restic.luau through the harness; nothing here is a reimplementation."""

    @classmethod
    def setUpClass(cls):
        cfg = settings()
        source = LUA_DRIVER % {
            "home": HOME,
            "bin": "/usr/bin/restic",
            "settings": lua_settings(cfg),
            "restore_target": cfg["restore_target"],
            "id1": SNAPSHOT_ID,
            "id2": SNAPSHOT_ID_2,
            "verify_entries": lua_literal(VERIFY_ENTRIES),
        }
        cls.driver = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False)
        cls.driver.write(source)
        cls.driver.close()
        result = subprocess.run([LUA, cls.driver.name], cwd=REPO, capture_output=True)
        if result.returncode != 0:
            raise AssertionError("lua driver failed:\n" + result.stderr.decode())
        cls.cfg = cfg
        cls.argv = {}
        cls.config = {}
        cls.quote = {}
        cls.redact = {}
        cls.redact_again = {}
        cls.valid = {}
        cls.target = {}
        cls.selection = {}
        cls.verify = {}
        cls.verify_target = {}
        cls.outcome = {}
        cls.mtime = {}
        cls.newest = {}
        cls.errors = {}
        cls.output = result.stdout.decode()
        for line in cls.output.splitlines():
            kind, name, value = line.split("\t", 2)
            if kind == "ARGV":
                cls.argv[name] = value.split("\0")
            elif kind == "ERR":
                cls.errors[name] = value
            elif kind == "CONFIG":
                cls.config[name] = value
            elif kind == "MISSING":
                cls.config[name] = None
            elif kind == "QUOTE":
                cls.quote[name] = value
            elif kind == "ARGV_JOIN":
                cls.quote["join"] = value
            elif kind == "REDACT":
                cls.redact[name] = value
            elif kind == "REDACT_AGAIN":
                cls.redact_again[name] = value
            elif kind == "VALID":
                cls.valid[name] = value
            elif kind == "TARGET":
                ok, err = value.split("\0", 1)
                cls.target[name] = (ok == "true", err)
            elif kind == "SELECT":
                paths, wanted, available, empty, large = value.split("\0")
                files = []
                for item in paths.split(" "):
                    if item:
                        path, size = item.rsplit(":", 1)
                        files.append({"path": path, "size": int(size)})
                cls.selection[name] = {
                    "files": files,
                    "wanted": int(wanted),
                    "available": int(available),
                    "skippedEmpty": int(empty),
                    "skippedLarge": int(large),
                }
            elif kind == "VERIFY":
                cls.verify[name] = value
            elif kind == "VERIFY_TARGET":
                cls.verify_target[name] = None if value == "NIL" else value
            elif kind == "OUTCOME":
                outcome_status, outcome_reason = value.split("\0", 1)
                cls.outcome[name] = (outcome_status, outcome_reason)
            elif kind == "MTIME":
                cls.mtime[name] = None if value == "nil" else int(value)
            elif kind == "NEWEST":
                parts = value.split("\0")
                if len(parts) == 1:
                    cls.newest[name] = parts[0] == "true"
                else:
                    cls.newest[name] = (None if parts[0] == "NIL" else parts[0],
                                        None if parts[1] == "NIL" else int(parts[1]))

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.driver.name)

    # ── config ───────────────────────────────────────────────────────────────

    def test_every_frozen_config_key_is_present(self):
        missing = [key for key, value in self.config.items() if value is None]
        self.assertEqual(missing, [], f"config keys missing from M.config: {missing}")

    def test_config_values_match_the_settings(self):
        cfg = self.cfg
        self.assertEqual(self.config["bin"], cfg["restic_bin"])
        self.assertEqual(self.config["repository"], cfg["repository"])
        self.assertEqual(self.config["redactedRepository"], cfg["repository"])  # a local path
        self.assertEqual(self.config["passwordFile"], cfg["password_file"])
        self.assertEqual(self.config["mode"], cfg["mode"])
        self.assertEqual(self.config["intervalMinutes"], str(cfg["interval_minutes"]))
        self.assertEqual(self.config["checkSubset"], cfg["check_subset"])
        self.assertEqual(self.config["checkIntervalHours"], str(cfg["check_interval_hours"]))
        self.assertEqual(self.config["staleAfterHours"], str(cfg["stale_after_hours"]))
        self.assertEqual(self.config["jobTimeoutMinutes"], str(cfg["job_timeout_minutes"]))
        self.assertEqual(self.config["restoreTarget"], cfg["restore_target"])
        self.assertEqual(self.config["restoreAllowRoots"], ",".join(cfg["restore_allow_roots"]))

    # ── argv: the library against the mirror ─────────────────────────────────

    def assert_argv(self, name, expected):
        self.assertIn(name, self.argv, f"{name}: the library returned an error: {self.errors.get(name)}")
        self.assertEqual(self.argv[name], expected, name)

    def test_read_only_builders(self):
        cfg = self.cfg
        self.assert_argv("snapshots", snapshots_args(cfg))
        self.assert_argv("stats", stats_args(cfg))
        self.assert_argv("ls", ls_args(cfg, SNAPSHOT_ID))
        self.assert_argv("diff", diff_args(cfg, SNAPSHOT_ID, SNAPSHOT_ID_2))

    def test_every_read_only_builder_never_locks(self):
        for name in ("snapshots", "stats", "ls", "diff"):
            argv = self.argv[name]
            self.assertIn("--no-lock", argv, name)
            command = {"snapshots": "snapshots", "stats": "stats", "ls": "ls", "diff": "diff"}[name]
            self.assertLess(argv.index("--no-lock"), argv.index(command), name)

    def test_check_uses_the_configured_subset_and_the_override_wins(self):
        self.assert_argv("check", check_args(self.cfg))
        self.assert_argv("check_override", check_args(self.cfg, "3/7"))
        # check is not read-only in restic's locking model
        self.assertNotIn("--no-lock", self.argv["check"])

    def test_backup_and_retention_are_unchanged(self):
        self.assert_argv("backup", backup_args(self.cfg))
        self.assert_argv("forget_dry", forget_args(self.cfg, True))
        self.assert_argv("forget_prune", forget_args(self.cfg, False))

    def test_forget_one_never_prunes(self):
        self.assert_argv("forget_one", forget_one_args(self.cfg, SNAPSHOT_ID))
        self.assertNotIn("--prune", self.argv["forget_one"])
        self.assertNotIn("--dry-run", self.argv["forget_one"])

    def test_restore_builders(self):
        self.assert_argv("restore", restore_args(self.cfg, SNAPSHOT_ID, "/home/tester/restore",
                                                 ["/home/tester/docs/*"]))
        self.assert_argv("restore_dry", restore_args(self.cfg, SNAPSHOT_ID, "/home/tester/restore",
                                                     None, dry_run=True))
        self.assertNotIn("--dry-run", self.argv["restore"])
        self.assertIn("--dry-run", self.argv["restore_dry"])

    def test_init_and_unlock(self):
        self.assert_argv("init", init_args(self.cfg))
        self.assert_argv("unlock", unlock_args(self.cfg))
        # unlock exists to remove a stale lock: --no-lock would defeat it
        self.assertNotIn("--no-lock", self.argv["unlock"])

    def test_password_only_ever_travels_as_a_flag(self):
        for name in ("snapshots", "backup", "restore", "forget_one", "unlock"):
            argv = self.argv[name]
            self.assertIn("--password-file", argv)
            self.assertEqual(argv[argv.index("--password-file") + 1], self.cfg["password_file"])
            self.assertNotIn("-p", argv)

    def test_untrusted_ids_and_targets_are_refused_before_restic_sees_them(self):
        # a rejection is nil + reason, never an argv that carries the hostile value
        for name in ("forget_one_bad", "ls_bad_id", "restore_bad_id", "restore_bad_target"):
            self.assertNotIn(name, self.argv, f"{name} produced an argv")
            self.assertIn(name, self.errors, f"{name} produced no error")
        self.assertTrue(all(isinstance(self.errors[name], str) and self.errors[name]
                            for name in ("forget_one_bad", "ls_bad_id", "restore_bad_id",
                                         "restore_bad_target")))

    # ── quoting ──────────────────────────────────────────────────────────────

    def test_quoting_matches_the_shell_rule(self):
        self.assertEqual(self.quote["plain"], shell_quote("plain"))
        self.assertEqual(self.quote["hostile"], shell_quote("it's a $(dangerous) path"))
        self.assertEqual(self.quote["join"], shell_argv(["a b", "c"]))

    # ── redaction ────────────────────────────────────────────────────────────

    def test_local_paths_are_never_redacted(self):
        for name in ("local", "tilde", "relative"):
            original = {"local": "/home/tester/backups", "tilde": "~/backups",
                        "relative": "backups/2026"}[name]
            self.assertEqual(self.redact[name], original, name)

    def test_credentials_never_survive_redaction(self):
        url = self.redact["url"]
        self.assertNotIn("ian", url)
        self.assertNotIn("sup3rs3cret", url)
        self.assertIn("backup.example.com", url)
        scp = self.redact["scp"]
        self.assertNotIn("ian", scp)
        self.assertNotIn("hunter2", scp)
        self.assertIn("host", scp)
        query = self.redact["query"]
        self.assertNotIn("abc123", query)
        self.assertIn("backup.example.com", query)
        token = self.redact["token_segment"]
        self.assertNotIn("9f2c1d4e", token)

    def test_redaction_is_idempotent(self):
        # the widget receives an already-redacted repository string; redacting again must not
        # mangle the host into something unrecognisable
        for name in ("url", "scp", "query", "token_segment", "local", "tilde", "relative"):
            self.assertEqual(self.redact_again[name], self.redact[name], name)

    # ── validators ───────────────────────────────────────────────────────────

    def test_snapshot_id_rules(self):
        self.assertEqual(self.valid["id_real"], "true")
        self.assertEqual(self.valid["id_uppercase"], "true")
        self.assertEqual(self.valid["id_64"], "true")
        for refused in ("id_short", "id_65", "id_latest", "id_flag", "id_trailing_space"):
            self.assertEqual(self.valid[refused], "false", refused)

    def test_restore_target_accepts_only_the_allow_list(self):
        self.assertEqual(self.target["staging_ok"][0], True)
        self.assertEqual(self.target["staging_sub"][0], True)
        self.assertEqual(self.target["allow_root"][0], True)
        self.assertEqual(self.target["new_dir"][0], True)

    def test_restore_target_refusals_name_a_reason(self):
        for name in ("relative", "empty", "root", "home", "home_slash", "source", "source_sub",
                     "source_etc", "dotdot_escape", "sibling_prefix", "staging_sibling",
                     "elsewhere", "prefix_only", "occupied", "nil_path", "no_cfg"):
            ok, err = self.target[name]
            self.assertFalse(ok, f"{name} was allowed")
            self.assertTrue(err and err.strip(), f"{name} was refused without a reason")

    def test_restore_target_specific_reasons(self):
        self.assertIn("absolute", self.target["relative"][1])
        self.assertIn("root", self.target["root"][1])
        self.assertIn("home", self.target["home"][1])
        self.assertIn("backup source", self.target["source"][1])
        self.assertIn("backup source", self.target["dotdot_escape"][1])
        self.assertIn("not a directory", self.target["occupied"][1])
        # a prefix sibling must fail because it is outside the allow-list, not because of a naive
        # string-prefix match against the backup source
        self.assertIn("must be inside", self.target["sibling_prefix"][1])
        self.assertIn("must be inside", self.target["prefix_only"][1])

    # ── restore verification (0.3.0) ─────────────────────────────────────────

    def test_verification_bounds_match_the_manifest(self):
        self.assertEqual(int(self.verify["max_bytes"]), VERIFY_MAX_BYTES)
        self.assertEqual(int(self.verify["files_min"]), VERIFY_FILES_MIN)
        self.assertEqual(int(self.verify["files_max"]), VERIFY_FILES_MAX)
        self.assertEqual(int(self.verify["files_default"]), VERIFY_FILES_DEFAULT)

    def test_verify_settings_are_read_and_clamped(self):
        self.assertEqual(self.config["verifyIntervalHours"], str(self.cfg["verify_interval_hours"]))
        self.assertEqual(self.config["verifyFileCount"], str(self.cfg["verify_file_count"]))
        for name, raw, expected in (("count_nil", None, 3), ("count_zero", 0, 3),
                                    ("count_negative", -5, 3), ("count_over", 99, 25),
                                    ("count_string", "4", 4), ("count_float", 3.9, 3)):
            self.assertEqual(int(self.verify[name]), expected, name)
            self.assertEqual(verify_file_count(raw), expected, name)
        # a verification interval is never negative, and a string setting is honoured
        self.assertEqual(int(self.verify["interval_nil"]), 0)
        self.assertEqual(int(self.verify["interval_negative"]), 0)
        self.assertEqual(int(self.verify["interval_string"]), 6)

    def test_file_selection_matches_the_mirror(self):
        cases = {
            "default3": (VERIFY_ENTRIES, 3, None),
            "count1": (VERIFY_ENTRIES, 1, None),
            "count25": (VERIFY_ENTRIES, 25, None),
            "count0": (VERIFY_ENTRIES, 0, None),
            "count_nil": (VERIFY_ENTRIES, None, None),
            "count99": (VERIFY_ENTRIES, 99, None),
            "tiny_bound": (VERIFY_ENTRIES, 3, 15),
            "bound_zero": (VERIFY_ENTRIES, 3, 0),
            "only_empty": ([{"type": "file", "path": "/data/c", "size": 0}], 2, None),
            "no_files": ([{"type": "dir", "path": "/data/b"}], 3, None),
            "no_entries": (None, 3, None),
        }
        self.assertEqual(set(self.selection), set(cases))
        for name, (entries, count, max_bytes) in cases.items():
            self.assertEqual(self.selection[name], select_verify_files(entries, count, max_bytes),
                             name)

    def test_file_selection_rules(self):
        picked = self.selection["default3"]
        # deterministic and spread: 7 candidates, 3 picks, evenly spaced through the listing
        self.assertEqual([f["path"] for f in picked["files"]],
                         ["/data/e", "/data/g", "/data/i"])
        self.assertEqual(picked["available"], 7)
        self.assertEqual(picked["skippedEmpty"], 1)
        self.assertEqual(picked["skippedLarge"], 1)
        self.assertTrue(all(f["size"] > 0 for f in picked["files"]),
                        "a verification must prefer files with content")
        self.assertTrue(all(f["size"] <= VERIFY_MAX_BYTES for f in picked["files"]))
        # never a directory, a symlink, a relative path or a file past the comparison bound
        for name in ("default3", "count25", "count99"):
            paths = [f["path"] for f in self.selection[name]["files"]]
            for refused in ("/data/b", "/data/d", "relative/l", "/data/k"):
                self.assertNotIn(refused, paths, name)
        # an empty repository of usable files is reported as such, not as a match
        self.assertEqual(self.selection["no_files"]["files"], [])
        self.assertEqual(self.selection["no_entries"]["files"], [])
        # a snapshot of only empty files still verifies rather than refusing
        self.assertEqual(self.selection["only_empty"]["files"], [{"path": "/data/c", "size": 0}])
        self.assertEqual(self.selection["count99"]["wanted"], VERIFY_FILES_MAX)
        # a tighter bound leaves fewer candidates and says how many it dropped
        self.assertEqual(self.selection["tiny_bound"]["skippedLarge"], 7)
        self.assertEqual(self.selection["bound_zero"]["files"], picked["files"])

    def test_judgement_of_one_file(self):
        expected = {
            "matched": ("matched", None),
            "failed_differs": ("failed", "does not match"),
            "failed_unknown_snapshot_time": ("failed", "does not match"),
            "failed_unknown_mtime": ("failed", "does not match"),
            "skipped_changed_wins_over_too_large": ("skipped", "changed after the snapshot"),
            "skipped_changed_after": ("skipped", "changed after the snapshot"),
            "skipped_changed_even_if_identical": ("skipped", "changed after the snapshot"),
            "skipped_gone": ("skipped", "is gone"),
            "skipped_replaced_by_a_directory": ("skipped", "is gone"),
            "skipped_too_large": ("skipped", "too large"),
            "skipped_unreadable": ("skipped", "could not be read"),
            "failed_no_restored_copy": ("failed", "no readable copy"),
            "failed_restored_without_text": ("failed", "no readable copy"),
        }
        self.assertEqual(set(self.outcome), set(expected))
        for name, (status, needle) in expected.items():
            actual, reason = self.outcome[name]
            self.assertEqual(actual, status, name)
            self.assertIn(actual, ("matched", "failed", "skipped"), name)
            if needle is not None:
                self.assertIn(needle, reason, name)
        # a difference is a failure even with nothing to compare the age against
        self.assertEqual(self.outcome["failed_unknown_snapshot_time"][0], "failed")
        self.assertEqual(self.outcome["failed_unknown_mtime"][0], "failed")
        # and a restore that produced nothing readable is a failure, never a skip
        self.assertEqual(self.outcome["failed_no_restored_copy"][0], "failed")

    def test_scratch_directory_is_inside_the_restore_target(self):
        self.assertEqual(self.verify_target["ok"], verify_target("/home/tester/restore", 1788874602))
        self.assertEqual(self.verify_target["ok"], "/home/tester/restore/.verify/1788874602")
        self.assertEqual(self.verify_target["trailing_slash"], "/home/tester/restore/.verify/7")
        for refused in ("no_time", "zero_time", "no_base"):
            self.assertIsNone(self.verify_target[refused], refused)

    def test_verify_restore_argv_is_a_plain_restore_of_the_chosen_files(self):
        target = "/home/tester/restore/.verify/1788874602"
        self.assert_argv("verify_restore", restore_args(
            self.cfg, SNAPSHOT_ID, target, ["/home/tester/docs/a b", "/home/tester/docs/c"]))
        self.assertNotIn("--dry-run", self.argv["verify_restore"])
        self.assertNotIn("relative/x", self.argv["verify_restore"])
        self.assert_argv("verify_restore_strings", restore_args(
            self.cfg, SNAPSHOT_ID, "/home/tester/restore/.verify/1", ["/home/tester/docs/a"]))
        # an empty file set is refused rather than restoring nothing and calling it a success
        self.assertNotIn("verify_restore_none", self.argv)
        self.assertEqual(self.errors["verify_restore_none"], "no files to verify")
        self.assertNotIn("verify_restore_bad_id", self.argv)

    def test_mtime_units_are_never_confused(self):
        for name, raw in (("seconds", 1788874602), ("float_seconds", 1788874602.75),
                          ("milliseconds", 1788874602000), ("zero", 0), ("negative", -5),
                          ("nil", None), ("string", "1788874602")):
            self.assertEqual(self.mtime[name], mtime_seconds(raw), name)
        self.assertEqual(self.mtime["milliseconds"], self.mtime["seconds"])
        self.assertIsNone(self.mtime["zero"])

    def test_newest_snapshot_skips_rows_that_cannot_be_used(self):
        self.assertEqual(self.newest["picks_the_newest_valid_row"], ("bbbbbbbb", 1788874542))
        self.assertTrue(self.newest["empty"])
        self.assertTrue(self.newest["no_valid_row"])
        self.assertTrue(self.newest["nil_rows"])


class TestQuoting(unittest.TestCase):
    def test_round_trip_preserves_bytes(self):
        for value in HOSTILE:
            self.assertEqual(round_trip(value), value, "failed for %r" % value)

    def test_argv_round_trip(self):
        argv = ["/tmp/it's here", "--tag", "a b", "$(id)"]
        cmd = "printf '%s\\n' " + shell_argv(argv)
        out = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, check=True).stdout.decode()
        self.assertEqual(out.splitlines(), argv)

    def test_hostile_path_stays_a_single_argv_element(self):
        hostile = "/tmp/it's a $(dangerous) path"
        argv = backup_args(settings(backup_paths=[hostile]))
        self.assertIn(hostile, argv)
        line = "printf '%s\\n' " + shell_argv(argv)
        out = subprocess.run(["/bin/sh", "-c", line], capture_output=True, check=True).stdout.decode()
        self.assertIn(hostile, out.splitlines())

    def test_no_shell_string_is_built_from_settings(self):
        # the generated job script quotes each argv element; nothing interpolates a setting into
        # an unquoted shell fragment (lib/jobs.luau calls exactly these two helpers)
        argv = restore_args(settings(repository="rest:http://h/r; rm -rf /"),
                            SNAPSHOT_ID, "/home/tester/restore", ["/home/tester/docs/*"])
        line = shell_argv(argv)
        out = subprocess.run(["/bin/sh", "-c", "printf '%s\\n' " + line], capture_output=True,
                             check=True).stdout.decode()
        self.assertEqual(out.splitlines(), argv)


def round_trip(value):
    cmd = "printf %s " + shell_quote(value)
    result = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, check=True)
    return result.stdout.decode()


class TestPolicyMirror(unittest.TestCase):
    """The retention rules restic would be asked to apply (unchanged in 0.2.0)."""

    def test_policy_requires_at_least_one_rule(self):
        self.assertEqual(policy_args(settings(keep_last=0, keep_daily=0, keep_weekly=0,
                                              keep_monthly=0)), [])
        self.assertTrue(policy_args(settings()))

    def test_forget_dry_run_differs_from_prune(self):
        self.assertIn("--dry-run", forget_args(settings(), dry_run=True))
        self.assertNotIn("--dry-run", forget_args(settings(), dry_run=False))
        self.assertIn("--prune", forget_args(settings(), dry_run=False))

    def test_backup_exclude_file_only_when_set(self):
        self.assertNotIn("--exclude-file", backup_args(settings(exclude_file="")))
        self.assertIn("--exclude-file", backup_args(settings(exclude_file="/tmp/excludes")))


class TestLibrarySource(unittest.TestCase):
    """Static properties of the library that must not regress with a refactor."""

    @classmethod
    def setUpClass(cls):
        with open(LIB, encoding="utf-8") as handle:
            cls.source = handle.read()

    def function_body(self, name):
        """The whole body of `M.<name>`: up to the next top-level function or section banner."""
        start = self.source.index(f"function M.{name}")
        body = self.source[start:]
        for marker in ("\nfunction M.", "\n-- ──"):
            index = body.find(marker)
            if index != -1:
                body = body[:index]
        return body

    def test_no_process_or_file_io(self):
        for forbidden in ("os.execute", "io.popen", "io.open", "loadfile", "dofile", "require("):
            self.assertNotIn(forbidden, self.source, forbidden)

    def test_quoting_helpers_are_exported_for_jobs_luau(self):
        self.assertIn("function M.shellQuote", self.source)
        self.assertIn("function M.shellArgv", self.source)

    def test_forget_one_never_contains_prune(self):
        body = self.function_body("forgetOneArgs")
        self.assertNotIn("--prune", body)
        self.assertIn("--json", body)
        self.assertIn("validSnapshotId", body)

    def test_every_frozen_export_exists(self):
        for name in ("config", "baseArgs", "backupArgs", "snapshotsArgs", "statsArgs", "checkArgs",
                     "policyArgs", "hasPolicy", "forgetArgs", "forgetOneArgs", "restoreArgs",
                     "lsArgs", "diffArgs", "initArgs", "unlockArgs", "parseJsonLines",
                     "lastSummary", "lastStatusLine", "parseSnapshots", "parseObject", "parseStats",
                     "parseLs", "parseDiff", "snapshotRow", "snapshotSummary", "summariseForgetDry",
                     "filterSnapshots", "validSnapshotId", "validRestoreTarget", "redactRepository",
                     "humanBytes", "ageLabel", "shellQuote", "shellArgv",
                     # 0.3.0 restore verification
                     "mtimeSeconds", "newestSnapshot", "verifyTarget", "selectVerifyFiles",
                     "verifyIncludes", "verifyRestoreArgs", "verifyOutcome"):
            self.assertIn(f"function M.{name}(", self.source, name)

    def test_verification_helpers_are_pure_and_bounded(self):
        # the judgement itself must not do I/O: the service owns the reads, so the part that
        # decides "the backup restores" stays testable (and cannot quietly read a live file)
        for name in ("selectVerifyFiles", "verifyOutcome", "verifyTarget", "newestSnapshot"):
            body = self.function_body(name)
            for forbidden in ("noctalia.", "os.", "io."):
                self.assertNotIn(forbidden, body, f"{name} must stay pure")

    def test_verification_never_uses_a_shell_or_a_credential(self):
        for name in ("verifyRestoreArgs", "verifyIncludes"):
            body = self.function_body(name)
            self.assertNotIn("shell", body, name)
            self.assertNotIn("password", body, name)
        # the restore half is built by the same builder the user-facing restore uses
        self.assertIn("restoreArgs", self.function_body("verifyRestoreArgs"))

    def test_read_only_builders_go_through_the_no_lock_helper(self):
        for name in ("snapshotsArgs", "statsArgs", "lsArgs", "diffArgs"):
            self.assertIn("readOnlyArgs", self.function_body(name), name)


class TestFormatting(unittest.TestCase):
    def test_human_bytes(self):
        self.assertEqual(human_bytes(0), "0 B")
        self.assertEqual(human_bytes(512), "512 B")
        self.assertEqual(human_bytes(2048), "2.0 KiB")
        self.assertEqual(human_bytes(5 * 1024 * 1024), "5.0 MiB")


if __name__ == "__main__":
    unittest.main()
