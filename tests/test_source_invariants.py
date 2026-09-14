"""Source-level invariants of the plugin that only the real host or the real icon set can violate.

Both checks here exist because live testing found defects that a plain-Lua test cannot see — the
stub harness has no VM instruction budget and accepts any glyph name:

1. **No per-character string walk.** The host runs plugin callbacks under a per-callback CPU
   budget. A `while` loop calling `text:sub(i, i)` once per character blew that budget on a ~97 KB
   `ls --json` job log, and because the log is published from the service's `update()` tick the
   entire tick died with ``script callback 'update' exceeded its CPU budget``. Work inside a
   callback must scale with lines or records, never with bytes walked one at a time.

2. **Glyph names must exist in the host's icon set** (Tabler). A name that is not there renders as
   nothing and the host logs ``[glyph] missing glyph: <name>``. The check runs when a noctalia
   checkout (or an installed asset dir) is available and skips otherwise, so it protects the dev
   box without breaking a checkout that has no font file.

Run from the repo root:  python3 -m unittest -v tests.test_source_invariants
"""

import json
import os
import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = REPO / "plugin" / "restic-snapshots"

# ui.glyph({ name = "x" }), glyph = "x", shortcut.setIcon("on", "off")
GLYPH_PATTERNS = [
    re.compile(r'ui\.glyph\(\{[^}]*?name\s*=\s*"([^"]+)"', re.S),
    re.compile(r'glyph\s*=\s*"([^"]+)"'),
    re.compile(r'setIcon\(\s*"([^"]+)"\s*(?:,\s*"([^"]+)")?'),
]

PER_CHARACTER_WALK = re.compile(r":sub\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")


def lua_sources():
    return sorted(PLUGIN.rglob("*.luau"))


def used_glyphs():
    found = {}
    for path in lua_sources():
        text = path.read_text(encoding="utf-8")
        for pattern in GLYPH_PATTERNS:
            for match in pattern.finditer(text):
                for group in match.groups():
                    if group:
                        found.setdefault(group, set()).add(path.name)
    return found


def icon_set_path():
    candidates = []
    override = os.environ.get("NOCTALIA_TABLER_JSON")
    if override:
        candidates.append(pathlib.Path(override))
    candidates.append(pathlib.Path.home() / "work/noctalia-upstream/assets/fonts/tabler.json")
    candidates.append(pathlib.Path("/usr/share/noctalia/assets/fonts/tabler.json"))
    candidates.extend(sorted((pathlib.Path.home() / "work").glob("*/assets/fonts/tabler.json")))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


class TestCallbackCost(unittest.TestCase):
    def test_no_per_character_string_walk(self):
        """A sub(x, x) call in a loop walks bytes one at a time and can blow the CPU budget."""
        offenders = []
        for path in lua_sources():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                match = PER_CHARACTER_WALK.search(line)
                if match and match.group(1) == match.group(2):
                    offenders.append(f"{path.relative_to(REPO)}:{number}: {line.strip()}")
        self.assertEqual(
            offenders, [],
            "per-character string walk (scales with bytes, can exceed the host CPU budget in a "
            "callback; use one pass over lines/records instead):\n  " + "\n  ".join(offenders),
        )

    def test_log_tail_is_bounded_and_linear(self):
        """jobs.readLog must bound by lines without scanning the whole tail per character."""
        source = (PLUGIN / "lib/jobs.luau").read_text(encoding="utf-8")
        self.assertIn("function M.readLog", source)
        self.assertNotIn("body:sub(index, index)", source)
        # The one-shot find of the newline is what keeps it linear.
        self.assertIn('text:find("\\n", from, true)', source)


class TestGlyphNames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.font = icon_set_path()
        if cls.font is not None:
            data = json.loads(cls.font.read_text(encoding="utf-8"))
            cls.names = set(data if isinstance(data, list) else data.keys())

    @unittest.skipUnless(icon_set_path() is not None, "no noctalia icon set available")
    def test_every_used_glyph_exists_in_the_icon_set(self):
        missing = {name: sorted(where) for name, where in used_glyphs().items() if name not in self.names}
        self.assertEqual(
            missing, {},
            f"glyph names not in {self.font} (the host logs 'missing glyph' and renders nothing): "
            f"{missing}",
        )

    def test_glyph_inventory_is_not_empty(self):
        """Guards the extractor itself: a regex that matches nothing would make the check vacuous."""
        self.assertGreaterEqual(len(used_glyphs()), 8, "glyph extraction found suspiciously few names")


if __name__ == "__main__":
    unittest.main()
