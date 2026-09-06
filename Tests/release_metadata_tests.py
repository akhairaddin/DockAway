import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "Release/release_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "test.dmg"
        self.archive.write_bytes(b"test archive bytes")
        self.feed = self.root / "appcast.xml"
        self.url = "https://example.com/" + metadata.asset_name("1.2", self.archive)
        self.notes = "https://example.com/changelog.html"
        self.signature = base64.b64encode(bytes(64)).decode()

    def item(self, version="1.2", build="12", signature=None, size=None, url=None):
        signature = self.signature if signature is None else signature
        size = self.archive.stat().st_size if size is None else size
        return f'''<item><title>{version}</title>
        <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
        <sparkle:version>{build}</sparkle:version>
        <enclosure url="{url or self.url}" length="{size}" sparkle:edSignature="{signature}" />
        </item>'''

    def write_feed(self, *items):
        self.feed.write_text(f'<rss xmlns:sparkle="{metadata.SPARKLE}"><channel>'
                             + "".join(items) + '</channel></rss>')

    def normalize(self):
        metadata.normalize_feed(self.feed, "1.2", self.archive, self.url, self.notes)

    def test_asset_name_follows_version_convention(self):
        before = metadata.asset_name("1.2", self.archive)
        self.assertEqual(before, "DockAway-1.2.dmg")
        self.archive.write_bytes(b"new bytes")
        self.assertEqual(before, metadata.asset_name("1.2", self.archive))

    def test_complete_changelog_and_exact_version(self):
        notes = metadata.release_notes(ROOT / "changelog.html", "1.2")
        self.assertIn("A Proper DockAway Welcome", notes)
        self.assertIn("Updated Documentation", notes)
        self.assertNotIn("Introducing Dock Settings", notes)
        with self.assertRaises(ValueError):
            metadata.release_notes(ROOT / "changelog.html", "99.9")

    def test_nested_changelog(self):
        notes = metadata.release_notes(ROOT / "changelog.html", "1.1.9")
        self.assertIn("  - Dock Position:", notes)
        self.assertIn("Updated Menu Preview", notes)

    def test_github_heading_uses_html_date_without_changing_html(self):
        changelog = ROOT / "changelog.html"
        before = changelog.read_bytes()
        notes = metadata.release_notes(changelog, "1.2")
        self.assertTrue(notes.startswith("## What's New: Version 1.2 (9-4-26)\n"))
        self.assertEqual(before, changelog.read_bytes())

    def test_missing_heading_date_is_rejected(self):
        changelog = self.root / "changelog.html"
        changelog.write_text('<h3>Version 1.2</h3><ul><li>Details</li></ul>')
        with self.assertRaisesRegex(ValueError, "Missing changelog date"):
            metadata.release_notes(changelog, "1.2")

    def test_valid_item_and_idempotent_markers(self):
        self.write_feed(self.item(), self.item("1.1.9", "11"))
        self.normalize()
        first = self.feed.read_bytes()
        self.normalize()
        self.assertEqual(first, self.feed.read_bytes())
        self.assertIn("<!-- 1.2 RELEASE -->", first.decode())
        root = ET.parse(self.feed).getroot()
        self.assertEqual(root.findtext(f"channel/item/{{{metadata.SPARKLE}}}releaseNotesLink"), self.notes)

    def test_old_signature_cannot_mask_missing_new_signature(self):
        self.write_feed(self.item(signature=""), self.item("1.1.9", "11"))
        with self.assertRaises(ValueError):
            self.normalize()

    def test_wrong_size_or_url(self):
        for changes in ({"size": 1}, {"url": "https://wrong.example/test.dmg"}):
            self.write_feed(self.item(**changes))
            with self.assertRaises(ValueError):
                self.normalize()

    def test_invalid_build(self):
        for build in ("", "0", "not-a-build"):
            self.write_feed(self.item(build=build))
            with self.assertRaises(ValueError):
                self.normalize()

    def test_duplicate_version_or_build_rollback(self):
        for other in (self.item(), self.item("1.1.9", "12")):
            self.write_feed(self.item(), other)
            with self.assertRaises(ValueError):
                self.normalize()


if __name__ == "__main__":
    unittest.main()
