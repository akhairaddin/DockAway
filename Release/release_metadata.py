"""Offline, standard-library validation shared by DockAway's release scripts."""

import argparse
import base64
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def asset_name(version, archive):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise ValueError("Release version must contain only numbers and dots")
    return f"DockAway-{version}-{digest(archive)}.dmg"


class ChangelogParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sections = {}
        self.heading = None
        self.version = None
        self.depth = 0
        self.lines = []

    def handle_starttag(self, tag, attrs):
        if tag == "h3":
            self.heading = []
            self.version = None
        elif tag == "ul":
            self.depth += 1
        elif tag == "li" and self.version:
            self.lines.append(["  " * max(0, self.depth - 1) + "- ", []])
        elif tag == "br" and self.version and self.lines:
            self.lines[-1][1].append(" ")

    def handle_endtag(self, tag):
        if tag == "h3" and self.heading is not None:
            match = re.match(r"Version\s+([0-9]+(?:\.[0-9]+)*)(?:\s|$)",
                             "".join(self.heading).strip())
            self.heading = None
            if match:
                self.version = match[1]
                if self.version in self.sections:
                    raise ValueError(f"Duplicate changelog version {self.version}")
                self.lines = []
                self.sections[self.version] = self.lines
        elif tag == "ul":
            self.depth -= 1

    def handle_data(self, data):
        if self.heading is not None:
            self.heading.append(data)
        elif self.version and self.depth and self.lines:
            self.lines[-1][1].append(data)


def release_notes(changelog, version):
    parser = ChangelogParser()
    parser.feed(Path(changelog).read_text())
    lines = parser.sections.get(version)
    if not lines:
        raise ValueError(f"No complete changelog section for Version {version}")
    return f"## DockAway {version}\n\n" + "\n".join(
        prefix + " ".join("".join(parts).split()) for prefix, parts in lines
    ) + "\n"


def normalize_feed(feed, version, archive, url, notes_url):
    tree = ET.parse(feed)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("Appcast has no channel")
    items = channel.findall("item")
    matching = [item for item in items
                if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version]
    if len(matching) != 1:
        raise ValueError(f"Expected exactly one appcast item for {version}")
    item = matching[0]
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != url:
        raise ValueError("Release item's download URL does not match the archive")
    if enclosure.get("length") != str(Path(archive).stat().st_size):
        raise ValueError("Release item's size does not match the archive")
    build = item.findtext(f"{{{SPARKLE}}}version", "")
    if not build.isdecimal() or int(build) < 1:
        raise ValueError("Release item needs a positive numeric build number")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Release item needs its own valid Ed25519 signature")
    for older in items:
        if older is item:
            continue
        older_build = older.findtext(f"{{{SPARKLE}}}version", "")
        if older_build.isdecimal() and int(older_build) >= int(build):
            raise ValueError("New release build must exceed all other feed builds")
    for link in item.findall(f"{{{SPARKLE}}}releaseNotesLink"):
        item.remove(link)
    ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = notes_url
    for index, child in reversed(list(enumerate(channel))):
        if child.tag == "item":
            release = child.findtext(f"{{{SPARKLE}}}shortVersionString")
            if not release or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", release):
                raise ValueError("Invalid release version in appcast")
            channel.insert(index, ET.Comment(f" {release} RELEASE "))
    ET.indent(tree, space="    ")
    tree.write(feed, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    name = commands.add_parser("asset-name")
    name.add_argument("version")
    name.add_argument("archive")
    notes = commands.add_parser("notes")
    notes.add_argument("changelog")
    notes.add_argument("version")
    notes.add_argument("output")
    verify = commands.add_parser("verify-archive")
    verify.add_argument("local")
    verify.add_argument("downloaded")
    feed = commands.add_parser("normalize-feed")
    for argument in ("feed", "version", "archive", "url", "notes_url"):
        feed.add_argument(argument)
    args = parser.parse_args()
    if args.command == "asset-name":
        print(asset_name(args.version, args.archive))
    elif args.command == "notes":
        Path(args.output).write_text(release_notes(args.changelog, args.version))
    elif args.command == "verify-archive":
        if digest(args.local) != digest(args.downloaded):
            raise ValueError("Uploaded DMG differs from the local signed archive")
    else:
        normalize_feed(args.feed, args.version, args.archive, args.url, args.notes_url)


if __name__ == "__main__":
    main()
