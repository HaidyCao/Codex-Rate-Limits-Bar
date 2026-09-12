# Repository Guidelines

## Project Structure & Module Organization

Swift 6 package targeting macOS 13+. `Sources/CodexRateLimitsCore/` holds data access, scanning, caching, pricing, CLI/MCP, and refresh control. `Sources/CodexRateLimitsBar/` holds AppKit views and system-event adapters; `main.swift` starts the executable.

XCTest suites are in `Tests/CodexRateLimitsCoreTests/`; integration, rendering, and isolation helpers are in `Tests/{Integration,UI,Support}/`. Bundled prices live in `Sources/CodexRateLimitsCore/Resources/pricing.json`; app metadata lives in `Resources/Info.plist`. Consult [architecture](docs/architecture.md), [verification](docs/verification.md), and [pricing](docs/pricing.md).

## Build, Test, and Development Commands

Use the Xcode toolchain and Python 3.

- `swift build`: debug compilation.
- `make build`: package and sign the release app under `dist/`.
- `make run`: build and launch the app.
- `make test`: isolated XCTest regressions, excluding benchmarks.
- `make verify`: tests, CLI/MCP, AppKit rendering, and bundle-resource checks.
- `make benchmark BENCHMARK_MIB=256`: synthetic scanner performance checks.

AppKit verification needs a graphical session. Avoid `make -j verify` and overlapping UI verification with builds or benchmarks; they share compiled objects.

## Coding Style & Architecture

Use four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Match filenames to responsibilities. Follow existing formatting; no formatter/linter is configured.

Keep `CodexBackend` thin and implementations internal. `RefreshCoordinator` owns scheduling policy; `UsageRefreshController` owns work and state. AppKit forwards events and renders. Use `@MainActor` for controller/UI state, `Sendable` across queues, and `AppText` for localization.

## Statistics & Compatibility

Keep API-equivalent costs, estimated Codex credits, and official balances distinct. Unknown models remain unpriced unless explicitly configured; never infer prices from name prefixes. Daily totals span selected local homes; weekly observations belong to the active account. Preserve cache compatibility, valid observation baselines, and CLI/MCP contracts when changing behavior.

## Testing Guidelines

Use `FeatureTests.swift` and `testDescriptiveBehavior`. Add behavioral regressions with temporary fixtures, injected clients, and controlled clocks. Compare incremental/rebuilt totals against independent expectations. Run targeted tests through isolation:

```sh
python3 Tests/Support/run_isolated.py swift test --filter UsageRefreshControllerTests
```

Run `make verify` for runtime changes; add benchmarks for scanner/cache changes. Inspect `.build/verification/menu/` renders for UI changes. Documentation-only edits need link and diff checks. Report any unavailable system-event checks.

## Commit & Pull Request Guidelines

Follow history: `feat:`, `fix:`, `refactor:`, `test:` with imperative summaries. Keep commits focused. PRs describe behavior, validation, compatibility, relevant issues/TODOs, and screenshots for visible changes.

## Configuration & Data

Verification wrappers isolate credentials and block networking. Launching/installing the app uses real state; back up application state before `make install-user`. `CODEX_HOME` selects the account; `env -u CODEX_HOME make verify-live` checks the default desktop profile. Never commit credentials, personal logs, or build artifacts.
