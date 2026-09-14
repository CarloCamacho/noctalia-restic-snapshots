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
}


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

-- config shape: every frozen key, with its value
local frozen = { "bin", "repository", "redactedRepository", "passwordFile", "paths", "tags",
  "excludeFile", "mode", "intervalMinutes", "keepLast", "keepDaily", "keepWeekly", "keepMonthly",
  "restoreTarget", "restoreAllowRoots", "checkSubset", "checkIntervalHours", "staleAfterHours",
  "jobTimeoutMinutes", "envFile" }
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
                     "humanBytes", "ageLabel", "shellQuote", "shellArgv"):
            self.assertIn(f"function M.{name}(", self.source, name)

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
