"""Tests for the restic argv builders and quoting rules.

Mirrors `plugin/restic-snapshots/lib/restic.luau`. The quoting test round-trips hostile values
through a real POSIX shell, because that is the property that matters.

Run from the repo root:  python3 -m unittest -v tests.test_restic
"""

import os
import subprocess
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(REPO, "plugin", "restic-snapshots", "lib", "restic.luau")

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
]


def shell_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def shell_argv(argv):
    return " ".join(shell_quote(item) for item in argv)


def round_trip(value):
    cmd = "printf %s " + shell_quote(value)
    result = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, check=True)
    return result.stdout.decode()


def config(**overrides):
    base = {
        "restic_bin": "restic",
        "repository": "/tmp/repo",
        "password_file": "/tmp/pass",
        "backup_paths": ["/tmp/data"],
        "backup_tags": ["noctalia"],
        "exclude_file": "",
        "mode": "plugin",
        "interval_minutes": 60,
        "keep_last": 7,
        "keep_daily": 7,
        "keep_weekly": 4,
        "keep_monthly": 6,
        "restore_target": "/tmp/restore",
        "check_subset": "1/100",
    }
    base.update(overrides)
    return base


def base_args(cfg, bin_path="restic"):
    argv = [bin_path]
    if cfg["password_file"]:
        argv += ["--password-file", cfg["password_file"]]
    argv += ["-r", cfg["repository"]]
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


def restore_args(cfg, snapshot, target, includes=None):
    argv = base_args(cfg) + ["restore", snapshot, "--target", target]
    for pattern in includes or []:
        argv += ["--include", pattern]
    return argv + ["--json"]


def human_bytes(value):
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    n = float(value)
    index = 0
    while n >= 1024 and index < len(units) - 1:
        n /= 1024
        index += 1
    return f"{int(n)} {units[index]}" if index == 0 else f"{n:.1f} {units[index]}"


class TestQuoting(unittest.TestCase):
    def test_round_trip_preserves_bytes(self):
        for value in HOSTILE:
            self.assertEqual(round_trip(value), value, "failed for %r" % value)

    def test_argv_round_trip(self):
        argv = ["/tmp/it's here", "--tag", "a b", "$(id)"]
        cmd = "printf '%s\\n' " + shell_argv(argv)
        out = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, check=True).stdout.decode()
        self.assertEqual(out.splitlines(), argv)


class TestArgv(unittest.TestCase):
    def test_password_uses_a_flag_never_a_value(self):
        argv = base_args(config(password_file="/run/secrets/restic"))
        self.assertIn("--password-file", argv)
        self.assertIn("/run/secrets/restic", argv)
        self.assertNotIn("-p", argv)

    def test_no_password_file_omits_the_flag(self):
        self.assertNotIn("--password-file", base_args(config(password_file="")))

    def test_backup_includes_paths_tags_and_json(self):
        argv = backup_args(config(backup_paths=["/home/me/docs", "/etc"], backup_tags=["noctalia", "daily"]))
        self.assertIn("--json", argv)
        self.assertEqual(argv.count("--tag"), 2)
        self.assertIn("/home/me/docs", argv)
        self.assertIn("/etc", argv)

    def test_backup_exclude_file_only_when_set(self):
        self.assertNotIn("--exclude-file", backup_args(config(exclude_file="")))
        self.assertIn("--exclude-file", backup_args(config(exclude_file="/tmp/excludes")))

    def test_policy_requires_at_least_one_rule(self):
        self.assertEqual(policy_args(config(keep_last=0, keep_daily=0, keep_weekly=0, keep_monthly=0)), [])
        self.assertTrue(policy_args(config()))

    def test_forget_dry_run_differs_from_prune(self):
        self.assertIn("--dry-run", forget_args(config(), dry_run=True))
        self.assertNotIn("--dry-run", forget_args(config(), dry_run=False))
        self.assertIn("--prune", forget_args(config(), dry_run=False))

    def test_restore_targets_staging_with_optional_includes(self):
        argv = restore_args(config(), "abc123", "/home/me/restore", ["/home/me/docs/*"])
        self.assertIn("--target", argv)
        self.assertIn("/home/me/restore", argv)
        self.assertEqual(argv.count("--include"), 1)

    def test_hostile_path_stays_a_single_argv_element(self):
        hostile = "/tmp/it's a $(dangerous) path"
        argv = backup_args(config(backup_paths=[hostile]))
        self.assertIn(hostile, argv)
        line = "printf '%s\\n' " + shell_argv(argv)
        out = subprocess.run(["/bin/sh", "-c", line], capture_output=True, check=True).stdout.decode()
        self.assertIn(hostile, out.splitlines())


class TestFormatting(unittest.TestCase):
    def test_human_bytes(self):
        self.assertEqual(human_bytes(0), "0 B")
        self.assertEqual(human_bytes(512), "512 B")
        self.assertEqual(human_bytes(2048), "2.0 KiB")
        self.assertEqual(human_bytes(5 * 1024 * 1024), "5.0 MiB")

    def test_no_shell_strings_in_the_library(self):
        with open(LIB, encoding="utf-8") as handle:
            source = handle.read()
        self.assertNotIn("os.execute", source)
        self.assertNotIn("io.popen", source)
        # Values must travel as argv; the only shell string built is a quoted argv join.
        self.assertIn("M.shellArgv", source)


if __name__ == "__main__":
    unittest.main()
