# Price configuration

The app estimates local API and purchased-credit equivalents at the **current
configured rates**. Changing a rate can therefore change the amount shown for
earlier usage. Official balances and quota percentages still come from Codex;
the app never recalculates or deducts them from local token counts.

## Policy review (2026-10-06)

The review started against commit `7c79417`. API card `2026-10-06.1` adds
GPT-6.1 Sol; credits card `2026-10-06.3` includes the corrected speed rates and
conservative accounting coverage from TODO-19. Price schema v1 gains one optional
credits field; cache v4 and Standard API-equivalent semantics remain unchanged.
TODO-20 clarifies scope and display; its card revision changes only metadata.
TODO-21/22 add maintenance and client verification. TODO-23's
[extension assessment](billing-extensions.md) keeps historical valuation and
official API costs conditional and separate from existing estimates. API card
`2026-10-06.2` corrects older-model cache writes in [TODO-24](#legacy-api-cache-writes-todo-24).
API card `2026-10-07.1` then adds the model-specific Cyber long-context rule
in [TODO-25](#cyber-api-long-context-todo-25); the credits card is unchanged.

[OpenAI's changelog](https://developers.openai.com/api/docs/changelog) records the
GPT-6.1 Sol release on September 29. The
[model page](https://developers.openai.com/api/docs/models/gpt-6.1-sol) establishes
these Standard API prices per million tokens:

| Request input size | Input | Cached input | Cache writes | Output |
| --- | --- | --- | --- | --- |
| Up to 272,000 tokens | $2 | $0.10 | $2.50 | $10 |
| More than 272,000 tokens | $4 | $0.20 | $5 | $15 |

The long-context tier applies to the full request. Fast API prices are twice
Standard; Batch/Flex are half Standard, with regional premiums where applicable.
The project's API column continues to mean **Standard equivalent**, excluding
those processing adjustments, Ultrafast, and tool fees. A new actual-API-bill
view would require separate scope and reliable request metadata.

Amount labels normalize to ten decimal places before their existing two-decimal
rounding, so insignificant floating-point summation differences do not flip a
cent midpoint between CLI/MCP/UI processes. This affects display only; raw JSON
estimates, tiny-positive-value labels and cached calculations retain their values.

The [Codex/Work token table](https://learn.chatgpt.com/docs/pricing) publishes
GPT-6.1 Sol Standard credits of **50 input / 2.5 cached input / 250 output** per
million tokens. It does not publish a separate cache-write charge or a
GPT-6.1 Sol long-context multiplier. API-key use follows API pricing; Enterprise
USD agreements and legacy Enterprise pricing require their own applicable card.
Local credits remain an equivalent, not evidence of a deduction.

The [speed policy](https://learn.chatgpt.com/docs/agent-configuration/speed)
distinguishes two different multipliers:

| Mode | Purchased credits / eligible Enterprise usage | Included subscription limits |
| --- | --- | --- |
| Fast, where supported | 2x | 2.5x |
| GPT-6 Astra Ultrafast | 6x | 8x |

GPT-6.1 Sol currently documents Standard/Fast support. Do not infer its Ultrafast
price or invent aliases/snapshots. Keep unsupported combinations unpriced.
The previous card used 2.5x for several models' Fast credit equivalents,
overstating that component by 25% relative to 2x. The new card uses 2x and adds
Astra `ultrafast` at 6x. Explicit `priority` entries preserve compatibility with
the former Fast mode name. GPT-6.1 Sol does not enable inferred dated snapshots.

### Credit accounting coverage (TODO-19)

The [Business/Enterprise credit card](https://help.openai.com/en/articles/11481834-chatgpt-rate-card-business-enterpriseedu-credit-based-pricing)
says Codex has no cache-write charge. The
[Codex/Work pricing page](https://learn.chatgpt.com/docs/pricing) says there is no
separate charge. Neither establishes how a reported `cache_write_input_tokens`
counter maps to the billable input category. The
[API formula](https://developers.openai.com/api/docs/guides/prompt-caching)
uses exclusive ordinary-input, cached-input and write-input categories; that is
API evidence, not proof of the Codex rollout counters or credit ledger.

An offline export from the installed `@openai/codex` **0.160.0** confirms that
`ThreadTokenUsageUpdatedNotification.TokenUsageBreakdown` has an optional
`cacheWriteInputTokens` integer with default 0, alongside required input/cached/
output counters. It supplies no inclusion or billing formula. Reproduce with
`python3 Tests/Support/run_isolated.py codex app-server generate-json-schema --out /tmp/codex-credit-schema`.
This app-server schema is supporting evidence for an omitted counter, not a
verified specification for every historical snake_case rollout format.

The parser retains its existing counter contract: `input_tokens` includes the
cached/write subsets, and input plus output equals total. Contradictory counters
remain `incompleteTokenBreakdown` for both estimates. No public Codex counter-to-
credit specification was established in this review, so the built-in credit card
now opts out of pricing a whole usage delta with positive reported writes:
`unverifiedCacheWrite`. Tokens, API estimates, and other priced requests remain.
An omitted write field is still treated as zero **reported** writes for backward
compatibility; it does not prove no server-side cache write occurred.

The current credit pages publish no model-specific long-context multiplier for
the following retained groups. API tiers cannot fill that gap:

| Models | API coverage | Built-in credit coverage pending evidence |
| --- | --- | --- |
| GPT-6 Astra/Sol/Luna, GPT-6.1 Sol | Published 2x input/cache, 1.5x output above 272K | Up to 272K known request input |
| GPT-5.6 Sol/Terra/Luna, GPT-5.5, GPT-5.4 | Published long-context API tiers | Up to 272K; previous borrowed multipliers removed |
| GPT-5.6 Cyber / Daybreak Red | Model-page 2x input/cache, 1.5x output above 272K; see source discrepancy below | Up to 272K |
| GPT-5.4 mini, GPT-5.3-Codex, GPT-5.2 | Existing Standard API rules | Existing Standard credit rules retained |

API rules are sourced from [API pricing](https://developers.openai.com/api/docs/pricing)
and the linked model pages. Credit rates/applicability are from the two credit
pages above; retired model rows retain their earlier configured base rates.
**272K is this project's conservative coverage guard**, chosen where the API
introduces a distinct context tier. It is not an official Codex credit threshold,
a technical limit, or proof that shorter/longer contexts are exempt forever.
Above it, credits report `unsupportedContext`; missing request context keeps the
Standard estimate and contributes to `billingAssumptions.assumedCreditTokens`.
Future evidence should update the card and replay affected logs.

TODO-19 did not change API write rates; [TODO-24](#legacy-api-cache-writes-todo-24)
subsequently corrects GPT-5.5/5.4. Client counter evidence remains separate;
lack of a write counter cannot establish an exact API bill either.

### Legacy API cache writes (TODO-24)

Reviewed on 2026-10-06 against the [prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
and the exact [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5) and
[GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4) model pages.
Models before GPT-5.6 have no extra cache-write charge. Under this project's
exclusive input categories, their reported writes use the **ordinary input
rate**, not zero or the newer models' premium:

`API input USD = ((input - cached - writes) × inputRate + cached × cachedRate + writes × inputRate) / 1,000,000`

Thus the result is independent of how the non-cached input is split into
ordinary and written tokens. Invalid/overlapping counters remain unpriced.
The two corrected rows are GPT-5.5 **$6.25 → $5** and GPT-5.4 **$3.125 → $2.50**
per million written tokens. The other 11 retained pre-5.6 entries already have
write rates equal to their input rates; this checks their write policy, not a
fresh verification of every historical base price. All eight retained 5.6+
entries keep their explicit premium. No name-prefix fallback is introduced.

| Independent sample | GPT-5.5 API USD | GPT-5.4 API USD |
| --- | --- | --- |
| 100K input, all written; no output | 0.50 (was 0.625) | 0.25 (was 0.3125) |
| 100K input: 40K cached, 20K written; 5K output | 0.47 (was 0.495) | 0.235 (was 0.2475) |
| Same cached/write/output counts, 272K request input | 1.33 | 0.665 |
| Same cached/write/output counts, 272,001 request input | 2.58501 | 1.292505 |

The existing 2x input/cache and 1.5x output tier remains above 272K. Output
already includes reasoning tokens. Zero-write and cached-read-only amounts are
unchanged. Purchased credits still report positive writes as
`unverifiedCacheWrite`; this API correction does not resolve Codex deductions.

Only the API card changes to `2026-10-06.2`; credits stays `2026-10-06.3`.
Schema v1, outer cache v4 and calculation revision `pricing-v4` remain intact.
Only GPT-5.5/5.4 model signatures change: available affected logs replay under
the current card, including weekly minute costs. Tokens, account baselines and
official samples survive. Missing logs report `stalePricing` until restored;
rollback uses the same replay mechanism. Explicit custom prices keep their
configured values, and `pricing --health` reports their differences read-only.

During this audit, the [Cyber model page](https://developers.openai.com/api/docs/models/gpt-5.6-cyber)
also established an API tier above 272K. TODO-24 left the Cyber card's 272K
coverage guard in place; the following update closes that implementation gap.

### Cyber API long context (TODO-25)

Reviewed on 2026-10-07. The [Cyber model page](https://developers.openai.com/api/docs/models/gpt-5.6-cyber)
explicitly applies 2x input and 1.5x output prices to the entire request above
272K input tokens. It also prices cache writes at 1.25x uncached input.
However, the [general pricing table](https://developers.openai.com/api/docs/pricing)
still shows dashes in Cyber's long-context cells. This app follows the explicit
model-specific rule for its Standard API equivalent; the two sources are not
fully aligned, and this is not invoice verification. With the existing cached
read and write rules, the resulting rates per million tokens are:

| Request input | Ordinary input | Cache reads | Cache writes | Output |
| --- | --- | --- | --- | --- |
| Up to 272,000 | $12.50 | $1.25 | $15.625 | $75 |
| Above 272,000 | $25 | $2.50 | $31.25 | $112.50 |

The [Daybreak Red model page](https://developers.openai.com/api/docs/models/gpt-daybreak-red-latest)
marks it deprecated and maps it to Cyber. The existing exact alias
`gpt-daybreak-red-latest` remains supported for historical logs. No new aliases,
prefix matching, or dated-snapshot permissions are introduced.

For 80K cached input, 20K writes and 5K output (including 4K reasoning), request
input of 272,000 / 272,001 / 400,000 yields $2.9375 / $5.687525 / $8.8875.
Ordinary input is input minus reads and writes; reasoning is already in output.
The last request's input selects the tier, independently of the cumulative
counter delta. Missing request context retains the base rate and an assumption.
Purchased credits remain separate: positive reported writes are
`unverifiedCacheWrite`; otherwise known input above 272K is `unsupportedContext`.

Only the API card advances to `2026-10-07.1`; credits stays `2026-10-06.3`.
Schema v1, cache v4 and calculation revision `pricing-v4` are unchanged.
Cyber and its configured alias change signatures; retained affected logs replay,
including previously unpriced API usage and weekly minute costs. Tokens,
account baselines and official observations survive upgrades and rollback.
Missing history stays `stalePricing` until restored. A custom 272K cap remains
valid; `pricing --health` reports differences without altering or activating it.

### Maintenance and compatibility decisions

- Reuse schema v1 and per-model signatures for the first rate update. Reprice
  retained files and weekly minute costs while preserving tokens, account
  baselines, and official observations. Missing source logs remain unpriced.
- A valid custom card replaces the whole bundle and may remain outdated after an
  app upgrade. Use `pricing --health` for a read-only comparison; never silently
  overwrite custom rates.
- Keep current-rate valuation explicit. The
  [API pricing page](https://developers.openai.com/api/docs/pricing) guarantees the
  GPT-5.6 Sol promotion at least through November 21, 2026; that is a review date,
  not proof of a higher price on November 22.
- [GPT-5.5 retirement](https://learn.chatgpt.com/docs/agent-configuration/speed#retirement-and-migration)
  on October 14 concerns ChatGPT/Work/Codex, not the API. Retain historical model
  entries. Contract fixtures should also cover Pro's absent five-hour window,
  documented on the [pricing page](https://learn.chatgpt.com/docs/pricing).

The review baseline passed 29 pricing tests but reproduced missing GPT-6.1 Sol
prices, the old Fast multiplier, and unpriced Astra Ultrafast credits. New
regressions check independent amounts, context boundaries, unknown variants,
mode changes, and old-cache repricing across restart, rebuild, and rollback.
The implementation results and release gates are recorded in the TODO.

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

### Read-only health report

```sh
CodexRateLimitsBar pricing --health
CodexRateLimitsBar pricing --health /tmp/codex-pricing.json
```

Without a file, inspect the effective card selected by the normal configuration
rules. With a file, validate and compare that candidate without activating it.
Both commands read only local price data: no account requests, session scan,
cache writes, network lookup or configuration edits. The baseline is the bundled
card, not a live assertion that OpenAI's prices have remained unchanged.

The JSON report has its own `schemaVersion: 1`; existing pricing/status/MCP
contracts are unchanged. `active` and `builtin` contain both cards' metadata.
`configurationStatus: valid` includes intentional custom prices; `fallback`
means the selected configuration failed validation and the app uses bundled
rates, with the original `active.configurationError` preserved. Candidate errors
return nonzero with stderr. A valid report, including coverage warnings or a
reported active fallback, returns zero; scripts should inspect its fields.

Each `api`/`credits` comparison lists `missingModels`, `missingAliases`,
`missingServiceTiers`, additional models/aliases, `resolutionDifferences` and
`rateDifferences` containing both complete rules. Missing names use actual
lookup: explicit aliases can supply a model name, and direct model entries can
supply an alias. No prefix guessing or automatic merging occurs. Rate differences
include context limits, write uncertainty and dated-snapshot rules; a changed
target is reported even if its prices match. A changed rule can appear for both
its canonical name and affected aliases. `coverageReviewRecommended` signals
missing names/modes only; intentional price/policy differences remain available
for review and never become configuration errors.

`builtinPolicyReviews` describes the **bundled baseline**, including when a
custom contract is active. Review its applicability to that contract yourself.
It distinguishes these dates:

| Field | Meaning |
| --- | --- |
| Card/notice `verifiedAt` | Declared source review date, not a validity period or proof that every historical row was freshly reverified. |
| `suggestedReviewOn` | Maintainer reminder; `reviewDue` becomes true on this UTC date. |
| `announcedProductChangeOn` | Documented availability event with explicit product scope. |
| `priceEffectiveOn` / `priceExpiresOn` | Actual published price boundaries; omitted when not established. |

The October 14 GPT-5.5 notice records product retirement, with no API price
expiry. November 21 is a suggested review of GPT-5.6 Sol's minimum promotional
duration, with neither a price expiry nor a replacement rate. Passing either
date changes only diagnostics. Rates, fingerprints, model entries, current-rate
valuation and cached statistics remain unchanged. These notices are compiled
into the app and require a reviewed release to update; custom `verifiedAt` dates
do not suppress or reschedule them.

## Release maintenance checklist

Network research is a manual maintenance step. `make verify` remains offline and
tests the committed policy; a passing run cannot establish current online prices.

1. Export both the previous built-in card and any custom card before editing.
   Record the app revision, API/credits versions and a rollback location. Inspect
   `pricing --health` and every existing coverage/policy difference.
2. Open official model, API pricing and credit/speed sources separately. Record
   exact model IDs, aliases, supported modes, units, input/write semantics,
   context rules, product/contract scope and verification date. Record omissions
   and conflicts explicitly. Do not infer a missing credit price from API USD.
3. Use the inventory below to account for every retained model; check the two
   aliases lists independently. Historical rows stay until a deliberate
   compatibility decision, even after product retirement. Legacy rate and
   cache-write evidence gaps need explicit release review, not a blanket claim
   that all rows were reverified.
4. Update `pricing.json`, relevant `PricingHealth` notices, this record and
   independent `PricingReleaseTests` expectations together. Update only the
   affected card versions. Put published effective/expiry dates in the policy
   record only when established; review reminders must not schedule price changes.
5. Run isolated pricing tests, then preserve the committed card and its review
   using the [archive procedure](pricing-archive/README.md#add-a-reviewed-configuration).
   Run `make verify` with the matching archive. For rate/calculation/cache
   changes also run the scanner migration/restart/rebuild/rollback cases and
   `make benchmark BENCHMARK_MIB=256`; confirm official observations survive.
   Inspect menu renders if presentation changes. Never regenerate expected
   amounts from the card being tested.
6. Review the final card diff and candidate `pricing --health FILE`. Include
   unresolved source gaps and rollback instructions in the release notes. Do not
   replace users' custom cards automatically. Retained logs reprice at the newly
   configured rates; unavailable logs remain `stalePricing`.

### Recorded mode and client contract

The [app-server documentation](https://learn.chatgpt.com/docs/app-server) describes
token updates for the active thread. The installed CLI **0.160.0** schema has
`threadId`, `turnId` and `tokenUsage` on that notification, with no actual service
tier. `turn/start.serviceTier` and `serviceTierForTurn` are request overrides;
their existence does not prove the response's actual billing tier. Local rollout
projections also lack a tier. Evidence and provenance are in
[client contract verification](verification.md#客户端与套餐契约样例todo-22).

For the supported rollout fields, selection remains: token `info` mode, token
payload mode, then the current recorded context. At each level `service_tier`
precedes `serviceTier`, followed by existing nested settings. A full
`turn_context` replaces model/mode, including an omitted mode; a sparse
`thread_settings_applied` changes the tier only when present, and explicit null
clears that setting. A null token-level value supplies no override, so lookup
continues to the enclosing context. Unknown requested/actual-tier key names
are not interpreted. A missing resolved mode uses the configured Standard
credit estimate and contributes to `missingServiceTierTokens` and
`assumedCreditTokens`; a present mode remains recorded-setting evidence, not a
claim of actual billing. The existing fields retain these meanings.

The [plan policy](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan)
currently describes Pro without a five-hour limit. The app nevertheless derives
weekly availability solely from returned 10,080-minute windows in either lane,
selecting the `codex` snapshot when available. Plan names never create windows or
balances. Confirmed zero credits, missing data and API-key request failures remain
distinct, and local equivalents remain usable independently.

### Model and mode inventory with independent examples

For every row below, the sample has 100,000 input tokens including 80,000 cached
tokens, zero reported writes, 5,000 output tokens and a known 100,000-token
request context. It therefore prices **20,000 ordinary + 80,000 cached + 5,000
output** tokens. API uses Standard throughout. S/F/U denote purchased-credit
Standard/Fast/Ultrafast; `default` is the explicit S name and `priority` the
explicit F name retained by this card. A dash is unpriced, not zero.

| Exact models | API USD sample | Standard credits sample | Credit modes | Evidence/review |
| --- | ---: | ---: | --- | --- |
| `gpt-6-astra` | 0.53 | 13.25 | S/F/U | API/model + credit/speed sources, reviewed 2026-10-06 |
| `gpt-6.1-sol` | 0.098 | 2.45 | S/F | Same, reviewed 2026-10-06; no inferred dated snapshots |
| `gpt-6-sol` | 0.106 | 2.65 | S/F | Model + credit/speed sources, reviewed 2026-10-06 |
| `gpt-6-luna` | 0.0053 | 0.1325 | S/F | Same, reviewed 2026-10-06 |
| `gpt-5.6-sol` | 0.212 | 5.3 | S/F | API + credit/speed sources; promotion reviewed 2026-10-06 |
| `gpt-5.6-terra` | 0.116 | 2.9 | S/F | Retained API base; credit/speed review 2026-10-06 |
| `gpt-5.6-luna` | 0.0116 | 0.29 | S/F | Same |
| `gpt-5.6-cyber` | 0.725 | 18.125 | S | API tier reviewed 2026-10-07; credit Daybreak Red review 2026-10-06 |
| `gpt-5.5` | 0.29 | 7.25 | S/F | Retained API base; credit/retirement review 2026-10-06 |
| `gpt-5.4` | 0.145 | 3.625 | S/F | Retained historical base and explicit modes |
| `gpt-5.4-mini` | 0.0435 | 1.09 | S | Retained historical base; credit output is 113/M, not an API conversion |
| `gpt-5.3-codex`, `gpt-5.2` | 0.119 | 2.975 | S | Retained historical base |
| `gpt-5.3-chat-latest`, `gpt-5.2-codex`, `gpt-5.2-chat-latest` | 0.119 | — | — | Retained API-only base |
| `gpt-5.1-codex-max`, `gpt-5.1-codex`, `gpt-5-codex`, `gpt-5` | 0.085 | — | — | Retained API-only base |
| `gpt-5.1-codex-mini` | 0.017 | — | — | Retained API-only base |

Sources: [API pricing](https://developers.openai.com/api/docs/pricing),
[GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol),
[credit table](https://learn.chatgpt.com/docs/pricing) and
[speed/retirement policy](https://learn.chatgpt.com/docs/agent-configuration/speed).
The complete card contains 21 API models, 13 credit models and four aliases per
card. Historical-base rows are carried from commit `7c79417`, card
`2026-09-23.1`; the 2026-10-06 date is not a new independent verification of all
their base prices. The GPT-5.5/5.4 write correction and independent write examples
are recorded in [TODO-24](#legacy-api-cache-writes-todo-24). Credit write and long
context gaps remain covered by [explicit guards](#credit-accounting-coverage-todo-19).

For GPT-6.1 Sol, the independent calculations are
`0.02 × $2 + 0.08 × $0.10 + 0.005 × $10 = $0.098` and
`0.02 × 50 + 0.08 × 2.5 + 0.005 × 250 = 2.45 credits`.
Its Fast result is **4.9 credits**; Astra Ultrafast is **79.5 credits**.
[PricingReleaseTests](../Tests/CodexRateLimitsCoreTests/PricingReleaseTests.swift)
locks the independent amounts and complete model/mode inventory offline.
Other pricing/accounting tests cover writes, unknown modes and context boundaries.

### Policy revisions and rollback

| Card revision | Change | Rollback consideration |
| --- | --- | --- |
| API/credits `2026-09-23.1` (`7c79417`) | Previous GPT-6 Sol/Luna baseline | Lacks 6.1 and retains older Fast assumptions. |
| API/credits `2026-10-06.1` | Add 6.1; credits Fast 2x and Astra Ultrafast 6x | Restoring old rates revalues retained history; tokens/official samples stay. |
| Credits `2026-10-06.2` | Guard unverified writes and long contexts; calculation `pricing-v4` | Older app binaries reject the new optional field; restore the saved compatible custom file with the old app. |
| Credits `2026-10-06.3` | Clarify estimate scope and contract exclusions only | Metadata-only change; no price replay required. |
| TODO-21 diagnostics | Read-only comparisons, date reminders, release examples | No card, schema or calculation-signature change. |
| API `2026-10-06.2` / TODO-24 | GPT-5.5/5.4 writes use ordinary input rates | Replay affected retained logs in either direction; missing logs stay stale. Credits card unchanged. |
| API `2026-10-07.1` / TODO-25 | Cyber long-context tier follows its model page; general table still blank | Replay Cyber/Daybreak Red logs in either direction; preserve official observations and custom caps. Credits unchanged. |

Preserve the previous app and custom card together. Do not delete caches to force
a rollback: per-model signatures replay available history in either direction.
Never remove an uncertainty guard solely to make a new card parse in an older
app; that changes its accounting meaning. Add the actual release commit to this
record when changes are committed. TODO-17 through TODO-21 were committed together
as `f8c9368`; the intermediate October card revisions above document development
steps, not separate published releases. The baseline before TODO-17 was
`2026-09-23.1` at `7c79417`; before TODO-24 it was API `2026-10-06.1` and
credits `2026-10-06.3` at `32a0f75`. Before TODO-25 it was API `2026-10-06.2`
and credits `2026-10-06.3` at `3e98529`.

### Repository archive (TODO-26)

TODO-25 was committed as `d5248e6`. The [price archive](pricing-archive/README.md)
preserves five complete committed configurations, including that revision,
with byte hashes, exact Git provenance and summaries of existing reviews.
It distinguishes configuration records from reviewed subsets. Both products'
official effective periods remain unknown; `verifiedAt` is never promoted to a
billing start date. Intermediate uncommitted revisions are not reconstructed.

`make verify-pricing-archive` checks the independent manifest and source resource
offline; `make verify-pricing` also validates every archived card with the current
Swift parser and compares the built-in export. These checks neither fetch prices
nor establish whether a policy is still current. The app does not read the archive,
and current-rate calculations, custom configuration, price schema and cache
compatibility are unchanged. Follow the archive's add/review/rollback procedure
when committing a future price revision.

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
1 billion per million tokens. Zero is an explicit zero price unless the optional credit uncertainty guard
below applies; an absent model has no price. Model and alias keys must be lowercase, without outer whitespace
or control characters. Raw names in logs remain visible alongside their resolved
`canonicalModel`; lookup ignores case and outer whitespace.

Optional `contextTier` specifies a positive `threshold`, `inputMultiplier` and
`outputMultiplier`; the tier applies to the whole request when its recorded input
exceeds the threshold. The input multiplier also applies to cached and cache-write
input. Optional `maximumInputTokens` caps the **known pricing coverage**, not the
model's technical context capacity. Above it, the request stays unpriced. If
both fields exist, the maximum must exceed the tier threshold. Missing context
uses the ordinary rate and is marked as an assumption when it can affect pricing.

Optional credits-only `cacheWriteInputUnverified: true` makes positive reported
writes unpriced. Absent, `null`, or `false` preserves the original v1 calculation:
`(input - cached - writes) * inputRate + cached * cachedRate + writes * writeRate`,
plus output and any configured context/mode factors. Thus existing custom cards
retain explicit zero or nonzero write prices and context tiers unchanged. API
entries reject this field. Exported new built-ins preserve the guard even when
loaded as custom cards. Older app versions reject the new field; restore your
previous custom file when rolling back rather than deleting the guard blindly.

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
API and credit rules remain independent. The built-in credit uncertainty guards
are described above; custom cards are explicit user configuration and are not
silently rewritten to match them.

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
`unverifiedCacheWrite`, `incompleteTokenBreakdown` and `stalePricing`.
The UI tooltip, CLI and MCP expose the same details. Known-price requests retain
their amounts even if another request for the same model is unpriced.

### Reading the estimates (TODO-20)

The menu labels the USD amount **Standard API** and the other amount as a
**purchased-credit equivalent**. Neither determines an actual API invoice,
credit deduction, included allowance or official balance. API-key usage,
Enterprise USD agreements and legacy Enterprise contracts need their own rates.
Daily totals span selected local logs; weekly observations belong to the active
account. Cloud, other-device and Work usage is covered only when captured in
those logs. A complete scan cannot establish a complete billing record.

`display.pricingBasisDetails` and `display.unpricedSummaryLabel` are optional
localized additions. Older snapshots without them still decode, and the menu
can derive descriptions from the existing raw fields. `basis: "current-rates"`,
all numeric fields and reason codes retain their meanings. No price signature or
cache migration is required for these presentation changes.

The summary shows the reason for the largest unpriced entry, with `+N` for the
other distinct reasons. It never adds API and credit token percentages. Hovering
on the summary shows each model, recorded mode (or an explicit missing-mode
label), affected tokens and percentage. Unknown future reason codes remain
visible and are not mislabeled as pending repricing. Missing mode/context
assumptions remain separate from unpriced usage.

Amounts, unpriced reasons and the rate card have separate tooltip regions.
Invalid configuration has its own visible fallback warning; read failures,
partial scans and cache persistence still use their existing status fields.
Pricing-only partial amounts retain their known portion with `+`; incomplete
scans may show `*` on the API card instead. Wholly unpriced amounts show `--`. The `local-usage` command and MCP local-usage tool share daily
explanations; `status` also has a weekly label because it reads official quota
context. Descriptions are provided in all five existing UI languages.

Token totals remain visible when billing components are missing or inconsistent.
Pricing requires input plus output to equal the total, cached/cache-write input
to fit within input, and reasoning output to fit within output. Omitted zero
components remain supported when those checks hold. A delta is unpriced if
either cumulative endpoint fails these checks, even if its own counters balance.
Fully unpriced usage shows `--` and 0% pricing coverage; a confirmed zero total
still shows zero. Scan completeness reports whether logs were read, independently
of pricing coverage. Weekly valuation excludes intervals containing unpriced API tokens. Credit-only
uncertainty sets the existing `creditAssumptionsPresent` flag and limits
confidence; it does not discard otherwise usable API valuation intervals.
When breakdowns are incomplete, the menu's component cards and cache-hit rate
show `--`. CLI/MCP retain numeric component counters for compatibility; inspect
`unpricedUsage` before treating those counters as a complete breakdown.

Calculation revision `pricing-v4` replays existing v4 caches without resetting valid
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
the [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol) and
[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) model pages,
the [Codex pricing page](https://learn.chatgpt.com/docs/pricing), and
[Codex speed modes](https://learn.chatgpt.com/docs/agent-configuration/speed).
API and credits use different rules and remain separate from official balances.
