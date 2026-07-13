# Codex Rate Limits Bar

Tiny macOS menu bar app for Codex rate limits.

- Rate-limit status item: weekly remaining quota, shown as `W 92%`, with the next reset below in the system date/time format (time today, date otherwise, and year only when needed).
- Data source: `codex app-server --stdio` via `account/rateLimits/read`.
- A second menu bar item shows today's local machine token usage:
  - Top line: consumed tokens, scaled to localized compact units.
  - Bottom line: cache hit rate, calculated as cached input tokens divided by input tokens.
  - Visible by default and can be hidden from the menu settings.
  - Data source: `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/*.jsonl` token_count events.
- The app, command-line data reader, and bundled MCP server are implemented in
  one Swift executable. Node.js is not required.
- If Codex was installed via npm, the app looks for the native Codex vendor
  binary and does not launch the Node wrapper.

## Build and Run

```sh
make build
open "dist/Codex Rate Limits Bar.app"
```

## One-Command Install

On another Mac, install Codex first and log in, then run from this repo:

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
- Codex CLI on `PATH`, or Codex.app installed in `/Applications`;
- `codex login` completed on the target machine.

Useful commands:

```sh
make run          # build and open from dist/
make open         # open the existing dist app
make stop         # stop the dist app
make install-user # copy to ~/Applications and open it
make install-plugin
```

`make install-plugin` also installs the app before refreshing the bundled Codex
plugin.

For a quick data-source check:

```sh
make verify
dist/Codex\ Rate\ Limits\ Bar.app/Contents/MacOS/CodexRateLimitsBar local-usage
dist/Codex\ Rate\ Limits\ Bar.app/Contents/MacOS/CodexRateLimitsBar status
```

## Shared Swift Binary

The executable supports several command-line modes in addition to the menu bar
app:

```sh
CodexRateLimitsBar status
CodexRateLimitsBar rate-limits
CodexRateLimitsBar local-usage
CodexRateLimitsBar reset-credits
CodexRateLimitsBar usage
CodexRateLimitsBar mcp
```

The local `codex-usage-monitor` plugin is bundled under
`plugins/codex-usage-monitor` and launches the installed app binary with `mcp`,
so the status bar and Codex plugin share the same Swift data path after install.
No JavaScript helper is copied into the app or plugin.
