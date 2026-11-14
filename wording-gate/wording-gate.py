#!/usr/bin/env python3
"""wording-gate: public prose says nothing about how it was made, and has no em dash.

Checks (stdlib only, no network):
  1. every tracked README*.md and docs/README.md|index.md: no em dash (whole file);
  2. lines ADDED vs --base in other prose files (md, rst, txt): no em dash, except
     under specs/ and in CHANGELOG*, which are working records;
  3. lines ADDED vs --base in any prose file: no method statement, i.e. a sentence
     saying our own text, image or code was produced by an AI or a named model.

A product that works with a model may still say so ("works with Claude" is not a
method statement). A line carrying `wording-gate: allow` is skipped.

Exit: 0 clean, 1 violations, 2 usage/tooling error.
"""

import argparse
import re
import subprocess
import sys

EM_DASH = "\u2014"
WAIVER = "wording-gate: allow"
PROSE = (".md", ".rst", ".txt")
WORKING_RECORDS = re.compile(r"(^|/)(specs/|CHANGELOG)", re.IGNORECASE)
LANDING = re.compile(r"(^|/)README[^/]*\.md$|^docs/(README|index)\.md$", re.IGNORECASE)

METHOD_PATTERNS = (
    (re.compile(r"\b(?:ai|gpt|llm|model|machine)[- ]generated\b", re.IGNORECASE), "generated-by statement"),
    (re.compile(r"\bgenerated (?:with|by|using)\b", re.IGNORECASE), "generated-by statement"),
    (
        re.compile(
            r"\b(?:made|created|drawn|produced|illustrated|designed|painted|rendered|written|authored)"
            r" (?:with|by|using) (?:an? )?(?:ai|gpt|chatgpt|openai|claude|dall-?e|midjourney"
            r"|stable diffusion|llm|generative|image model)\b",
            re.IGNORECASE,
        ),
        "made-with statement",
    ),
    (re.compile(r"^\W*generator(?: family)?\s*:", re.IGNORECASE), "Generator: line"),
    (re.compile(r"^\W*co-authored-by:.*\b(?:claude|gpt|codex|copilot)\b", re.IGNORECASE), "AI co-author trailer"),
)


def git(*args):
    out = subprocess.run(["git", *args], capture_output=True, text=True)
    if out.returncode:
        print(f"wording-gate: git {' '.join(args)}: {out.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return out.stdout


def added_lines(base):
    """Yield (path, line_number, text) for every line added vs the merge base."""
    diff = git("diff", "--unified=0", "--no-color", "--diff-filter=AM", f"{base}...HEAD")
    path, number = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("@@"):
            number = int(re.search(r"\+(\d+)", line).group(1)) - 1
        elif line.startswith("+") and not line.startswith("+++"):
            number += 1
            yield path, number, line[1:]


def check(base):
    found = []
    for path in git("ls-files").splitlines():
        if LANDING.search(path):
            for n, text in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                if EM_DASH in text and WAIVER not in text:
                    found.append((path, n, "em dash in a landing page"))
    for path, n, text in added_lines(base):
        if not path.lower().endswith(PROSE) or WAIVER in text:
            continue
        if EM_DASH in text and not LANDING.search(path) and not WORKING_RECORDS.search(path):
            found.append((path, n, "em dash in added prose"))
        for pattern, label in METHOD_PATTERNS:
            if pattern.search(text):
                found.append((path, n, label))
                break
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    git("rev-parse", "--verify", args.base)
    found = check(args.base)
    for path, n, label in found:
        print(f"::error file={path},line={n}::wording-gate: {label}")
    print(f"wording-gate: {len(found)} violation(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
