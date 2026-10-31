"""Exercise release shell steps with temporary assets and a fake gh client.

The real workflow accepts tag pushes or manual runs on existing tags. No build,
Git tag, remote API or release
mutation is performed by these tests; Ruby's bundled YAML parser reads the same
workflow that Actions will execute.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
CHECKS_WORKFLOW = ROOT / ".github/workflows/checks.yml"
VERSION = "1.2.3"
EXPECTED_ASSETS = (
    f"ClaudeSwitcher-{VERSION}-macos-arm64-app-only.zip",
    f"ClaudeSwitcher-{VERSION}-macos-arm64-app-only.dmg",
    f"ClaudeSwitcher-{VERSION}-macos-arm64-update.zip",
    f"ClaudeSwitcher-{VERSION}-macos-x86_64-app-only.zip",
    f"ClaudeSwitcher-{VERSION}-macos-x86_64-app-only.dmg",
    f"ClaudeSwitcher-{VERSION}-macos-x86_64-update.zip",
    f"ClaudeSwitcher-{VERSION}-installer-kit.zip",
    f"ClaudeSwitcher-{VERSION}-windows.zip",
    f"ClaudeSwitcher-{VERSION}-linux.tar.gz",
)


@unittest.skipUnless(shutil.which("ruby"), "Release YAML validation uses macOS bundled Ruby")
class ReleasePipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parsed = subprocess.run(
            ["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(ARGV.map { |path| YAML.load_file(path) })",
             str(WORKFLOW), str(CHECKS_WORKFLOW)],
            capture_output=True, text=True, timeout=10,
        )
        if parsed.returncode:
            raise AssertionError(parsed.stdout + parsed.stderr)
        cls.workflow, cls.checks_workflow = json.loads(parsed.stdout)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release-pipeline-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "build").mkdir()
        self.env = dict(os.environ, VERSION=VERSION, RELEASE_TAG="v" + VERSION, RELEASE_REF_TYPE="tag",
                        GITHUB_OUTPUT=str(self.root / "github-output"))

    def script(self, job, name):
        return next(step["run"] for step in self.workflow["jobs"][job]["steps"] if step["name"] == name)

    def run_step(self, job, name, env=None):
        return subprocess.run(["/bin/bash", "-c", self.script(job, name)], cwd=self.root,
                              env=env or self.env, capture_output=True, text=True, timeout=10)

    def assets(self):
        for index, name in enumerate(EXPECTED_ASSETS):
            (self.root / "build" / name).write_bytes((str(index) + ":" + name).encode())

    def manifest(self):
        self.assets()
        result = self.run_step("publish", "Generate release checksums")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.root / "build/SHA256SUMS-release.txt"

    def fake_gh(self, exit_code=0):
        binary = self.root / "bin"
        binary.mkdir()
        client = binary / "gh"
        client.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'with open(os.environ["GH_CAPTURE"], "a") as handle:\n'
            '    handle.write(json.dumps(sys.argv[1:]) + "\\n")\n'
            'raise SystemExit(int(os.environ["GH_EXIT"]))\n', encoding="utf-8")
        client.chmod(0o755)
        return dict(self.env, PATH=str(binary) + os.pathsep + os.environ.get("PATH", ""),
                    GH_CAPTURE=str(self.root / "gh-calls"), GH_EXIT=str(exit_code))

    def calls(self):
        return [json.loads(line) for line in (self.root / "gh-calls").read_text().splitlines()]

    def test_tag_push_or_existing_tag_dispatch_requires_full_architecture_matrix(self):
        self.assertEqual(self.workflow["on"], {"push": {"tags": ["v*"]}, "workflow_dispatch": None})
        validator = next(step for step in self.workflow["jobs"]["validate"]["steps"] if step["id"] == "version")
        self.assertEqual(validator["env"]["RELEASE_REF_TYPE"], "${{ github.ref_type }}")
        jobs = self.workflow["jobs"]
        build = jobs["macos"]
        self.assertEqual(set(build["needs"]), {"validate", "verify"})
        matrix = build["strategy"]["matrix"]["include"]
        self.assertEqual({item["arch"]: item["os"] for item in matrix},
                         {"arm64": "macos-15", "x86_64": "macos-15-intel"})
        self.assertFalse(build["strategy"]["fail-fast"])
        self.assertFalse(build.get("continue-on-error", False))
        self.assertIn("macos", jobs["publish"]["needs"])
        self.assertIn("validate", jobs["publish"]["needs"])
        self.assertIn("verify", jobs["publish"]["needs"])
        self.assertNotIn("if", jobs["publish"], "Publish must use Actions' default success gate")
        self.assertEqual(self.workflow["permissions"]["contents"], "read")
        self.assertEqual(jobs["publish"]["permissions"]["contents"], "write")

    def test_release_tests_the_calling_tag_before_building_or_publishing(self):
        jobs = self.workflow["jobs"]
        verify = jobs["verify"]
        self.assertEqual(verify["needs"], "validate")
        # Local workflow references load the workflow from the caller's same commit.
        self.assertEqual(verify["uses"], "./.github/workflows/checks.yml")
        self.assertEqual(verify["permissions"], {"contents": "read"})
        # Ruby's YAML 1.1 parser maps an unquoted 'on' key to JSON's 'true'.
        triggers = self.checks_workflow.get("on", self.checks_workflow.get("true"))
        self.assertIn("workflow_call", triggers)
        self.assertIn("pull_request", triggers)
        self.assertIn("workflow_dispatch", triggers)
        self.assertEqual(triggers["push"]["branches"], ["main"])
        self.assertEqual(self.checks_workflow["permissions"], {"contents": "read"})
        for job in ("verify", "macos", "publish"):
            self.assertNotIn("if", jobs[job], "Validation failures must use the default success gate")
            self.assertFalse(jobs[job].get("continue-on-error", False))
        for definition in self.checks_workflow["jobs"].values():
            checkout = next(step for step in definition["steps"]
                            if step.get("uses", "").startswith("actions/checkout@"))
            self.assertNotIn("ref", checkout.get("with", {}),
                             "Reusable checks must not override the calling release tag with a branch")

    def test_tag_validator_accepts_only_three_numeric_semver_parts(self):
        for tag in ("v0.0.0", "v1.2.3", "v12.34.56"):
            with self.subTest(tag=tag):
                output = self.root / "github-output"
                output.unlink(missing_ok=True)
                result = self.run_step("validate", "Resolve version from tag", dict(self.env, RELEASE_TAG=tag))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(output.read_text(), "version=" + tag[1:] + "\n")
        for tag in ("1.2.3", "v1", "v1.2", "v1.2.3.4", "v1.2.3-beta", "v1.2.3+build",
                    "v01.2.3", "v1.02.3", "v1.2.03", "v-1.2.3", "v1.2.3\n", "v1.2.3$(touch injected)"):
            with self.subTest(tag=tag):
                output = self.root / "github-output"
                output.unlink(missing_ok=True)
                result = self.run_step("validate", "Resolve version from tag", dict(self.env, RELEASE_TAG=tag))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists(), "Invalid tags must not emit a version for downstream jobs")
                self.assertFalse((self.root / "injected").exists())

    def test_manual_dispatch_requires_existing_tag_even_for_semver_named_branches(self):
        for ref_type, ref_name in (("branch", "main"), ("branch", "v1.2.3"),
                                   ("", "v1.2.3"), ("tag\n", "v1.2.3")):
            with self.subTest(ref_type=ref_type, ref_name=ref_name):
                output = self.root / "github-output"
                output.unlink(missing_ok=True)
                result = self.run_step("validate", "Resolve version from tag",
                                       dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch",
                                            RELEASE_REF_TYPE=ref_type, RELEASE_TAG=ref_name))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists(), "Branch dispatch must not emit a release version")
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                output = self.root / "github-output"
                output.unlink(missing_ok=True)
                result = self.run_step("validate", "Resolve version from tag",
                                       dict(self.env, GITHUB_EVENT_NAME=event))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(output.read_text(), "version=" + VERSION + "\n")

    def test_checksum_manifest_covers_both_architectures_and_all_platforms(self):
        manifest = self.manifest()
        rows = [line.split("  ", 1) for line in manifest.read_text().splitlines()]
        self.assertEqual({name for _, name in rows}, set(EXPECTED_ASSETS))
        self.assertEqual(len(rows), len(EXPECTED_ASSETS))
        for checksum, name in rows:
            self.assertEqual(checksum, hashlib.sha256((self.root / "build" / name).read_bytes()).hexdigest())

    def test_missing_or_empty_architecture_artifact_blocks_checksum_publication(self):
        for name in EXPECTED_ASSETS:
            with self.subTest(name=name):
                self.assets()
                manifest = self.root / "build/SHA256SUMS-release.txt"
                manifest.unlink(missing_ok=True)
                (self.root / "build" / name).unlink()
                result = self.run_step("publish", "Generate release checksums")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(manifest.exists(), "Incomplete assets must never get a release checksum manifest")
        self.assets()
        (self.root / "build" / EXPECTED_ASSETS[2]).write_bytes(b"")
        result = self.run_step("publish", "Generate release checksums")
        self.assertNotEqual(result.returncode, 0)

    def test_publish_creates_one_verified_tag_release_with_exact_manifest_assets(self):
        self.manifest()
        result = self.run_step("publish", "Publish release once", self.fake_gh())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        command = calls[0]
        self.assertEqual(command[:3], ["release", "create", "v" + VERSION])
        self.assertIn("--verify-tag", command)
        self.assertNotIn("--draft", command)
        self.assertNotIn("--prerelease", command)
        self.assertNotIn("--clobber", command)
        uploaded = {arg for arg in command if arg.startswith("build/")}
        self.assertEqual(uploaded, {"build/" + name for name in EXPECTED_ASSETS} | {"build/SHA256SUMS-release.txt"})

    def test_existing_release_failure_does_not_upload_or_overwrite_assets(self):
        self.manifest()
        result = self.run_step("publish", "Publish release once", self.fake_gh(exit_code=1))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][:3], ["release", "create", "v" + VERSION])
        self.assertNotIn("--clobber", self.calls()[0])

    def test_malformed_manifest_cannot_reach_release_client(self):
        self.assets()
        manifest = self.root / "build/SHA256SUMS-release.txt"
        for content in ("0" * 64 + "  ../escape\n", "not-a-hash  " + EXPECTED_ASSETS[0] + "\n", ""):
            with self.subTest(content=content):
                manifest.write_text(content)
                capture = self.root / "gh-calls"
                capture.unlink(missing_ok=True)
                binary = self.root / "bin"
                if binary.exists():
                    shutil.rmtree(binary)
                result = self.run_step("publish", "Publish release once", self.fake_gh())
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(capture.exists())

    def test_all_embedded_shell_steps_parse_with_bash(self):
        for job, definition in self.workflow["jobs"].items():
            for step in definition.get("steps", []):
                if "run" in step:
                    with self.subTest(job=job, step=step["name"]):
                        result = subprocess.run(["/bin/bash", "-n"], input=step["run"],
                                                capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
