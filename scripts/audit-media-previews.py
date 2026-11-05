#!/usr/bin/env python3
"""Regression checks for Quick Look CSV and malformed ODS inputs.

Usage: python3 scripts/audit-media-previews.py [path/to/ql42render]
"""
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZipFile


class Table(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag == "td":
            self.cell = ""

    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data

    def handle_endtag(self, tag):
        if tag == "td":
            self.row.append(self.cell)
            self.cell = None
        elif tag == "tr" and self.row:
            self.rows.append(self.row)


ROOT = Path(__file__).resolve().parents[1]
EXE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build/debug/ql42render"
PREFIX = '''<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0">'''


with tempfile.TemporaryDirectory(prefix="suite42-preview-regression-") as tmp:
    folder = Path(tmp)

    def render(name, content, ods=False, styles=""):
        source = folder / name
        if ods:
            xml = PREFIX + styles + '<office:body><office:spreadsheet><table:table table:name="Test">' + content
            xml += '</table:table></office:spreadsheet></office:body></office:document-content>'
            with ZipFile(source, "w") as archive:
                archive.writestr("content.xml", xml)
        else:
            source.write_text(content)
        target = folder / (name + ".html")
        result = subprocess.run([str(EXE), "html", str(source), str(target)], capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, (name, result.returncode, result.stderr)
        html = target.read_text()
        table = Table()
        table.feed(html)
        return table.rows, html

    rows, _ = render("quoted.csv", 'name,comment\nAlice,"one;two;three;four"\n')
    assert rows == [["name", "comment"], ["Alice", "one;two;three;four"]], rows
    rows, _ = render("escaped.csv", 'name,comment\nAlice,"one;""two"";three;four"\n')
    assert rows == [["name", "comment"], ["Alice", 'one;"two";three;four']], rows
    rows, _ = render("empty.csv", '""')
    assert rows == [[""]], rows
    rows, _ = render("semicolon.csv", 'name;comment\nAlice;"one,two,three,four"\n')
    assert rows == [["name", "comment"], ["Alice", "one,two,three,four"]], rows

    cell = '<table:table-cell><text:p>test</text:p></table:table-cell>'
    for attribute in ["number-rows-repeated", "number-columns-repeated"]:
        tag = "table-row" if attribute == "number-rows-repeated" else "table-cell"
        content = cell if tag == "table-row" else "<text:p>test</text:p>"
        part = f'<table:{tag} table:{attribute}="-1">{content}</table:{tag}>'
        if tag == "table-cell":
            part = "<table:table-row>" + part + "</table:table-row>"
        rows, _ = render(attribute + ".ods", part, ods=True)
        assert rows == [["test"]], rows

    rows, _ = render("negative-spaces.ods", '<table:table-row><table:table-cell><text:p>a<text:s text:c="-1"/>b</text:p></table:table-cell></table:table-row>', ods=True)
    assert rows == [["a b"]], rows
    rows, html = render("large-repeat.ods", '<table:table-row table:number-rows-repeated="9223372036854775807">' + cell + '</table:table-row>', ods=True)
    assert len(rows) == 2000 and 'class="note"' in html, len(rows)
    rows, html = render("huge-span.ods", '<table:table-row><table:table-cell table:number-columns-spanned="9223372036854775807"><text:p>test</text:p></table:table-cell></table:table-row>', ods=True)
    assert 'colspan="200"' in html
    styles = '<office:automatic-styles><style:style style:name="wide" style:family="table-column"><style:table-column-properties style:column-width="infpt"/></style:style></office:automatic-styles>'
    rows, _ = render("infinite-width.ods", '<table:table-column table:style-name="wide"/><table:table-row>' + cell + '</table:table-row>', ods=True, styles=styles)
    assert rows == [["test"]], rows

print("PASS: 10 Quick Look CSV/ODS regression cases")
