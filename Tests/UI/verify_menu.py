"""Compile the actual AppKit views with a verification entry point, then render fixtures."""
import argparse
from pathlib import Path
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, offline_command, run_checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="release")
    parser.add_argument("--artifacts", type=Path, default=Path(".build/verification"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    artifacts = (repo / args.artifacts).resolve()
    build = Path(run_checked(["swift", "build", "-c", args.config, "--show-bin-path"], cwd=repo,
                             text=True, capture_output=True).stdout.strip())
    executable = artifacts / "VerifyMenu"
    # Swift Build places a combined target object and module beside the product.
    # Older SwiftPM uses per-source objects plus a Modules directory. Only look
    # inside the active --show-bin-path; other layouts may contain stale builds.
    combined = build / "CodexRateLimitsCore.o"
    if combined.is_file():
        objects = [combined]
        modules = build
    else:
        objects = sorted((build / "CodexRateLimitsCore.build").glob("*.swift.o"))
        modules = build / "Modules"
    if not objects:
        raise SystemExit("Core objects missing; run make build first")
    if not (modules / "CodexRateLimitsCore.swiftmodule").exists():
        raise SystemExit("Core module missing from the active build; run make build first")
    app_sources = sorted(path for path in (repo / "Sources/CodexRateLimitsBar").glob("*.swift")
                         if path.name != "main.swift")
    run_checked(["swiftc", "-swift-version", "6", "-parse-as-library",
                 "-I", modules, *objects, *app_sources,
                 repo / "Tests/UI/VerifyMenu.swift", "-o", executable])
    with tempfile.TemporaryDirectory(prefix="codex-menu-verification-") as directory:
        run_checked(offline_command([executable, artifacts / "fixtures", artifacts / "menu",
                                     "-AppleLanguages", "(en-US)"]),
                    env=isolated_environment(directory))
        for language in ["zh-Hans", "zh-Hant", "ja", "ko"]:
            run_checked(offline_command([executable, artifacts / "fixtures", artifacts / "menu" / language,
                                         "-AppleLanguages", f"({language})", "--localized"]),
                        env=isolated_environment(directory))


if __name__ == "__main__":
    main()
