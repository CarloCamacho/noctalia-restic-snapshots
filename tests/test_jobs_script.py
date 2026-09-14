"""Shell-level verification of the job script lib/jobs.luau generates.

tests/lua/jobs_test.lua can only read the script text. This test asks the *real* generator for a
script, writes it to disk and runs it through /bin/sh with a fake `restic`, so the fifo plumbing,
the stdout/stderr split, the recorded pid, the exit-code file and the argument quoting are
exercised by a real shell. That is the only way to prove the generated script actually works.

Skipped when lua5.4 (used to drive the generator through the shared harness) is unavailable.
"""

import glob
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN_DIR = "plugin/restic-snapshots"
LUA = shutil.which("lua5.4") or shutil.which("lua")

# Drives the plugin's own generator through tests/lua/harness.lua and drops the script it writes
# onto the real filesystem (the harness only keeps it in memory). Args: dataDir resticPath
# hostileArg envFile.
GENERATOR_LUA = textwrap.dedent(
    """
    package.path = "tests/lua/?.lua;" .. package.path
    local H = dofile("tests/lua/harness.lua")
    H.install("plugin/restic-snapshots")
    local jobs = H.load("lib/jobs.luau")

    local dataDir, resticPath, hostile, envFile = ...
    _G.noctalia.pluginDataDir = function() return dataDir end

    local argv = {
      resticPath, "--password-file", dataDir .. "/pass", "-r", "ssh://host/repo",
      "backup", hostile, "--json",
    }
    local token, err, paths = jobs.start(argv, {
      pathPrefix = "/usr/bin:/bin",
      envFile = (envFile ~= "" and envFile or nil),
    })
    assert(token ~= nil, tostring(err))

    local text = H.files[paths.script]
    assert(type(text) == "string", "the generator wrote no script")
    local handle = assert(io.open(paths.script, "w"))
    handle:write(text)
    handle:close()
    """
)

# A fake restic: records its own pid, its argv ($0 included), and the fifo's mode, then emits two
# status lines on stdout, one noise line on stderr, an env probe, and a summary line.
FAKE_RESTIC = """#!/bin/sh
printf '%s' "$$" > "$FAKE_PID_FILE"
printf '%s\\n' "$0" "$@" > "$FAKE_ARGV_FILE"
sleep 0.3
for f in "$FAKE_JOBS_DIR"/*.fifo; do
  [ -e "$f" ] || continue
  printf '%s\\n' "$(stat -c %a "$f")" >> "$FAKE_MODE_FILE"
done
printf '%s\\n' '{"message_type":"status","percent_done":0.5,"files_done":5,"total_files":10}'
printf '%s\\n' 'restic: plain noise on stderr' >&2
printf '%s\\n' "env-probe:${FAKE_ENV_MARKER:-unset}"
printf '%s\\n' '{"message_type":"status","percent_done":1.0,"files_done":10,"total_files":10}'
printf '%s\\n' '{"message_type":"summary","total_files_processed":10,"total_bytes_processed":2048,"data_added":512}'
exit "${FAKE_EXIT_CODE:-0}"
"""

STATUS_FIRST = '{"message_type":"status","percent_done":0.5,"files_done":5,"total_files":10}'
STATUS_LAST = '{"message_type":"status","percent_done":1.0,"files_done":10,"total_files":10}'
SUMMARY = '{"message_type":"summary","total_files_processed":10,"total_bytes_processed":2048,"data_added":512}'
NOISE = "restic: plain noise on stderr"
HOSTILE = "/tmp/it's a $(dangerous) `command` path && echo pwned"


def mode_of(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class JobScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if LUA is None:
            raise unittest.SkipTest("lua5.4 is not available to drive the generator")

    def run_job(self, exit_code=0, with_env_file=True):
        """Generate a script with the plugin's generator, run it, return everything it wrote."""
        tmp = tempfile.mkdtemp(prefix="jobs-script-")
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)

        data_dir = os.path.join(tmp, "data")
        jobs_dir = os.path.join(data_dir, "jobs")
        os.makedirs(jobs_dir)
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(bin_dir)

        restic_path = os.path.join(bin_dir, "restic")
        with open(restic_path, "w") as handle:
            handle.write(FAKE_RESTIC)
        os.chmod(restic_path, 0o755)

        # A path with a quote in it, to prove the sourcing line is quoted properly too.
        env_file = os.path.join(tmp, "restic env's file.env")
        with open(env_file, "w") as handle:
            handle.write("FAKE_ENV_MARKER=sourced-value\n")

        driver = os.path.join(tmp, "generate.lua")
        with open(driver, "w") as handle:
            handle.write(GENERATOR_LUA)

        pid_file = os.path.join(tmp, "fake.pid")
        argv_file = os.path.join(tmp, "fake.argv")
        mode_file = os.path.join(tmp, "fake.mode")
        env = dict(os.environ)
        env.update(
            {
                "FAKE_PID_FILE": pid_file,
                "FAKE_ARGV_FILE": argv_file,
                "FAKE_MODE_FILE": mode_file,
                "FAKE_JOBS_DIR": jobs_dir,
                "FAKE_EXIT_CODE": str(exit_code),
            }
        )

        generated = subprocess.run(
            [LUA, driver, data_dir, restic_path, HOSTILE, env_file if with_env_file else ""],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)

        scripts = glob.glob(os.path.join(jobs_dir, "*.sh"))
        self.assertEqual(len(scripts), 1, "expected exactly one generated script")
        script_path = scripts[0]

        # Production launches the script through /bin/sh with the script path as $0.
        run = subprocess.run(["/bin/sh", script_path], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)

        def read(path):
            with open(path, "r") as handle:
                return handle.read()

        def maybe_read(path):
            return read(path) if os.path.exists(path) else None

        log_path = glob.glob(os.path.join(jobs_dir, "*.jsonl"))
        status_path = glob.glob(os.path.join(jobs_dir, "*.status"))
        return {
            "tmp": tmp,
            "script": script_path,
            "script_text": read(script_path),
            "returncode": run.returncode,
            "log": read(log_path[0]) if log_path else "",
            "status": maybe_read(status_path[0]) if status_path else None,
            "status_path": status_path[0] if status_path else None,
            "exit": maybe_read(os.path.join(glob.glob(os.path.join(jobs_dir, "*.exit"))[0]))
            if glob.glob(os.path.join(jobs_dir, "*.exit"))
            else None,
            "pid": maybe_read(os.path.join(glob.glob(os.path.join(jobs_dir, "*.pid"))[0]))
            if glob.glob(os.path.join(jobs_dir, "*.pid"))
            else None,
            "jobs_dir": jobs_dir,
            "fifos_left": glob.glob(os.path.join(jobs_dir, "*.fifo")),
            "fake_pid": maybe_read(pid_file),
            "fake_argv": read(argv_file).splitlines() if os.path.exists(argv_file) else [],
            "fifo_modes": read(mode_file).splitlines() if os.path.exists(mode_file) else [],
            "restic_path": restic_path,
            "data_dir": data_dir,
        }

    def test_shell_run_splits_output_records_restics_pid_and_exit_code(self):
        result = self.run_job(exit_code=7, with_env_file=True)
        log_lines = result["log"].splitlines()

        self.assertEqual(result["returncode"], 0, "the wrapper script itself must exit 0")
        # The split: status lines never reach the log, everything else does.
        self.assertIn(SUMMARY, log_lines)
        self.assertIn(NOISE, log_lines, "stderr must be merged into the log")
        self.assertNotIn(STATUS_FIRST, log_lines)
        self.assertNotIn(STATUS_LAST, log_lines)
        # Overwritten in place: the newest status line, and only that one.
        self.assertEqual(result["status"].strip(), STATUS_LAST)
        self.assertEqual(len(result["status"].strip().splitlines()), 1)

        # The pid file must hold restic's own pid, not a pipeline member's.
        self.assertIsNotNone(result["fake_pid"], "the fake restic never ran")
        self.assertEqual(result["pid"].strip(), result["fake_pid"].strip())

        # The exit code file carries restic's code, not the shell's.
        self.assertEqual(result["exit"].strip(), "7")

        # A hostile argument must survive the round trip byte for byte.
        self.assertEqual(
            result["fake_argv"],
            [
                result["restic_path"],
                "--password-file",
                os.path.join(result["data_dir"], "pass"),
                "-r",
                "ssh://host/repo",
                "backup",
                HOSTILE,
                "--json",
            ],
        )

        # The env file is sourced (its path has a quote in it) and exported to restic.
        self.assertIn("env-probe:sourced-value", log_lines)

        # Mode 0600 on the script and everything it writes.
        self.assertEqual(mode_of(result["script"]), 0o600)
        for name, path in (("log", glob.glob(os.path.join(result["jobs_dir"], "*.jsonl"))[0]),
                           ("status", result["status_path"]),
                           ("exit", glob.glob(os.path.join(result["jobs_dir"], "*.exit"))[0]),
                           ("pid", glob.glob(os.path.join(result["jobs_dir"], "*.pid"))[0])):
            self.assertEqual(mode_of(path), 0o600, "%s must be 0600" % name)
        self.assertTrue(result["fifo_modes"], "the fake restic never saw the fifo")
        self.assertEqual(result["fifo_modes"][0].strip(), "600")

        # The fifo is cleaned up when the job ends.
        self.assertEqual(result["fifos_left"], [])

        # The script text proves how the shell was meant to run restic.
        self.assertIn('> "$fifo" 2>&1 &', result["script_text"])
        self.assertIn('chmod 600 "$0"', result["script_text"])
        self.assertIn("umask 077", result["script_text"])

    def test_shell_run_without_env_file_never_sources_one(self):
        result = self.run_job(exit_code=0, with_env_file=False)
        log_lines = result["log"].splitlines()

        self.assertNotIn("set -a", result["script_text"])
        self.assertIn("env-probe:unset", log_lines)
        self.assertIn(SUMMARY, log_lines)
        self.assertEqual(result["status"].strip(), STATUS_LAST)
        self.assertEqual(result["pid"].strip(), result["fake_pid"].strip())
        self.assertEqual(result["exit"].strip(), "0")


if __name__ == "__main__":
    unittest.main()
