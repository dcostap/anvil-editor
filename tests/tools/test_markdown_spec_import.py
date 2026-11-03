"""Check the reference-HTML conversion without parsing Markdown or using the network."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import import_markdown_spec as importer


def example(number, markdown, html):
    return {"example": number, "section": "Code spans", "markdown": markdown, "html": html}


class MarkdownSpecImportTests(unittest.TestCase):
    def test_text_and_composed_styles_come_from_reference_html(self):
        raw = json.dumps([example(1, "not parsed\n",
            '<p>a<strong>b<em>&lt;&amp;</em>c</strong>d<code>&lt;em&gt;</code></p>\n')]).encode()
        self.assertEqual(importer.convert(raw)["cases"][0]["runs"], [
            {"text": "a", "style": "normal"},
            {"text": "b", "style": "strong"},
            {"text": "<&", "style": "strong_emphasis"},
            {"text": "c", "style": "strong"},
            {"text": "d", "style": "normal"},
            {"text": "<em>", "style": "code"},
        ])

    def test_equivalent_nesting_has_the_same_visible_style(self):
        raw = json.dumps([
            example(1, "one\n", "<p><em><strong>x</strong></em></p>\n"),
            example(2, "two\n", "<p><strong><em>x</em></strong></p>\n"),
            example(3, "three\n", "<p><em><em>x</em></em></p>\n"),
        ]).encode()
        cases = importer.convert(raw)["cases"]
        self.assertEqual(cases[0]["runs"], [{"text": "x", "style": "strong_emphasis"}])
        self.assertEqual(cases[1]["runs"], cases[0]["runs"])
        self.assertEqual(cases[2]["runs"], [{"text": "x", "style": "emphasis"}])

    def test_scope_exclusions_do_not_depend_on_anvil_output(self):
        raw = json.dumps([
            example(1, "one\ntwo\n", "<p>one\ntwo</p>\n"),
            example(2, "[link](url)\n", '<p><a href="url">link</a></p>\n'),
            example(3, "plain\n", "<p>plain</p>\n"),
        ]).encode()
        result = importer.convert(raw)
        self.assertEqual([case["example"] for case in result["cases"]], [3])
        self.assertEqual(result["excluded"], {"multiline source": 1, "other HTML elements": 1})


if __name__ == "__main__":
    unittest.main()
