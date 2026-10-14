#!/usr/bin/env python3
# update_appcast.py — Prepend a new release entry to appcast.xml
#
# Usage:
#   python3 Scripts/update_appcast.py <appcast.xml> <version> <sparkle_version> \
#       <pub_date> <ed_sig> <length> [notes.md]
#
# Arguments:
#   appcast.xml      Path to the appcast file to update
#   version          Marketing version string (e.g. 1.0.7)
#   sparkle_version  Integer build counter (e.g. 7)
#   pub_date         RFC 2822 UTC date string (e.g. "Thu, 18 Apr 2026 12:00:00 +0000")
#   ed_sig           EdDSA signature from sign_update
#   length           Byte size of the DMG
#   notes.md         Optional — path to markdown file for release notes
#                    If omitted, a placeholder is inserted.

import sys
import re


def markdown_to_html(path):
    with open(path) as f:
        lines = f.read().splitlines()

    out = []
    in_ul = False
    for line in lines:
        if line.startswith('## '):
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<h3>{line[3:].strip()}</h3>')
        elif re.match(r'^[-*] ', line):
            if not in_ul:
                out.append('<ul>')
                in_ul = True
            item = line[2:].strip()
            item = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', item)
            out.append(f'<li>{item}</li>')
        elif line.strip():
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<p>{line.strip()}</p>')

    if in_ul:
        out.append('</ul>')
    return '\n        '.join(out)


def main():
    if len(sys.argv) < 7:
        print(
            'Usage: update_appcast.py <appcast.xml> <version> <sparkle_version> '
            '<pub_date> <ed_sig> <length> [notes.md]',
            file=sys.stderr,
        )
        sys.exit(1)

    appcast_path = sys.argv[1]
    version = sys.argv[2]
    sparkle_version = sys.argv[3]
    pub_date = sys.argv[4]
    ed_sig = sys.argv[5]
    length = sys.argv[6]
    notes_file = sys.argv[7] if len(sys.argv) >= 8 else None

    if notes_file:
        notes_html = markdown_to_html(notes_file)
    else:
        notes_html = '<p>TODO: add release notes before publishing.</p>'

    new_item = f"""    <item>
      <title>OpenEmu-Silicon {version}</title>
      <description>
        <![CDATA[
        <h2>OpenEmu-Silicon {version}</h2>
        {notes_html}
        ]]>
      </description>
      <pubDate>{pub_date}</pubDate>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/download/v{version}/OpenEmu-Silicon.dmg"
        sparkle:version="{sparkle_version}"
        sparkle:shortVersionString="{version}"
        sparkle:edSignature="{ed_sig}"
        length="{length}"
        type="application/octet-stream"/>
    </item>"""

    with open(appcast_path, 'r') as f:
        content = f.read()

    insert_after = re.search(r'(<language>[^<]*</language>\s*)', content)
    if not insert_after:
        print('ERROR: could not find insertion point in appcast.xml', file=sys.stderr)
        sys.exit(1)

    pos = insert_after.end()
    content = content[:pos] + new_item + '\n' + content[pos:]

    with open(appcast_path, 'w') as f:
        f.write(content)

    print(f'Prepended v{version} entry (sparkle:version={sparkle_version}) to {appcast_path}')


if __name__ == '__main__':
    main()
