# Repository price archive

This directory preserves committed **project configurations**, not an official
billing history. The app does not load it. Existing estimates still use the
current bundled or explicitly selected custom card. No account data, credentials,
personal custom cards, or captured website bodies are stored here.

## Contents and evidence

[manifest.json](manifest.json) lists five byte-for-byte snapshots from Git:

| Source commit | API version | Credits version | Repository change |
| --- | --- | --- | --- |
| `c06dea9` | `2026-09-12.1` | `2026-09-12.1` | Initial versioned configuration |
| `7c79417` | `2026-09-23.1` | `2026-09-23.1` | Sol/Luna support |
| `f8c9368` | `2026-10-06.1` | `2026-10-06.3` | 6.1, speed rates, credit coverage and scope |
| `3e98529` | `2026-10-06.2` | `2026-10-06.3` | Legacy API cache-write correction |
| `d5248e6` | `2026-10-07.1` | `2026-10-06.3` | Cyber API context tier |

These are committed states, not evidence that each was publicly released.
Intermediate October credits `.1` and `.2` were development steps with no
separately committed full card; they are not reconstructed. Repeated credits
versions must contain the same complete credit card. Known old mistakes remain
in their original snapshots so reviewers can trace the corrections.

Each entry records the original file SHA-256, full source commit, archive date,
and repository evidence paths at that commit. `api` and `credits` separately
record their version, original `verifiedAt`, source links and a concise evidence
summary. `configuration-only` preserves a configuration without claiming a new
policy review. `recorded-review` summarizes an existing review documented at the
source commit; `reviewedOn` is that review's date, not today's archive check.
Carried-forward model prices are not implicitly reverified.

`effectiveFrom` and `effectiveTo` are **null** for both products. The archive's v1
contract deliberately accepts only unknown effective periods: archive, review,
commit and version dates cannot establish when an official price applied. Adding
supported periods requires an explicit schema/design review. Credit prices and
API equivalents remain separate; this data cannot reconstruct invoices.

Official source links are copied from the original cards and are not downloaded
by the checks. They are live references, not frozen evidence of page contents.
Summaries preserve the recorded findings and limitations, including the Cyber
model-page/general-table disagreement. See the [policy review](../pricing.md).

## Offline verification

From the repository root, using Python 3 with no extra packages:

```sh
make verify-pricing-archive
python3 Tests/Integration/verify_pricing_archive.py --git-root .
```

The first command needs neither a build nor Git history. It checks strict
manifest fields, JSON duplicates, dates, evidence metadata, byte hashes, duplicate
snapshots, per-product version conflicts, file inventory and the current source
resource, then runs corruption regressions. It rejects symlink substitutions.
The optional second command additionally compares every card with its local
Git blob and checks the cited repository documents exist at that commit. Missing
history is a failure with a diagnostic; no fetch occurs automatically. A source
archive or shallow checkout can run the first command without claiming Git proof.

`make verify-pricing` also passes all archived cards through the app's existing
`pricing --validate` parser and compares its exported built-in card with the
current resource. This provides rate/schema validation without implementing a
second price parser. Subprocesses cannot network, access fixture credentials, or
write archive files. `make verify` includes both validation layers. None of these
commands checks whether a web page has changed or verifies an invoice.

## Add a reviewed configuration

1. Review the relevant policy sources and update the bundled card, its versions,
   tests and [pricing notes](../pricing.md). Preserve uncertainties and exact
   model scope. Commit that reviewed configuration so it has a stable source
   commit; use targeted pricing tests before that commit. Full verification will
   fail until the matching archive is added in the follow-up change.
2. Extract the complete file from that commit into `cards/` with the name
   `api-VERSION_credits-VERSION.json`; preserve the original bytes. For example:

   ```sh
   git show d5248e6:Sources/CodexRateLimitsCore/Resources/pricing.json > /tmp/reviewed-pricing.json
   shasum -a 256 /tmp/reviewed-pricing.json
   git rev-parse d5248e6
   ```

3. Append a manifest entry with that hash/commit and the **actual** archive date.
   Copy both products' versions, `verifiedAt` and sources exactly; describe what
   was reviewed versus inherited. Keep effective periods null, name the evidence
   documents at that commit, and update `current` to the entry matching the source
   resource. Update the inventory table above. Do not add duplicate copies merely
   for unchanged commits, or rewrite existing archived bytes to fix old prices.
4. Run both commands above and `make verify-pricing`; run full `make verify` for
   the associated runtime/rate change. Commit the archive and maintenance notes.
   Neither check updates the manifest or the user's active custom configuration.

## Rollback

Keep old snapshots immutable. If reverting the bundled file byte-for-byte to an
existing snapshot, point `current` at that existing entry and verify again; do not
create another copy or delete newer evidence. A deliberately new revision needs
its own entry. The app ignores all archive data. For an actual application/custom
card rollback, follow [the compatibility procedure](../pricing.md#policy-revisions-and-rollback),
including the original app/card pairing and retention of caches and observations.
