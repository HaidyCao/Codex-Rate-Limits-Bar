# Repository price archive

This directory preserves **project configurations and review records**, not an
official billing history. The app does not load it. Existing estimates still use the
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

Each entry records the original file SHA-256, archive date and evidence paths.
Existing entries have a full `sourceCommit` identifying the original card and
repository evidence. Archive schema v2 also accepts **content snapshots** with
`sourceCommit: null` and fingerprinted copies of both review documents. This lets
a new card, evidence and archive pass verification before being committed together;
no future commit hash or intermediate failing commit is needed. A null commit
means no recorded commit attribution, even after the files are committed.

`api` and `credits` separately
record their version, original `verifiedAt`, source links and a concise evidence
summary. `configuration-only` preserves a configuration without claiming a new
policy review. `recorded-review` summarizes an existing review documented at the
source commit or captured documents; `reviewedOn` is that review's date, not today's archive check.
Carried-forward model prices are not implicitly reverified.

`effectiveFrom` and `effectiveTo` are **null** for both products. Both archive
schemas deliberately accept only unknown effective periods: archive, review,
commit and version dates cannot establish when an official price applied. Adding
supported periods requires an explicit schema/design review. Credit prices and
API equivalents remain separate; this data cannot reconstruct invoices.

Official source links are copied from the original cards and are not downloaded
by the checks. They are live references, not frozen evidence of page contents.
Summaries preserve the recorded findings and limitations, including the Cyber
model-page/general-table disagreement. See the [policy review](../pricing.md).

The existing manifest and five historical files remain in their original v1
format. Adding the first content snapshot sets the manifest schema to 2; all
existing entries retain their commits and unchanged bytes. Runtime price schema
v1 is independent of this archive schema and does not change.

## Offline verification

From the repository root, using Python 3 with no extra packages:

```sh
make verify-pricing-archive
python3 Tests/Integration/verify_pricing_archive.py --git-root .
```

The first command needs neither a build nor Git history. It checks strict
manifest fields, JSON duplicates, dates, evidence metadata, byte hashes, duplicate
snapshots, per-product version conflicts, file inventory and the current source
resource, then runs corruption regressions. It rejects symlink substitutions,
missing/modified review copies and unlisted evidence files.
The optional second command additionally compares every card with its local
Git blob and checks the cited repository documents exist at that commit, for
entries with a `sourceCommit`. Content snapshots get integrity checks and are
counted separately; they do not receive Git attribution. Missing
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
   tests, [pricing notes](../pricing.md) and [TODO](../../TODO.md). Preserve
   uncertainties and exact model scope. Finalize the review text before capturing
   it; no commit is required yet.
2. Copy the complete working price file into `cards/api-VERSION_credits-VERSION.json`
   without reformatting it. For that identifier, copy `docs/pricing.md` and
   `TODO.md` to `evidence/ID/docs__pricing.md.txt` and `evidence/ID/TODO.md.txt`.
   These are raw UTF-8 repository document copies, not downloaded web pages.
   Compute each file's original-byte hash with `shasum -a 256 FILE`.
3. Set manifest `schemaVersion` to 2 and append an entry with `sourceCommit: null`.
   Keep the existing entry fields, including both `repositoryEvidence` paths,
   and add the following map (replace `ID` and hashes with actual values):

   ```json
   "evidenceFiles": {
     "docs/pricing.md": {
       "file": "evidence/ID/docs__pricing.md.txt",
       "sha256": "SHA256_OF_CAPTURED_PRICING_DOCUMENT"
     },
     "TODO.md": {
       "file": "evidence/ID/TODO.md.txt",
       "sha256": "SHA256_OF_CAPTURED_TODO"
     }
   }
   ```

   Record the **actual** archive date and card hash. Copy both products' versions,
   `verifiedAt` and sources exactly; describe reviewed versus inherited facts.
   Keep effective periods null. Set `current` to the matching entry and update the
   inventory table above. Existing commit-based entries do not add `evidenceFiles`.
4. Run `make verify-pricing-archive`, optional local Git verification, and
   `make verify-pricing`. For the associated runtime/rate change run full
   `make verify` **before committing** the card, archive, evidence and notes together.
   Re-capture documents if correcting that review before commit. Once accepted,
   keep archived bytes immutable as working documents evolve. Do not invent a
   commit hash, change old snapshots, or weaken a failed validation to publish.

Historical backfills can still use a known commit and the original schema-v1
entry shape, extracting bytes with `git show COMMIT:PATH`. The checks do not
write files, change Git history, select custom prices, or update the manifest.

## Rollback

Keep old snapshots immutable. If reverting the bundled file byte-for-byte to an
existing snapshot, point `current` at that existing entry and verify again; do not
create another copy or delete newer evidence. A deliberately new revision needs
its own entry. The app ignores all archive data. For an actual application/custom
card rollback, follow [the compatibility procedure](../pricing.md#policy-revisions-and-rollback),
including the original app/card pairing and retention of caches and observations.
