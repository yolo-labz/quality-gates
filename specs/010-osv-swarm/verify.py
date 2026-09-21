#!/usr/bin/env python3
"""Run the actual pinned scanner against caller arguments and synthetic regressions.

Usage: python3 specs/010-osv-swarm/verify.py REPO [REPO ...]
Requires Docker and network access to OSV; any scanner/network error fails closed.
Evidence is retained under docs/evidence/osv-2026-09-21, never a temp directory.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "docs/evidence/osv-2026-09-21"
IMAGE = "ghcr.io/google/osv-scanner-action@sha256:71ad04ab2f8798be47870f9b18817ad317c2f8f2f97aa6726ba10d5578bc174a"
ACTION = "a345acffa64b0eaede81a3d9aae6141214d9c8fc"


def scan(source, args, label, expected):
    output = EVIDENCE / (label + ".json")
    if output.exists():
        output.unlink()  # This invocation must produce fresh evidence.
    command = [
        "docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
        "-v", f"{source}:/github/workspace:ro", "-v", f"{EVIDENCE}:/evidence",
        "-w", "/github/workspace", "--entrypoint", "osv-scanner", IMAGE,
        "scan", "source", "--format=json", f"--output-file=/evidence/{output.name}", *args,
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (EVIDENCE / (label + ".log")).write_text(result.stdout + result.stderr)
    assert result.returncode == expected, (label, result.returncode, result.stderr)
    if expected == 127:
        assert "flag provided but not defined: -skip-git" in result.stderr + result.stdout
        assert not output.exists(), label
        return None
    data = json.loads(output.read_text())
    assert isinstance(data["results"], list), label
    print(f"{label}: exit={result.returncode}, result_sources={len(data['results'])}")
    return data


def verify_repo(repo):
    text = (repo / ".github/workflows/osv-scanner.yml").read_text()
    assert f"@{ACTION} # v2.6.0" in text, repo
    block = re.search(r"^      scan-args: \|-\n((?:        .+\n)+)", text, re.MULTILINE)
    assert block, repo
    args = shlex.split(block[1])
    assert "--recursive" in args and "./" in args, repo
    assert "--skip-git" not in args and "--experimental-exclude" not in args, repo
    assert "fail-on-vuln: false" not in text, repo
    if (repo / "Cargo.lock").exists():
        assert "--allow-no-lockfiles" not in args, repo
    scan(repo, args, repo.name.removesuffix("-091-osv-swarm") + "-verified", 0)


def fixtures():
    with tempfile.TemporaryDirectory(prefix="osv-regression-") as temp:
        source = Path(temp)
        args = ["--recursive", "--allow-no-lockfiles", "./"]
        empty = scan(source, args, "fixture-empty", 0)
        assert empty["results"] == []
        scan(source, ["--skip-git", *args], "fixture-obsolete-flag", 127)
        (source / "requirements.txt").write_text("requests==2.19.1\n")
        vulnerable = scan(source, args, "fixture-vulnerable", 1)
        assert any(p.get("vulnerabilities") for s in vulnerable["results"] for p in s["packages"])
        print("synthetic vulnerable dependency still fails with allow-no-lockfiles")


if __name__ == "__main__":
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    for argument in sys.argv[1:]:
        verify_repo(Path(argument).resolve())
    fixtures()
