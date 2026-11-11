"""Installs every catalogue entry the way Pilot's catalogue does (PLAN section 3) into a temporary Pilot-like folder and
proves the result is an extension Pilot reads: files from index.json only, sha256 checked, executables 0755 and the
rest 0644, the folder named by its id."""
import hashlib
import json
import shutil
import stat
import tempfile
import unittest
from pathlib import Path

from harness import EXTENSIONS, ROOT, Sandbox, check


class CatalogueInstallTests(unittest.TestCase):
    def setUp(self):
        self.index = json.loads((ROOT / "index.json").read_text(encoding="utf-8"))
        self.pilot = Path(tempfile.mkdtemp(prefix="pilot-catalogue-"))
        self.addCleanup(shutil.rmtree, self.pilot, True)

    def install(self, entry):
        folder = self.pilot / "Extensions" / entry["id"]
        for f in entry["files"]:
            data = (EXTENSIONS / entry["id"] / f["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), f["sha256"], "%s/%s" % (entry["id"], f["path"]))
            self.assertEqual(len(data), f["size"])
            target = folder / f["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if f["executable"] else 0o644)
        return folder

    def test_index_lists_every_extension_folder(self):
        self.assertEqual(self.index["schema"], 2)
        self.assertEqual([e["id"] for e in self.index["extensions"]], [f.name for f in check.build_index.folders() if check.build_index.listed(f)])

    def test_every_entry_installs_into_a_folder_pilot_reads(self):
        for entry in self.index["extensions"]:
            with self.subTest(entry["id"]):
                folder = self.install(entry)
                self.assertEqual(check.check(folder), [])
                manifest = json.loads((folder / "extension.json").read_text(encoding="utf-8"))
                shown = [c["name"] for c in manifest["commands"] if not c.get("hidden")]
                self.assertEqual([c["name"] for c in entry["commands"]], shown)
                self.assertEqual(entry["version"], manifest["version"])
                for c in manifest["commands"]:
                    self.assertTrue((folder / c["run"]).stat().st_mode & stat.S_IXUSR, c["run"])

    def test_an_installed_program_answers_from_its_new_folder(self):
        """The first list or detail command of each installed extension runs from the temp folder, not the repo."""
        box = Sandbox()
        self.addCleanup(box.close)
        for name, body in (("pbpaste", "echo hello"), ("pbcopy", "cat >/dev/null"), ("open", "exit 0"), ("gh", "exit 1")):
            box.shim(name, body)
        for entry in self.index["extensions"]:
            with self.subTest(entry["id"]):
                folder = self.install(entry)
                manifest = json.loads((folder / "extension.json").read_text(encoding="utf-8"))
                command = next(c for c in manifest["commands"] if c["mode"] in ("list", "detail"))
                result = box.run(entry["id"], command["name"], folder=folder)
                self.assertEqual(result.plain, [])
                self.assertTrue({m["type"] for m in result.messages} & {"list", "detail", "error"}, result.stdout)
