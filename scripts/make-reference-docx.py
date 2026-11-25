#!/usr/bin/env python3 -I
"""Builds ZadurCore/Sources/ZadurCore/Resources/reference.docx from Pandoc's default reference.

Adds a centred "Szenenwechsel" paragraph style and sets a readable body: Times New Roman 12 pt,
1.5 line spacing (room for handwritten notes), first-line indent instead of paragraph gaps.
"""
import re, subprocess, sys, zipfile, io, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
target = root / "ZadurCore/Sources/ZadurCore/Resources/reference.docx"
default = subprocess.run(["pandoc", "--print-default-data-file", "reference.docx"],
                         capture_output=True, check=True).stdout

source = zipfile.ZipFile(io.BytesIO(default))
styles = source.read("word/styles.xml").decode("utf-8")

# Body font and size for the whole document.
styles = re.sub(r"<w:rFonts [^>]*/>", '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="Times New Roman" w:cs="Times New Roman"/>', styles, count=1)
styles = re.sub(r'<w:sz w:val="\d+"\s*/>', '<w:sz w:val="24"/>', styles, count=1)

def restyle(style_id, ppr):
    global styles
    pattern = re.compile(r'(<w:style [^>]*w:styleId="%s"[^>]*>)(.*?)(</w:style>)' % style_id, re.S)
    def fix(m):
        body = re.sub(r"<w:pPr>.*?</w:pPr>|<w:pPr/>", "", m.group(2), flags=re.S)
        body = re.sub(r"(<w:qFormat/>|<w:basedOn [^>]*/>|<w:name [^>]*/>)(?!.*(<w:qFormat/>|<w:basedOn|<w:name))", r"\1" + ppr, body, count=1, flags=re.S)
        return m.group(1) + body + m.group(3)
    styles, n = pattern.subn(fix, styles)
    if n == 0:
        print(f"warning: style {style_id} not found", file=sys.stderr)

# Body text: 1.5 lines, indent, no gap. First paragraph: no indent.
restyle("BodyText", '<w:pPr><w:spacing w:before="0" w:after="0" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="567"/></w:pPr>')
restyle("FirstParagraph", '<w:pPr><w:spacing w:before="0" w:after="0" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr>')

scene_break = (
    '<w:style w:type="paragraph" w:customStyle="1" w:styleId="Szenenwechsel">'
    '<w:name w:val="Szenenwechsel"/><w:basedOn w:val="BodyText"/><w:next w:val="FirstParagraph"/><w:qFormat/>'
    '<w:pPr><w:spacing w:before="240" w:after="240" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr>'
    '</w:style>'
)
styles = styles.replace("</w:styles>", scene_break + "</w:styles>")

out = io.BytesIO()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in source.infolist():
        data = styles.encode("utf-8") if item.filename == "word/styles.xml" else source.read(item.filename)
        zout.writestr(item, data)
target.write_bytes(out.getvalue())
print(f"wrote {target.relative_to(root)} ({len(out.getvalue())} bytes)")
