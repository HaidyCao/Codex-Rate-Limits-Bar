# Codex Rate Limits Bar

Tiny macOS menu bar app for Codex rate limits.

Planned fixes and improvements: [Project TODO](TODO.md).

- Rate-limit status item: weekly remaining quota, shown as `W 92%`, with the next reset below in the system date/time format (time today, date otherwise, and year only when needed).
- The Usage card compares the remaining quota with the time budget, learns from recent consumption, and estimates either the remaining quota at reset or an early exhaustion time.
- Optional system notifications warn at 25% and 10%, when a medium/high-confidence forecast predicts early exhaustion, and shortly after a weekly reset. Alerts are deduplicated per quota window and are disabled by default.
- Forecast samples and alert state are stored in `~/Library/Application Support/Codex Rate Limits Bar/quota-history.<scope>.json`, isolated by account, Codex home, authentication source and quota bucket. Samples are recorded only when the percentage changes or every 30 minutes and are retained for 60 days.
- Data source: `codex app-server --stdio` via `account/rateLimits/read`.
- The Usage card also shows the official purchased-credit balance when returned by Codex, separately from earned rate-limit reset coupons. Missing balances display `--`; zero, negative and unlimited balances stay distinct.
- A second menu bar item shows today's local machine token usage:
  - Top line: consumed tokens, scaled to localized compact units.
  - Bottom line: cache hit rate, calculated as cached input tokens divided by input tokens.
  - The expanded panel shows today's API-equivalent estimated cost in USD, a separate Codex credit estimate, price coverage, and unpriced models/modes.
  - Visible by default and can be hidden from the menu settings.
  - Data source: `token_count` events in active and archived sessions under `~/.codex`, `~/.codex-cli`, and `CODEX_HOME` when configured. Canonical paths and copied rollout filenames are deduplicated; `CODEX_SESSIONS_DIR` explicitly selects one directory.
  - Session files are read incrementally with a reusable 1 MB buffer. Per-file cursors, daily baselines, and compact model cost buckets are persisted for up to eight days so app restarts and local-midnight rollover do not rescan complete histories.
- The Usage card learns the API-equivalent USD value of the weekly quota from this Mac's incremental cost and the matching change in Codex's used percentage. It waits for at least two observed percentage points and 95% known-price coverage before showing a value.
- The app, command-line data reader, and bundled MCP server are implemented in
  one Swift executable. Node.js is not required.
- If Codex was installed via npm, the app looks for the native Codex vendor
  binary and does not launch the Node wrapper.

## Account Attribution

The menu identifies the current account; its tooltip includes the Codex home,
authentication source and quota bucket. Daily token and cost totals still cover
all local homes. Quota, official credit balance, reset credits and weekly cost
observations refer to the selected account.

Each official refresh reads `account/read` and `account/rateLimits/read` from
one app-server pinned to the active `CODEX_HOME` (default `~/.codex`). Reset
credits use the returned `rateLimitResetCredits` when available; `availableCount`
is authoritative even when details are absent or capped. For older responses,
the private endpoint is used only with verified credentials from that same home.
`CODEX_AUTH_FILE` no longer redirects reset queries independently of the Codex
login. Account changes detected during a refresh discard that response.

Persistent identity uses a digest of the local account/workspace and user
identifiers, without storing access tokens or JWTs. If file credentials cannot
be verified, including managed keyring/auto/ephemeral storage, official values
remain available but account-specific history, alerts and weekly cost learning
are paused and the menu marks the identity unconfirmed.

Legacy `quota-history.json` is left intact and is not assigned to an account.
The daily usage cache and cursors are reused; an untagged legacy weekly
observation starts fresh. Tagged observations survive same-account restarts.
Switching accounts or quota buckets starts a new weekly cost observation so
events from the previous login cannot carry over. Forecast and alert history
for a known account is restored when returning to its scope.

## Cost Estimates

Cost estimates use the model recorded in each local Codex turn, distinguish
uncached input, cached input, cache writes, and output, and apply the published
long-context tier only when a request reports more than 272K input tokens.
Prices come from the [OpenAI API pricing page](https://developers.openai.com/api/docs/pricing).

[GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) is supported
as `gpt-6-astra`, including dated snapshots. Standard rates verified on 2026-09-05
are $10 input, $1 cached input, $12.50 cache writes, and $50 output per 1M tokens.
Above 272K request input tokens, the respective rates are $20, $2, $25, and $75.
Estimates use Standard API rates; Fast, Batch, Flex, regional surcharges, and tool
fees are not included.

Daybreak Blue (`gpt-daybreak-blue-latest`) currently follows GPT-5.6 Sol pricing;
Daybreak Red follows GPT-5.6 Cyber. Raw model names are retained in the output.
Only explicit aliases and dated snapshots inherit prices. Spark, Pro, and unknown
variants never inherit a price solely by sharing a model-name prefix.

Each model bucket stores its effective pricing signature. Changes to a price,
alias or calculation rule replay the affected retained session files, including
weekly files, without resetting the weekly observation baseline. Legacy v4 caches
are upgraded in place; unreadable/missing logs remain unpriced until they can be
replayed. Adding a session root also preserves the observation and existing file
cursors. Non-default `CODEX_HOME` profiles use separate cache files so CLI and
desktop accounts cannot replace each other's weekly observations. The compact
per-model buckets do not retain every token event.

### Codex credits

`local-usage` and `status.localUsage` include `todayCredits`, with `estimatedCredits`,
`coveragePercent`, `pricedTokens`, `unpricedTokens`, `assumedStandardTokens` and
per-model amounts. `display` includes credit and coverage labels. The menu and MCP
use the same values. These are **local usage equivalents at the current purchased
credit rate card**, not actual deductions, included plan limits, or a fixed value
of the weekly allowance.

The [official credit rate card](https://help.openai.com/en/articles/11481834)
is independent of API pricing. The estimate excludes reported cache-write tokens
from the billable input categories and does not add a cache-write charge. Astra
keeps standard context rates in Codex; the published long-context tiers apply to
other eligible models. [Fast mode](https://learn.chatgpt.com/docs/agent-configuration/speed)
uses 2.5x credits for Astra, GPT-5.6 and GPT-5.5, and 2x for GPT-5.4. Mode changes
are read from each turn/settings event and persisted with the scanner cursor.
Missing mode or request-context records assume standard rates; missing mode token
counts are reported. Unrecognized modes stay unpriced. API equivalents continue
to use Standard API rates regardless of Codex mode.

The built-in rates were verified on 2026-09-11. Historical usage is re-estimated at
these rates, including current Daybreak aliases and Sol's purchased-credit
promotion; it is not a historical billing ledger. Tools, images, voice, regional
surcharges, cloud/other-device activity, and legacy Enterprise credit pricing are
not covered. Official balances come directly from `account/rateLimits/read` and
are never inferred from local token counts or subtracted by this app. Personal
plans generally use included allowances before deducting purchased credits.

These values are API-price equivalents, not ChatGPT subscription charges or an
actual bill. The weekly quota value is inferred as
`local cost since observation began * 100 / observed used-percentage change`;
activity on other devices or in cloud tasks can reduce its accuracy. Daily totals
span local homes; weekly observations only use the active `CODEX_HOME` (or
`~/.codex` by default) that supplies the official quota, so separate CLI and
desktop logins do not mix their costs. The source is included in `weeklyQuotaCost.source`. This
incremental approach avoids rescanning a full week of large session logs at
startup. Unknown model prices are exposed as partial coverage instead of
silently being treated as free.

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
make test         # run the Core unit tests
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

Reusable models, localization, formatting, Codex data access, and local JSONL
scanning live in `Sources/CodexRateLimitsCore`. The AppKit menu bar shell remains
in `Sources/CodexRateLimitsBar`, with Core behavior covered by `swift test`.

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
