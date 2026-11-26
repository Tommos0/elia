#!/usr/bin/env python3
"""Reproduce the review's limited checks without changing Elia's checkout.

This is NOT Elia's test suite. It runs syntax checks, the runner's --plan,
repository inventory, and isolated filesystem/Git primitive demonstrations.
No network, package installation, model call, or running Elia service is used.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


def run(argv, cwd, data=None):
    try:
        p = subprocess.run(argv, cwd=cwd, input=data, text=True,
                           capture_output=True, timeout=40)
        return {"command": argv, "exit_code": p.returncode,
                "stdout": p.stdout, "stderr": p.stderr}
    except FileNotFoundError as e:
        return {"command": argv, "exit_code": None, "status": "unavailable",
                "stderr": str(e)}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()
    repo, out = args.repo.resolve(), args.output.resolve()
    if out == repo or repo in out.parents:
        ap.error("--output must be outside the source checkout")
    out.mkdir(parents=True, exist_ok=True)
    checks = []
    before = run(["git", "status", "--porcelain=v1"], repo)
    sha = run(["git", "rev-parse", "HEAD"], repo)["stdout"].strip()
    expected_sha = "5be0bd873bd2716529de25541efb1825495cd12e"
    if sha != expected_sha:
        ap.error(f"This replay is for {expected_sha}; checkout has {sha}")
    if before.get("exit_code") != 0 or before.get("stdout"):
        ap.error("Use a clean checkout of the reviewed snapshot")
    paths = run(["git", "ls-files", "-z"], repo)["stdout"].split("\0")
    paths = [p for p in paths if p]
    blobs = {}
    inventory = []
    for path in paths:
        data = subprocess.check_output(["git", "show", f"{sha}:{path}"], cwd=repo)
        try:
            source = data.decode("utf-8")
        except UnicodeDecodeError:
            source = None
        if source is not None:
            blobs[path] = source
        inventory.append({"path": path, "bytes": len(data),
                          "lines": len(source.splitlines()) if source is not None else None,
                          "sha256": hashlib.sha256(data).hexdigest(),
                          "kind": "text" if source is not None else "binary",
                          "source_url": f"https://github.com/Tommos0/elia/blob/{sha}/{path}"})
    checks.append({"id": "V01", "name": "runtime availability",
                   "result": [run([cmd, "--version"], repo) for cmd in
                              ["elixir", "mix", "node", "npm", "git", "python3"]]})
    # Never run the formatting/build/test alias on a machine that has Mix.
    # In the review environment it was absent; retain that unavailable-command
    # observation without turning this static replay into an application run.
    precommit = (run(["mix", "precommit"], repo) if shutil.which("mix") is None else
                 {"command": ["mix", "precommit"], "exit_code": None,
                  "status": "not run", "reason": "Runtime gate is separate; this script never executes it when Mix is installed."})
    checks.append({"id": "V02", "name": "mix precommit availability only",
                   "result": precommit,
                   "note": "Unavailable runtime is an environment block, not a failing Elia test. Run the application gate separately, in the serialized test queue."})
    checks.append({"id": "V03", "name": "shell syntax",
                   "result": [run(["sh", "-n", path], repo) for path in paths if path.startswith("bin/")]})
    js = [p for p in paths if p.startswith("assets/js/") and p.endswith(".js")]
    js += ["priv/static/sw.js"]
    checks.append({"id": "V04", "name": "first-party JavaScript syntax only",
                   "result": [{"file": p, **run(["node", "--input-type=module", "--check"], repo, blobs[p])} for p in js],
                   "note": "Does not resolve imports, build assets, or test browser behavior."})
    parsed_json = []
    for p in ["assets/package.json", "assets/package-lock.json", "priv/static/manifest.webmanifest"]:
        try:
            json.loads(blobs[p])
            parsed_json.append({"file": p, "result": "valid JSON"})
        except ValueError as e:
            parsed_json.append({"file": p, "result": str(e)})
    checks.append({"id": "V05", "name": "JSON syntax", "result": parsed_json,
                   "note": "assets/tsconfig.json contains valid comment syntax for JSONC; deliberately excluded from this strict JSON check."})
    plan = run(["sh", "bin/test", "--plan"], repo)
    (out / "test-plan.txt").write_text(plan.get("stdout", ""))
    assigned = []
    for line in plan.get("stdout", "").splitlines():
        if line.strip().startswith("files:"):
            assigned += line.split("files:", 1)[1].split()
    tests = [p for p in paths if p.startswith("test/") and p.endswith("_test.exs")]
    checks.append({"id": "V06", "name": "test partition plan (no tests executed)",
                   "exit_code": plan["exit_code"], "tracked_test_files": len(tests),
                   "assigned_count": len(assigned),
                   "missing": sorted(set(tests)-set(assigned)),
                   "extra": sorted(set(assigned)-set(tests)),
                   "duplicates": [p for p, n in collections.Counter(assigned).items() if n > 1]})
    dependencies = json.loads(blobs["assets/package.json"])["dependencies"]
    resolver = "for (const p of process.argv.slice(1)) {try {console.log(p + ': ' + require.resolve(p, {paths: [process.cwd() + '/assets']}))} catch(e) {console.log(p + ': ' + e.code)}}"
    checks.append({"id": "V07", "name": "fresh checkout asset package resolution",
                   "result": run(["node", "-e", resolver, *dependencies], repo),
                   "note": "Expected missing packages in a clone; the review finding is that mix setup never installs them."})
    with tempfile.TemporaryDirectory(prefix="primitive-probe-", dir=out) as scratch:
        base = Path(scratch)
        workspace = base / "workspace"
        private = base / "private"
        workspace.mkdir()
        private.mkdir()
        sentinel = private / "sentinel.txt"
        sentinel.write_text("review-generated-dummy-content")
        instruction = workspace / "AGENTS.md"
        instruction.symlink_to(sentinel)
        followed_read = instruction.read_text() == sentinel.read_text()
        protected = workspace / ".git"
        protected.mkdir()
        target = protected / "review-canary"
        target.write_text("before")
        alias = workspace / "ordinary-alias"
        alias.symlink_to(protected, target_is_directory=True)
        (alias / "review-canary").write_text("after")
        checks.append({"id": "V08", "name": "isolated symlink primitives",
                       "host_read_follows_external_symlink": followed_read,
                       "host_write_follows_directory_alias": target.read_text() == "after",
                       "status": "primitive reproduced",
                       "note": "Only generated dummy files. Does not execute Elia or demonstrate an end-to-end jail escape."})
        fixture = base / "git-fixture"
        fixture.mkdir()
        def git(*parts):
            result = run(["git", "-c", "user.name=Review Fixture", "-c", "user.email=review@example.invalid", *parts], fixture)
            if result.get("exit_code") != 0:
                raise RuntimeError(result)
            return result["stdout"].strip()
        git("init", "-q")
        (fixture / ".gitignore").write_text("/priv/static/assets/\n")
        (fixture / "source.txt").write_text("version A")
        git("add", ".")
        git("commit", "-qm", "baseline fixture")
        first = git("rev-parse", "HEAD")
        asset = fixture / "priv/static/assets/app.js"
        asset.parent.mkdir(parents=True)
        asset.write_text("generated A")
        (fixture / "source.txt").write_text("version B")
        git("add", "source.txt")
        git("commit", "-qm", "candidate fixture")
        asset.write_text("partial generated B")
        git("reset", "--hard", first)
        checks.append({"id": "V09", "name": "isolated Git rollback primitive",
                       "tracked_source_restored": (fixture / "source.txt").read_text() == "version A",
                       "ignored_candidate_asset_remains": asset.read_text() == "partial generated B",
                       "git_reports_clean": git("status", "--porcelain") == "",
                       "status": "primitive reproduced",
                       "note": "New disposable repository only; does not execute Elia.Deploy."})
    after = run(["git", "status", "--porcelain=v1"], repo)
    checks.append({"id": "V10", "name": "checkout unchanged",
                   "before": before["stdout"], "after": after["stdout"],
                   "unchanged": before["stdout"] == after["stdout"] == ""})
    metrics = {
        "tracked_files": len(paths),
        "first_party_elixir_modules": sum(p.startswith("lib/") and p.endswith(".ex") for p in paths),
        "first_party_lib_lines": sum(i["lines"] or 0 for i in inventory if i["path"].startswith("lib/")),
        "test_files": len(tests),
        "test_source_lines": sum(i["lines"] or 0 for i in inventory if i["path"].startswith("test/")),
        "spec_markdown_files": sum(p.startswith("specs/") and p.endswith(".md") for p in paths),
        "test_declarations_approximate": sum(len(re.findall(r'^\s*test\s+', blobs[p], re.M)) for p in tests),
        "github_workflow_files": [p for p in paths if p.startswith(".github/workflows/")],
        "root_license_files": [p for p in paths if "/" not in p and re.match(r'(?i)(license|copying)', p)],
    }
    output = {"review_commit": sha, "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "Static checks and isolated primitives, not the application test suite",
              "metrics": metrics, "checks": checks}
    (out / "static-checks.json").write_text(json.dumps(output, indent=2) + "\n")
    (out / "repository-inventory.json").write_text(json.dumps({"commit": sha, "files": inventory}, indent=2) + "\n")
    print(json.dumps({"commit": sha, "metrics": metrics, "checks": [{"id": c["id"], "name": c["name"]} for c in checks], "output": str(out)}, indent=2))


if __name__ == "__main__":
    main()
