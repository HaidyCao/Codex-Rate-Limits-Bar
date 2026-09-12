"""Verify a relocated .app can read prices while its build directory is inaccessible."""
import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, run_checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    expected = json.loads((repo / "Sources/CodexRateLimitsCore/Resources/pricing.json").read_text())
    with tempfile.TemporaryDirectory(prefix="codex-bundle-verification-") as directory:
        root = Path(directory)
        app = root / "Relocated.app"
        shutil.copytree(args.app.resolve(), app)
        # Do not rename, remove, or modify another build's resource directory.
        policy = '(version 1)(allow default)(deny network*)(deny file-read* (subpath ' + json.dumps(str(repo / ".build")) + '))'
        value = run_checked(["/usr/bin/sandbox-exec", "-p", policy, app / "Contents/MacOS/CodexRateLimitsBar",
                             "pricing", "--export-builtin"], env=isolated_environment(root),
                            capture_output=True, text=True, timeout=15)
        assert json.loads(value.stdout) == expected
    print("Relocated bundle verification passed with build resources inaccessible.")


if __name__ == "__main__":
    main()
