# Codex Rate Limits Bar

Tiny macOS menu bar app for Codex rate limits.

- Top line: 5-hour remaining quota.
- Bottom line: weekly remaining quota.
- Data source: `codex app-server --stdio` via `account/rateLimits/read`.
- A second menu bar item shows today's local machine token usage:
  - Top line: consumed tokens, scaled to 亿 / 万 / raw count.
  - Bottom line: cache hit rate, calculated as cached input tokens divided by input tokens.
  - Data source: `~/.codex/sessions/**/*.jsonl` token_count events.

## Build and Run

```sh
make build
open "dist/Codex Rate Limits Bar.app"
```

## One-Command Install

On another Mac, install Codex CLI first and log in, then run from this repo:

```sh
./install.sh
```

The installer:

- builds and installs `Codex Rate Limits Bar.app` into `~/Applications`;
- copies the bundled `plugins/codex-usage-monitor` plugin into `~/plugins`;
- creates or updates `~/.agents/plugins/marketplace.json` without removing other personal plugins;
- refreshes `codex-usage-monitor@personal` with `codex plugin remove` + `codex plugin add`;
- starts the status bar app.

Requirements:

- macOS with Xcode Command Line Tools (`xcode-select --install` if missing);
- Node.js on `PATH`;
- Codex CLI on `PATH`;
- `codex login` completed on the target machine.

Useful commands:

```sh
make run          # build and open from dist/
make open         # open the existing dist app
make stop         # stop the dist app
make install-user # copy to ~/Applications and open it
```

For a quick data-source check:

```sh
make verify
node scripts/codex_rate_limits.js local-usage
```

## Shared Helper

The app uses `scripts/codex_rate_limits.js`. The local `codex-usage-monitor`
plugin is bundled under `plugins/codex-usage-monitor` and prefers the helper
inside `~/Applications/Codex Rate Limits Bar.app`, so the status bar and Codex
plugin share the same rate-limit and local-usage reading path after install.
