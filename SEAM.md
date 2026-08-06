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
- `rollup/core/classes/RollupSuppressedFullRecalc.cls` — the no-op substitute processor returned on SUPPRESS.
- `Rollup.cls` — `resolveFullRecalcGate()` resolves the gate class from a `RollupPlugin__mdt` /
  `RollupPluginParameter__mdt` registration (`FullRecalcGate` / `FullRecalcGateClass`) and **fails open**
  (proceeds) when unconfigured, unresolvable, or on any error, plus `applyFullRecalcGate()`, the consult site.
- `RollupFullBatchRecalculator`, `RollupAsyncProcessor`, `RollupFinalizer`, `RollupFullRecalcProcessor` —
  the gating call sites + release hook.
- `extra-tests/classes/RollupFullRecalcGateTests.cls` — covers the seam in isolation (dormant-is-inert,
  fail-open paths, runToken stability).

Six rules hold the seam together; breaking any of them reintroduces a bug we already shipped once:

1. **Resolve the gate before building the context.** `RollupFullRecalcContext`'s constructor clones the
   metadata list, copies every in-scope parent id, derives the key and mints a token via
   `Crypto.generateAesKey`. Build it first and the "dormant seam costs nothing" claim stops being true —
   every cursor-path full recalc pays for a context it throws away.
2. **Arm the release before consulting `beforeEnqueue`.** `setFullRecalcGate` runs first so a policy that
   claims its lock and then throws still gets its `afterComplete`. An unmatched release is a no-op by
   construction (the gate matches on `runToken`), so arming early is free.
3. **Don't consult the gate for a recalc that will never enqueue.** A processor that is still `isNoOp`
   with `recordCount == 0` is dropped by `addRollup`, so no finalizer would ever release a claim taken
   for it.
4. **Only the cursor path may be gated, checked at the consult site itself.** A non-cursor processor
   never fires `notifyGateComplete`, so consulting it takes a claim nothing gives back. The caller
   filters, and `applyFullRecalcGate` re-checks — a comment is not a guard, and the failure mode is a
   silently stranded lock.
5. **The suppression substitute must pass on the conductor role.** `performBulkFullRecalc` promotes
   `processors[0]` and hangs the other calc-item types off its `rollups`. A substitute that lands
   there and returns early cancels rollup groups the gate never suppressed — silently, no job and no
   log. `RollupSuppressedFullRecalc.runCalc` promotes the first live processor instead, mirroring
   `RollupParentResetProcessor.arrangeCabooses`.
6. **Only the conductor releases.** `hasNotifiedGate` is a per-instance latch: it rides the cursor
   chain (each page is the serialized previous instance) but not a sibling copy. A delegated inner
   rollup carries its own copy of the conductor, so `RollupAsyncProcessor.finish` skips the release
   when `isDelegatedInnerRollup` — otherwise `afterComplete` fires while the conductor is still
   paging, and an early release lets in the duplicate the policy exists to stop. A TTL cannot
   backstop that direction.

**Zero behavior change unless a gate class is registered.** With no `RollupPlugin__mdt` registration the
seam is inert, so it is safe to carry on top of any upstream release.

## 2. Bug-fix carries (general, upstream candidates)

Not Vacatia-specific — full-recalc correctness fixes that belong upstream (PR them to reduce this
divergence to just the seam):

- changed-fields full-recalc scope: keep in-scope bystanders, requery all `GroupByFields`, honor a
  caller-supplied custom `Evaluator` in bystander re-inclusion.
- don't drop unchanged bystanders from `ChangedFieldsOnCalcItem` rollups.
- `ZZ*` regression suite in `extra-tests/` guards all of the above.

## 3. Analyzer suppressions the fork owns

**`RollupCalculator` — `PMD.ExcessivePublicCount`.** Upstream sits at 19 of the 20 limit; the
fork's `setCustomEvaluator` (needed so full-recalc bystander re-inclusion honours a caller-supplied
`Evaluator`) is the 20th. It has to be public — `RollupAsyncProcessor` is not a subclass and Apex
has no package-private. The alternatives were changing `setEvaluator`'s signature, rewriting ~35
upstream test call sites, or threading the value through the virtual `Factory.getCalculator` and
every calculator subclass constructor. An overload is not available: `setEvaluator` and
`setCustomEvaluator` take the same parameter type. Each alternative is far more divergence than a
count threshold is worth on a fork whose value is being a near-fast-forward of upstream. The
suppression is the fork's, not
upstream's: scanning the upstream file in isolation returns zero violations. If a bump makes the
suppression unnecessary, drop it rather than carrying it.

## Preserving the divergence across an upstream bump

The whole stack (carries + seam) is a linear series on top of the upstream base tag. To catch up:

```
git fetch upstream --tags
git rebase --onto <new-upstream-tag> <old-upstream-tag> <fork-branch>
```

Resolve conflicts (historically only in `extra-tests/testSuites/ApexRollupTestSuite.testSuite-meta.xml`
when upstream reorganizes tests). Then **verify with aer** before tagging:

```
aer test rollup extra-tests --skip-errors -f RollupFullRecalcGateTests   # seam: expect 37/37
aer test rollup extra-tests --skip-errors -f ZZ                          # carries: expect 19/19
```

Tag the result `v<upstream>-vacatia.<n>` and vendor it into the Vacatia SalesforceDX monorepo via
`scripts/vendor/vendor-apex-rollup.sh` (bump `ROLLUP_TAG`). A handful of `RollupCalculatorTests` /
`RollupFullRecalcTests` fail under aer on a **clean** upstream checkout too — they are aer-vs-org
environment gaps, not regressions; confirm the same failures exist on the clean upstream tag before
worrying about them. The fastest way to confirm is a throwaway worktree on the base
(`git worktree add /tmp/wt <base-tag>`) and the same `aer` filter — as of v1.7.44 that is 2 in
`RollupFullRecalcTests` (`shouldBatchForFullRecalcWhenOverLimits`,
`addsCabooseForMultipleFullRecalcsToDifferentParents`) and 5 state-related ones in
`RollupCalculatorTests`.
