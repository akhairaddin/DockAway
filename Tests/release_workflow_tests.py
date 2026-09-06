"""Exercise the real post-publish script with offline stand-ins for GitHub/Sparkle."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Release").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("update-appcast.sh", "release_metadata.py"):
            shutil.copyfile(ROOT / "Release" / name, self.root / "Release" / name)
        (self.root / "changelog.html").write_text('<h3>Version 1.2 (9-4-26)</h3><ul><li>Everything changed.</li></ul>')
        (self.root / "appcast.xml").write_text('<rss><channel /></rss>')
        self.archive = self.root / "input.dmg"
        self.archive.write_bytes(b"archive")
        self.log = self.root / "commands.log"
        self.env = dict(os.environ, RILMAZAFONE_REPO_ROOT=str(self.root),
                        RILMAZAFONE_VERSION="1.2", RILMAZAFONE_DMG=str(self.archive),
                        SPARKLE_GENERATE_APPCAST=str(self.bin / "generate_appcast"),
                        TEST_LOG=str(self.log), PATH=str(self.bin) + ":" + os.environ["PATH"])
        self.executable("generate_appcast", '''#!/usr/bin/env python3
import base64, pathlib, sys
stage = pathlib.Path(sys.argv[-1])
archive = next(stage.glob('*.dmg'))
url = sys.argv[sys.argv.index('--download-url-prefix') + 1] + archive.name
sig = base64.b64encode(bytes(64)).decode()
(stage / 'appcast.xml').write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>1.2</title><sparkle:shortVersionString>1.2</sparkle:shortVersionString><sparkle:version>12</sparkle:version><enclosure url="{url}" length="{archive.stat().st_size}" sparkle:edSignature="{sig}" /></item></channel></rss>')
''')
        self.executable("git", '''#!/bin/zsh
print -r -- "git $*" >> "$TEST_LOG"
if [[ "$1" == remote ]]; then print 'https://github.com/akhairaddin/DockAway.git'; fi
if [[ "$1" == diff ]]; then exit 1; fi
''')
        self.executable("gh", '''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ['TEST_LOG'], 'a') as log: log.write('gh ' + ' '.join(sys.argv[1:]) + '\\n')
args = sys.argv
target = pathlib.Path(args[args.index('--dir') + 1]) / args[args.index('--pattern') + 1]
target.write_bytes(b'wrong bytes' if os.environ.get('TEST_CORRUPT') else pathlib.Path(os.environ['RILMAZAFONE_DMG']).read_bytes())
''')

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, **extra):
        return subprocess.run(['/bin/zsh', str(self.root / 'Release/update-appcast.sh')],
                              env=dict(self.env, **extra), capture_output=True, text=True)

    def test_preflight_never_calls_git_or_github(self):
        result = self.run_script(DOCKAWAY_PREPARE_ONLY="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())
        self.assertEqual((self.root / "appcast.xml").read_text(), '<rss><channel /></rss>')

    def test_mismatched_download_never_publishes(self):
        result = self.run_script(TEST_CORRUPT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("git ", self.log.read_text())
        self.assertEqual((self.root / "appcast.xml").read_text(), '<rss><channel /></rss>')

    def test_matching_download_can_publish(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("git push", self.log.read_text())
        self.assertIn("<!-- 1.2 RELEASE -->", (self.root / "appcast.xml").read_text())

    def test_missing_changelog_stops_preflight(self):
        (self.root / "changelog.html").write_text('<h3>Version 1.1.9</h3><ul><li>Old</li></ul>')
        result = self.run_script(DOCKAWAY_PREPARE_ONLY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
