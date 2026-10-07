"""Behavioral regressions for archive corruption and misleading provenance."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Integration"))
from verify_pricing_archive import ARCHIVE, REPOSITORY, SOURCE_PATH, validate_archive


class PricingArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="codex-archive-tests-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "archive"
        shutil.copytree(ARCHIVE, self.archive)
        self.builtin = self.root / "pricing.json"
        shutil.copyfile(REPOSITORY / SOURCE_PATH, self.builtin)
        self.manifest_path = self.archive / "manifest.json"
        self.manifest = json.loads(self.manifest_path.read_text())

    def save(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def validate(self):
        return validate_archive(self.archive, self.builtin)

    def testValidArchiveIsReadOnlyAndKeepsUnknownEffectiveDates(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.validate()
        self.assertEqual(len(result), len(self.manifest["snapshots"]))
        for entry in self.manifest["snapshots"]:
            for kind in ("api", "credits"):
                self.assertIsNone(entry[kind]["effectiveFrom"])
                self.assertIsNone(entry[kind]["effectiveTo"])
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def testChangedHistoricalPriceFailsItsFingerprint(self):
        entry = self.manifest["snapshots"][0]
        path = self.archive / entry["file"]
        document = json.loads(path.read_text())
        next(iter(document["api"]["models"].values()))["input"] += 1
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.validate()

    def testRepeatedCreditVersionCannotHideDifferentPricesBehindNewHash(self):
        versions = {}
        for entry in self.manifest["snapshots"]:
            version = entry["credits"]["version"]
            if version in versions:
                break
            versions[version] = entry
        else:
            self.fail("Fixture must retain at least one repeated credit version")
        path = self.archive / entry["file"]
        document = json.loads(path.read_text())
        next(iter(document["credits"]["models"].values()))["output"] += 1
        path.write_text(json.dumps(document))
        entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save()
        with self.assertRaisesRegex(ValueError, "Conflicting credits version"):
            self.validate()

    def testBuiltinEditNeedsAnArchivedCurrentSnapshot(self):
        self.builtin.write_bytes(self.builtin.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "Current archive differs"):
            self.validate()

    def testDuplicateSnapshotsAreRejected(self):
        self.manifest["snapshots"].append(self.manifest["snapshots"][0])
        self.save()
        with self.assertRaisesRegex(ValueError, "Duplicate snapshot"):
            self.validate()

    def testMissingCardIsRejected(self):
        (self.archive / self.manifest["snapshots"][0]["file"]).unlink()
        with self.assertRaisesRegex(ValueError, "Missing archive file"):
            self.validate()

    def testUnlistedCardIsRejected(self):
        (self.archive / "cards/orphan.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            self.validate()

    def testSymlinkCannotSubstituteAnArchivedCard(self):
        card = self.archive / self.manifest["snapshots"][0]["file"]
        outside = self.root / "outside.json"
        card.rename(outside)
        card.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.validate()

    def testMisleadingMetadataIsRejected(self):
        changes = [
            ("version", "2099-01-01.1", "version mismatch"),
            ("verifiedAt", "2000-01-01", "verifiedAt mismatch"),
            ("effectiveFrom", "2026-10-07", "unknown effective periods"),
            ("effectiveTo", "2027-01-01", "unknown effective periods"),
        ]
        original = self.manifest_path.read_text()
        for key, value, message in changes:
            with self.subTest(field=key):
                self.manifest = json.loads(original)
                self.manifest["snapshots"][0]["api"][key] = value
                self.save()
                with self.assertRaisesRegex(ValueError, message):
                    self.validate()

    def testEvidenceCannotInventReviewOrChangeSource(self):
        for key, value, message in [
            ("reviewedOn", "2026-10-07", "cannot claim a review date"),
            ("sources", ["https://example.com/unsupported"], "Sources mismatch"),
            ("summary", "", "Missing evidence summary"),
        ]:
            with self.subTest(field=key):
                evidence = self.manifest["snapshots"][0]["api"]["evidence"]
                before = evidence[key]
                evidence[key] = value
                self.save()
                with self.assertRaisesRegex(ValueError, message):
                    self.validate()
                evidence[key] = before

    def testInvalidDatesAndUnknownFieldsFailClosed(self):
        self.manifest["snapshots"][0]["archivedOn"] = "2026-02-30"
        self.save()
        with self.assertRaises(ValueError):
            self.validate()
        self.manifest["unexpected"] = True
        self.save()
        with self.assertRaisesRegex(ValueError, "Invalid fields: manifest"):
            self.validate()

    def testCurrentMustReferenceAnEntry(self):
        self.manifest["current"] = "missing"
        self.save()
        with self.assertRaisesRegex(ValueError, "Current snapshot is missing"):
            self.validate()

    def testDuplicateJSONKeysAndNonfiniteValuesAreRejected(self):
        for text, message in [(' {"schemaVersion":1,"schemaVersion":2}', "Duplicate JSON key"),
                              (' {"schemaVersion":NaN}', "Non-finite JSON")]:
            with self.subTest(text=text):
                self.manifest_path.write_text(text)
                with self.assertRaisesRegex(ValueError, message):
                    self.validate()

    def testCLIReportsFailureWithoutTraceback(self):
        self.manifest["current"] = "missing"
        self.save()
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "Integration/verify_pricing_archive.py"),
                                 "--archive", str(self.archive), "--builtin", str(self.builtin)],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Current snapshot is missing", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
