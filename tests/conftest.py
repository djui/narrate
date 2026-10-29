import zipfile
from pathlib import Path

import pytest

OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">test-book</dc:identifier>
    <dc:title>The Test Voyage</dc:title>
    <dc:creator id="a1">Ann Author</dc:creator>
    <dc:creator id="a2">Ivy Illustrator</dc:creator>
    <meta refines="#a2" property="role">ill</meta>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="copy" href="text/copyright.xhtml" media-type="application/xhtml+xml"/>
    <item id="body" href="text/body.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
  </manifest>
  <spine>
    <itemref idref="copy"/>
    <itemref idref="body"/>
    <itemref idref="notes"/>
  </spine>
</package>"""

NAV = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><ol>
  <li><a href="text/copyright.xhtml">Copyright</a></li>
  <li><a href="text/body.xhtml#part1">PART ONE—The Harbour</a></li>
  <li><a href="text/body.xhtml#ch1">I The Old Captain</a></li>
  <li><a href="text/body.xhtml#ch2">II A Black Spot</a></li>
  <li><a href="text/notes.xhtml">Notes</a></li>
</ol></nav></body></html>"""

COPYRIGHT = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body epub:type="frontmatter copyright-page"><p>Copyright 2026 Ann Author. All rights reserved.</p></body></html>"""

# Two chapters in one file, split by TOC anchors; a figure, a poem, a scene break and a footnote.
BODY = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
<h1 id="part1">PART ONE—The Harbour</h1>
<div class="fig"><img src="../images/cover.jpg" alt="ship"/><p class="caption">The ship at anchor</p></div>
<h2 id="ch1">I<br/>The Old Captain</h2>
<p>Dr. Livesey came late one
afternoon.<a epub:type="noteref" href="notes.xhtml#n1">1</a> He looked at the captain.</p>
<p class="poem">Fifteen men on the dead man's chest—<br/>Yo-ho-ho, and a bottle of rum!</p>
<hr/>
<p>Next morning the fog had lifted.</p>
<h2 id="ch2">II<br/>A Black Spot</h2>
<p><span epub:type="pagebreak" id="p12">12</span>It was in the year of grace 17—, a cold winter.</p>
</body></html>"""

NOTES = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
<section epub:type="endnotes"><aside epub:type="footnote" id="n1"><p>1. Livesey is said “LIV-see”.</p></aside></section>
</body></html>"""


@pytest.fixture
def epub_path(tmp_path: Path) -> Path:
    path = tmp_path / "test-voyage.epub"
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        )
        z.writestr("OEBPS/content.opf", OPF)
        z.writestr("OEBPS/nav.xhtml", NAV)
        z.writestr("OEBPS/text/copyright.xhtml", COPYRIGHT)
        z.writestr("OEBPS/text/body.xhtml", BODY)
        z.writestr("OEBPS/text/notes.xhtml", NOTES)
        z.writestr("OEBPS/images/cover.jpg", b"\xff\xd8\xff\xe0fakejpeg")
    return path
