# Vacatia fork divergence — read before syncing upstream

This is the Vacatia fork of [jamessimone/apex-rollup](https://github.com/jamessimone/apex-rollup).
It stays a near-fast-forward of upstream, carrying a small, deliberate divergence. **Anyone bumping
the upstream base must preserve everything below — a naive overwrite silently reverts it.**

## 1. The full-recalc gate seam (the load-bearing divergence)

Upstream has no way to veto or substitute a full-recalc before it enqueues. This fork adds a **dormant
seam** so a host org can plug in a policy (Vacatia uses it for a concurrent-recalc suppression semaphore,
CXS-300) **without forking rollup behavior**:

- `rollup/core/classes/RollupFullRecalcGate.cls` — the interface (`beforeEnqueue` → PROCEED/SUPPRESS,
  `afterComplete`).
- `rollup/core/classes/RollupFullRecalcContext.cls` — the immutable recalc description handed to the gate
  (calc-item type, rollup metadata, record ids, a stable `recalcKey`, a per-invocation `runToken`).
- `Rollup.cls` — `resolveFullRecalcGate()` resolves the gate class from a `RollupPlugin__mdt` /
  `RollupPluginParameter__mdt` registration (`FullRecalcGate` / `FullRecalcGateClass`) and **fails open**
  (proceeds) when unconfigured, unresolvable, or on any error. Plus `RollupSuppressedFullRecalc`, the no-op
  substitute processor returned on SUPPRESS.
- `RollupFullBatchRecalculator`, `RollupAsyncProcessor`, `RollupFinalizer`, `RollupFullRecalcProcessor` —
  the gating call sites + release hook.
- `extra-tests/classes/RollupFullRecalcGateTests.cls` — covers the seam in isolation (dormant-is-inert,
  fail-open paths, runToken stability).

**Zero behavior change unless a gate class is registered.** With no `RollupPlugin__mdt` registration the
seam is inert, so it is safe to carry on top of any upstream release.

## 2. Bug-fix carries (general, upstream candidates)

Not Vacatia-specific — full-recalc correctness fixes that belong upstream (PR them to reduce this
divergence to just the seam):

- changed-fields full-recalc scope: keep in-scope bystanders, requery all `GroupByFields`, honor a
  caller-supplied custom `Evaluator` in bystander re-inclusion.
- don't drop unchanged bystanders from `ChangedFieldsOnCalcItem` rollups.
- `ZZ*` regression suite in `extra-tests/` guards all of the above.

## Preserving the divergence across an upstream bump

The whole stack (carries + seam) is a linear series on top of the upstream base tag. To catch up:

```
git fetch upstream --tags
git rebase --onto <new-upstream-tag> <old-upstream-tag> <fork-branch>
```

Resolve conflicts (historically only in `extra-tests/testSuites/ApexRollupTestSuite.testSuite-meta.xml`
when upstream reorganizes tests). Then **verify with aer** before tagging:

```
aer test rollup extra-tests --skip-errors -f RollupFullRecalcGateTests   # seam: expect 31/31
aer test rollup extra-tests --skip-errors -f ZZ                          # carries: expect all green
```

Tag the result `v<upstream>-vacatia.<n>` and vendor it into the Vacatia SalesforceDX monorepo via
`scripts/vendor/vendor-apex-rollup.sh` (bump `ROLLUP_TAG`). A handful of `RollupCalculatorTests` /
`RollupFullRecalcTests` fail under aer on a **clean** upstream checkout too — they are aer-vs-org
environment gaps, not regressions; confirm the same failures exist on the clean upstream tag before
worrying about them.
