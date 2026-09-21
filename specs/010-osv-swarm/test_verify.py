#!/usr/bin/env python3
"""Offline regression: repository evidence never lands in the public coordinator."""
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch


class EvidenceOwnership(unittest.TestCase):
    def test_repository_owns_its_scan_evidence(self):
        namespace = runpy.run_path(str(Path(__file__).with_name("verify.py")))
        verify_repo = namespace["verify_repo"]
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "private-repo-091-osv-swarm"
            workflow = repo / ".github/workflows/osv-scanner.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                f"uses: upstream@{namespace['ACTION']} # v2.6.0\n"
                "      scan-args: |-\n"
                "        --recursive\n"
                "        --allow-no-lockfiles\n"
                "        ./\n"
            )
            scanner = Mock()
            with patch.dict(verify_repo.__globals__, scan=scanner):
                verify_repo(repo)
            scanner.assert_called_once_with(
                repo, ["--recursive", "--allow-no-lockfiles", "./"],
                "private-repo-verified", 0,
                evidence=repo / "docs/evidence/osv-2026-09-21",
            )


if __name__ == "__main__":
    unittest.main()
