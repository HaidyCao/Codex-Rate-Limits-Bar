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
  - Data source: `token_count` events in active and archived sessions under `~/.codex`, `~/.codex-cli`, and `CODEX_HOME` when configured. Session IDs and usage-event fingerprints deduplicate copies across filenames and directories; `CODEX_SESSIONS_DIR` explicitly selects one directory.
  - Session files are read incrementally with a reusable 1 MB buffer. Per-file identities, content fingerprints, cursors, daily baselines, and compact model cost buckets are persisted for up to eight days. Unchanged files reuse the cache; changed prefixes and relevant session copies trigger replay.
- The Usage card learns a range for the weekly quota's local API-equivalent USD value from timestamped quota reads and this Mac's usage. It requires at least three independent intervals, each lasting 30 minutes with a change of five percentage points, and shows sample confidence, interval count and observation span.
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

## Local Usage Cache and Rebuild

File identity includes the device, inode and change time. Before reading an
appended tail, the scanner verifies SHA-256 of the previously consumed bytes.
Same-size edits, atomic replacements and truncation/rewrite therefore invalidate
the affected statistics, including edits in the middle of a growing file.
Verified moves into archives transfer the cached entry without counting it twice.

Files with the same session ID share an event ledger during replay: matching
timestamps, cumulative usage and billing context count once; distinct branch
tails contribute their own increments. When a copy omits intermediate cumulative
samples, the smallest observed delta for the matching event is used. Different
session IDs remain separate even when filenames match. Existing fork-import and
midnight-baseline rules still apply. The ledger is temporary and is not persisted.

Daily and weekly contributions retain separate source ownership, so a copy in
another home cannot remove the active account's weekly usage. `topFiles` entries
include `sourceFiles` listing all known copies. If an unreadable or missing copy
prevents a safe replay, the affected group retains its previous totals and reports
an error; restoring the file allows the next refresh to recover. Missing legacy
entries with no current daily or weekly contribution can be retired safely.

Use **Rebuild Local Usage** in the menu or `CodexRateLimitsBar local-usage --rebuild`
to replay available session files modified within the retained eight-day range,
including today's logs. Rebuild recalculates tokens and price equivalents while
preserving the account and a still-valid weekly observation baseline. The first
upgrade also verifies retained files that lack identity metadata. Large histories
can take tens of seconds to rebuild; the menu scan runs in the background.

## Scan Completeness and Billing Assumptions

Local usage exposes three separate measures in the menu, CLI and MCP:

- `diagnostics.status` describes the scanned logs: `complete`, `empty` (no logs),
  `noUsage` (no usage events today), `partial` (some data could not be verified),
  or `unavailable` (no usable records could be verified). A valid zero-token
  event is distinct from missing or unreadable logs.
- API and credit `coveragePercent` describe prices for the tokens already
  counted. **100% price coverage does not imply a complete scan or billing record.**
- `billingAssumptions` reports missing mode/context token counts, the tokens
  whose API or credit price used a default, and `apiPercent`/`creditPercent`.
  These percentages use deduplicated observed tokens as the denominator; missing
  both fields does not double-count a token. Only rules affected by the missing
  field count toward assumed pricing (for example, Astra credits have no context tier).

All bounded JSONL records are parsed as JSON, including whitespace, escaped keys
and arbitrary field order. Reads use a reusable 1 MB buffer; a single record can
grow to 8 MB to accommodate large normal session and compaction records. Larger
records, malformed JSON, invalid usage fields and unfinished trailing records
produce diagnostics. Rate-limit-only updates are valid non-usage events.
Per-file diagnostic counters survive restarts. Old caches replay retained files
to recover records skipped by the previous parser, preserving valid observations.

Diagnostics cover the selected retained files and their cumulative baselines.
They include directory/read failures, missing files, parsing/skipped/pending
record counts, root availability and up to 50 path/reason entries, with an omitted
entry count. Optional default homes that have never existed are listed without
raising an error; an inaccessible directory or missing explicit
`CODEX_SESSIONS_DIR` is a failure. A disappearing directory retains cached totals.
File access recovery or repaired records are checked on the next refresh.

The menu shows incomplete statistics in orange with details in the tooltip;
unavailable totals display `--`. `status.localUsageError` carries the same error
as `localUsage.error`. Daily amounts remain estimates over available data.
Weekly amounts expose `scanStatus`, `billingAssumptions`, `inferencePauseReason`
and a structured `valuation`. Inference pauses for incomplete relevant scans;
intervals containing any unknown API price or assumed API billing condition are
excluded. Credit-only uncertainty caps sample confidence at medium. Recovery
preserves the valid observation baseline, but a value still needs enough clean
intervals. A failure in an unrelated home's independent session does not block
the active account's weekly estimate.

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

Prices and aliases now live in the bundled [pricing.json](Sources/CodexRateLimitsCore/Resources/pricing.json),
with separate API and credits versions, verification dates, sources and conditions.
The menu shows the active version and whether it is built-in or custom; its tooltip
includes verification dates, sources and the latest version transition. CLI/MCP
expose the same metadata in `localUsage.pricing` (or `pricing` on `local-usage`).
All retained usage is re-estimated at the current rates, not historical billing rates.

An optional `~/Library/Application Support/Codex Rate Limits Bar/pricing.json`
replaces the full built-in document; `CODEX_PRICING_FILE` selects another file.
Changes take effect at the next local refresh. Invalid configuration is rejected
with a visible error and built-in fallback. See [Price configuration](docs/pricing.md)
for export, validation, manual prices, aliases and independent credits mode rules.

`unpricedUsage` lists raw model/mode names, reasons, token counts and percentages,
separately for API and credits. The weekly estimate has its own scoped list.
Known amounts remain available when another request for the same model lacks a
price. Cyber's unpublished long-context API tier stays unpriced rather than using
a guessed multiplier. Unknown-price details persist across restarts. The first
upgrade replays retained cost-bearing files to recover these details and current
rules, preserving account baselines and timestamped quota evidence.

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

The built-in rates were verified on 2026-09-12. Historical usage is re-estimated at
these rates, including current Daybreak aliases and Sol's purchased-credit
promotion; it is not a historical billing ledger. Tools, images, voice, regional
surcharges, cloud/other-device activity, and legacy Enterprise credit pricing are
not covered. Official balances come directly from `account/rateLimits/read` and
are never inferred from local token counts or subtracted by this app. Personal
plans generally use included allowances before deducting purchased credits.

### Weekly quota valuation

Weekly values are **this Mac's API-price equivalents**, not subscription charges,
official credit deductions or an actual bill. Daily totals span local homes;
weekly observations use only the active `CODEX_HOME` (or `~/.codex` by default)
that supplies the official quota. `weeklyQuotaCost.source` identifies that scope.
Other devices and cloud tasks can consume the same quota without contributing
to the local cost numerator; even high sample confidence cannot establish their
cost or the full account's monetary allowance.

The estimator pairs official read timestamps with minute buckets of local usage
over the latest 24 hours. Reusing a cached quota read does not create a new sample
or add later costs to an earlier interval. Each nonoverlapping interval needs
at least 30 minutes and five percentage points of consumption; at least three
valid intervals are required before showing a value. This means at least
90 minutes and 15 percentage points of usable evidence, after initial alignment.

For each interval, the estimator applies `local API cost * 100 / percentage change`.
It uses a two-minute delay allowance and whole-minute cost bounds, plus ±1
percentage point for the difference between integer quota readings. The delay
allowance is a local modeling assumption, not a guaranteed server update delay.
The displayed range spans accepted interval bounds and rounds outward to avoid
false cent precision. It describes observed variation and modeled timing error;
it is **not a statistical confidence interval**.

Values begin at medium sample confidence. High requires at least six intervals,
a six-hour span, 30 percentage points, median relative deviation no greater than
10%, a range width no greater than 40% of the median estimate, and no excluded
intervals or uncertain credit conditions. An interval more than threefold from
the median is excluded; a newly outlying interval pauses the estimate. Remaining
deviation above 25% or range width above 85% also pauses it.

Unknown API prices block the affected interval even when their token share is
tiny; token coverage alone cannot bound the missing monetary cost. Missing
context that affects API pricing also blocks that interval. Conditions affecting
only credit prices are reported separately and cap confidence at medium.
Incomplete scans, unmatched quota consumption and exhausted quota produce a
pause reason. Samples older than five minutes cannot support a current value;
gaps longer than ten minutes or percentage regression restart the sample series.
Account or quota-window changes start separate evidence. Subsequent clean,
stable intervals can restore the estimate.

`weeklyQuotaCost.valuation` exposes `status` (`collecting`, `ready`, `paused` or
`unstable`), `confidence`, the estimate and bounds, sample/interval/rejection
counts, observation span, effective percentage change and sample timestamps.
`estimatedQuotaUSD` remains available for compatibility and is null until ready.
The menu, CLI and MCP use the same estimator and explanations.

The v4 cache gains optional minute totals and quota samples, without retaining
every usage event. Minute totals keep 24 hours plus the alignment boundary;
quota samples keep at most 24 hours and 1,500 entries. Upgrading preserves the
existing account, weekly observation start and baseline percentage; timed
evidence begins at upgrade because earlier samples cannot be reconstructed from
aggregate costs. Restarting, rebuilding or repricing preserves those samples
and recalculates affected local costs. No full-week startup replay is required.

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

For isolated regression checks:

```sh
make verify             # Swift, CLI/MCP, actual AppKit views, relocated app resources
make verify-local-usage # CLI/MCP fixtures only
make benchmark          # Synthetic 256 MiB log; no real sessions
make verify-live        # Explicit opt-in: query the current real Codex account
dist/Codex\ Rate\ Limits\ Bar.app/Contents/MacOS/CodexRateLimitsBar local-usage
dist/Codex\ Rate\ Limits\ Bar.app/Contents/MacOS/CodexRateLimitsBar status
```

Default verification runs with temporary credentials, caches and logs, and blocks
network access for test processes. Artifacts are saved to `.build/verification/`.
See [verification commands and coverage](docs/verification.md) for CI commands,
performance measurements, and manual checks.

## Freshness and refresh recovery

Quota, official balance, reset credits, and local usage show separate update
states and timestamps. Official data becomes stale after five minutes and local
usage after two. Failed requests retain and dim old values; stale quota pauses
forecasts, and stale quota or local usage pauses weekly amount estimates.
Unrelated refreshes do not clear another source's error.

Wake and network recovery trigger refreshes. Concurrent requests coalesce,
failures use bounded exponential backoff, and manual refresh remains available.
Account changes and timed-out requests cannot apply late results. CLI/MCP
snapshots expose additive `refresh` / `freshness` metadata; their history is
limited to each invocation. See [refresh behavior and verification](docs/refresh.md)
for timings, field definitions, and manual system-event checks.

## Shared Swift Binary

Reusable models, localization, data access, local JSONL scanning, and refresh
control live in `Sources/CodexRateLimitsCore`. `CodexBackend` is the shared facade;
official clients, cache storage, CLI/MCP and refresh orchestration have separate
implementations. The AppKit shell lives in `Sources/CodexRateLimitsBar`:
`AppDelegate.swift` connects the menu to the controller, `RefreshEventMonitor.swift`
forwards system events, and each menu card has its own view file. `main.swift`
is the startup entry. The verification executable compiles those same views
against CLI/MCP fixtures. See [module boundaries](docs/architecture.md) and the
[staged refactoring plan](docs/refactoring-plan.md).

The executable supports several command-line modes in addition to the menu bar
app:

```sh
CodexRateLimitsBar status
CodexRateLimitsBar rate-limits
CodexRateLimitsBar local-usage
CodexRateLimitsBar local-usage --rebuild
CodexRateLimitsBar pricing
CodexRateLimitsBar pricing --export-builtin
CodexRateLimitsBar pricing --validate /path/to/pricing.json
CodexRateLimitsBar reset-credits
CodexRateLimitsBar usage
CodexRateLimitsBar mcp
```

The local `codex-usage-monitor` plugin is bundled under
`plugins/codex-usage-monitor` and launches the installed app binary with `mcp`,
so the status bar and Codex plugin share the same Swift data path after install.
No JavaScript helper is copied into the app or plugin.
