"""One runnable check: planted failures fail, clean prose and product mentions pass."""

import subprocess
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).with_name("wording-gate.py")


def run(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=True)


class WordingGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        run(self.repo, "init", "-q", "-b", "main")
        run(self.repo, "config", "user.email", "t@example.com")
        run(self.repo, "config", "user.name", "t")
        (self.repo / "README.md").write_text("# tool\n\nDoes one thing.\n")
        run(self.repo, "add", "-A")
        run(self.repo, "commit", "-qm", "base")
        run(self.repo, "checkout", "-qb", "topic")

    def tearDown(self):
        self.tmp.cleanup()

    def gate(self, files):
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        run(self.repo, "add", "-A")
        run(self.repo, "commit", "-qm", "change")
        done = subprocess.run(
            ["python3", str(GATE), "--base", "main"], cwd=self.repo, capture_output=True, text=True
        )
        return done.returncode, done.stdout

    def test_clean_change_passes(self):
        self.assertEqual(self.gate({"docs/guide.md": "Run it, then read the log.\n"})[0], 0)

    def test_product_that_works_with_a_model_passes(self):
        self.assertEqual(self.gate({"docs/uses.md": "Works with Claude and other models.\n"})[0], 0)

    def test_em_dash_in_readme_fails(self):
        code, out = self.gate({"README.md": "# tool\n\nDoes one thing \u2014 well.\n"})
        self.assertEqual(code, 1)
        self.assertIn("landing page", out)

    def test_method_statement_fails(self):
        self.assertEqual(self.gate({"docs/a.md": "This diagram was generated with AI.\n"})[0], 1)

    def test_generator_line_fails(self):
        self.assertEqual(self.gate({"notes/b.md": "Generator: some model\n"})[0], 1)

    def test_waiver_and_spec_records_pass(self):
        files = {"specs/1/x.md": "a \u2014 b\n", "docs/c.md": "generated with ruff <!-- wording-gate: allow -->\n"}
        self.assertEqual(self.gate(files)[0], 0)


if __name__ == "__main__":
    unittest.main()
