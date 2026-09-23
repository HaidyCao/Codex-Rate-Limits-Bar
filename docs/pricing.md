# Price configuration

The app estimates local API and purchased-credit equivalents at the **current
configured rates**. Changing a rate can therefore change the amount shown for
earlier usage. Official balances and quota percentages still come from Codex;
the app never recalculates or deducts them from local token counts.

## Select and validate a configuration

The built-in document is [pricing.json](../Sources/CodexRateLimitsCore/Resources/pricing.json).
It ships inside the signed app's Swift resource bundle. A custom file replaces
the **entire document**, including both cards; it is not a partial overlay.
Start by exporting the built-in document and editing a copy:

```sh
"$HOME/Applications/Codex Rate Limits Bar.app/Contents/MacOS/CodexRateLimitsBar" pricing --export-builtin > /tmp/codex-pricing.json
# Edit /tmp/codex-pricing.json, including version, verifiedAt and conditions.
"$HOME/Applications/Codex Rate Limits Bar.app/Contents/MacOS/CodexRateLimitsBar" pricing --validate /tmp/codex-pricing.json
```

Validation returns metadata on success and a nonzero exit status with an error
on failure. Once valid, place the document at
`~/Library/Application Support/Codex Rate Limits Bar/pricing.json`. Keep a copy
of your previous custom file when updating it. For a separate CLI configuration:

```sh
CODEX_PRICING_FILE=/tmp/codex-pricing.json \
  "$HOME/Applications/Codex Rate Limits Bar.app/Contents/MacOS/CodexRateLimitsBar" local-usage
```

The desktop app uses its own launch environment, so exporting a variable in a
terminal does not change an already-running app. The default file path is shared
by the desktop and CLI. `pricing` prints active metadata; `pricing --export`
prints the effective complete document. These commands do not change files,
query the account or refresh session statistics.

Each scan loads and validates the configuration once, then uses that immutable
document through reading, deduplication, aggregation and weekly valuation. The
next local refresh picks up edits without an app restart. A missing optional
default file selects built-in rates. A missing explicitly selected file,
unreadable file, invalid value or unsupported schema produces
`pricing.configurationError` and a visible warning, then uses built-in rates.
Repairing the file clears the warning on the next refresh. No remote price
updates are downloaded automatically.

## Document and model rules

`schemaVersion` is `1`. Both `api` and `credits` contain:

| Field | Meaning |
| --- | --- |
| `version` | Human-readable revision; update it when changing your configuration. |
| `verifiedAt` | Valid `YYYY-MM-DD` date. Custom dates are user-declared. |
| `sources` | Nonempty HTTP(S) source URL list; custom sources are user-declared. |
| `conditions` | Nonempty descriptions of units, assumptions and applicability. |
| `models` | Exact canonical model names mapped to rates. |
| `aliases` | Explicit alias-to-model mappings for this card. |

A rate has required `input`, `cachedInput`, `cacheWriteInput`, `output` and
`datedSnapshots` fields. All prices are per **1 million tokens**, in USD for API
and credits for the credits card. Rates must be finite, nonnegative and at most
1 billion per million tokens. Zero is an explicit zero price; an absent model
has no price. Model and alias keys must be lowercase, without outer whitespace
or control characters. Raw names in logs remain visible alongside their resolved
`canonicalModel`; lookup ignores case and outer whitespace.

Optional `contextTier` specifies a positive `threshold`, `inputMultiplier` and
`outputMultiplier`; the tier applies to the whole request when its recorded input
exceeds the threshold. The input multiplier also applies to cached and cache-write
input. Optional `maximumInputTokens` caps the **known pricing coverage**, not the
model's technical context capacity. Above it, the request stays unpriced. If
both fields exist, the maximum must exceed the tier threshold. Missing context
uses the ordinary rate and is marked as an assumption when it can affect pricing.

API amounts deliberately use Standard rates, so API entries reject
`serviceTiers`. Credits entries require `serviceTiers.standard = 1`; their other
keys map exact mode names to positive multipliers. Missing mode uses `standard`
and is labeled as an assumption. An unlisted mode remains unpriced. A manual
mode such as `"private-mode": 3` can be added explicitly to a credits model.
Multipliers must be finite, positive and at most 1,000.

For example, add this entry under `api.models` in your exported document:

```json
"my-private-model": {
  "input": 2,
  "cachedInput": 0.2,
  "cacheWriteInput": 2.5,
  "output": 12,
  "datedSnapshots": false
}
```

Add `"my-private-alias": "my-private-model"` under `api.aliases` to map a log name
explicitly. Credits has its **own** models and aliases; an API mapping never
implicitly establishes a credit price. A credits-only model is also allowed.
Aliases must point directly to a model in the same card; chains, cycles, missing
targets and shadowing a canonical model are rejected. When `datedSnapshots` is
true, a `-YYYY-MM-DD` suffix may resolve through an explicit base/alias. Other
suffixes, including Pro and Spark, never inherit a price by prefix matching.

The document is limited to 1 MB, with at most 1,000 models and 1,000 aliases per
card. Duplicate keys and misspelled or unknown structural fields are rejected instead of ignored.
Supported model rates remain independent: API cache writes may have a charge,
while the built-in credits card uses zero. The API cards for GPT-6 Sol and Luna
apply 2x input/cache and 1.5x output rates above 272K request input tokens. The
Codex credit card publishes one Standard token rate for GPT-6 Astra, Sol and Luna;
no long-context credit multiplier is published for those models. Cyber's API
table has no published long-context rate, so its pricing coverage ends at 272K
request input tokens. Those rules are visible in the data.

## Repricing and unknown usage

`pricing` metadata records the active document fingerprint, separate card
versions/dates/sources, built-in or custom origin, and `basis: "current-rates"`.
The persisted scan cache records the preceding fingerprint/versions and the
latest change time. A content edit is detected even if the author forgets to
change the version. The app retains the latest transition, not a historical
billing ledger; archive custom documents yourself for a full audit trail.

Per-model effective signatures include the resolved model and calculation rules.
Changed prices, context limits, credit modes and alias targets replay affected
retained files, including weekly minute costs. Editing only version, verification
date or source text updates metadata without replaying unchanged prices. Account
baselines and official weekly sample timestamps survive repricing and rebuilds.
Logs that cannot be replayed keep their token totals and report stale/unpriced
amounts until restored. An unsupported request does not cause repeated full scans.

`unpricedUsage` contains one aggregate per API/credits kind, raw model, raw mode
and reason. Each entry has `totalTokens` and `percent`, relative to all observed
tokens in its scope. API and credits are independent views of the same tokens;
do not add their percentages together. The daily list covers local homes, while
`weeklyQuotaCost.unpricedUsage` covers the active weekly observation. Reasons are
`unknownModel`, `unknownServiceTier`, `unsupportedContext`,
`incompleteTokenBreakdown` and `stalePricing`.
The UI tooltip, CLI and MCP expose the same details. Known-price requests retain
their amounts even if another request for the same model is unpriced.

Token totals remain visible when billing components are missing or inconsistent.
Pricing requires input plus output to equal the total, cached/cache-write input
to fit within input, and reasoning output to fit within output. Omitted zero
components remain supported when those checks hold. A delta is unpriced if
either cumulative endpoint fails these checks, even if its own counters balance.
Fully unpriced usage shows `--` and 0% pricing coverage; a confirmed zero total
still shows zero. Scan completeness reports whether logs were read, independently
of pricing coverage. Weekly valuation excludes intervals containing unpriced tokens.
When breakdowns are incomplete, the menu's component cards and cache-hit rate
show `--`. CLI/MCP retain numeric component counters for compatibility; inspect
`unpricedUsage` before treating those counters as a complete breakdown.

The calculation revision replays existing v4 caches without resetting valid
account baselines or official weekly samples. Missing component information is
never reconstructed using the current request's input count or model price.
The first upgrade scans retained logs again. Concurrent CLI reads can reach the
15-second cache-lock timeout while that scan is running; retry after it finishes.
Subsequent reads reuse the upgraded cache.

### Cumulative counter corrections

A session's cumulative baseline keeps one recorded sample at the greatest total
seen so far. A newer sample at the same total can correct the baseline. A lower
total cannot change any of its components. Taking a separate maximum for input,
output and cached tokens would combine unrelated samples and could make later
valid requests look incomplete.

For example, `(input, output, total)` can change from `(1000, 100, 1100)` to
`(1200, 50, 1250)`. The 150-token transition has no reliable component breakdown
and remains unpriced. The next sample `(1300, 60, 1360)` adds 100 input and 10
output tokens, which can be priced normally. Cached, cache-write and reasoning
counter regressions also make the transition uncertain; `last_token_usage` is
not substituted for a cumulative delta.

Weekly intervals containing these transitions use reason
`incompleteTokenBreakdown` and show the corresponding explanation. Other
unpriced intervals keep `unpricedUsage` with a general unpriced-usage label;
neither code implies that every affected model is absent from the price table.
Clean later intervals can qualify for valuation independently.

File diagnostics revision 3 replays old cumulative baselines and minute costs
once. Cache documents remain v4; prices, account baselines and official quota
sample timestamps are unchanged by the migration.

## Sources

The built-in card cites [OpenAI API pricing](https://developers.openai.com/api/docs/pricing),
the [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol) and
[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) model pages,
the [Codex pricing page](https://learn.chatgpt.com/docs/pricing), and
[Codex speed modes](https://learn.chatgpt.com/docs/agent-configuration/speed).
API and credits use different rules and remain separate from official balances.
