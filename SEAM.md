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

Two more files diverge for the seam's sake:

- `RollupPlugin.cls` — `onlyUseMockPlugins`. Test-only: it lets a test assert "nothing is registered"
  without the host org's real records deciding the answer. Pure instrumentation; production behaviour
  is identical while the flag is false. **This one announces itself** — the gate tests reference the
  field by name, so reverting the file to upstream is a compile error, not a silent green.
- `RollupTests.cls` — the async-job stub in `fallsBackToRunningSyncWhenOutOfAsyncJobs` DERIVES the
  value from `System.OrgLimits` instead of upstream's literal `250001`. `DailyAsyncApexExecutions` scales with
  licenses (259,400 in a 100+-seat org), so upstream's literal does not exceed it there and the test
  fails in a real org. It passes either way under `aer`, so only a real org run catches a revert.
  This one is a genuine upstream bug and is the best candidate to PR away. **Check it by eye after
  every bump** — nothing in the suite goes red if it is reverted.

Seven rules hold the seam together; breaking any of them reintroduces a bug we already shipped once:

1. **Resolve the gate before building the context.** `RollupFullRecalcContext`'s constructor clones the
   metadata list, copies every in-scope parent id, derives the key and mints a token via
   `Crypto.generateAesKey`. Build it first and every cursor-path full recalc pays for a context it
   throws away. **Not pinned by a test**: delete the `gate == null` short-circuit and the suite stays
   green, because the outcome is identical and only the cost differs. Check this one by eye on every
   bump.

   Read this as "keep the seam's per-recalc cost proportionate", not "the dormant seam allocates
   nothing anywhere". It does not hold literally: rule 3's pre-ingest snapshot copies `this.rollups`
   on **every** `runCalc`, gated or not. That one is a shallow copy of a handful of processors and
   buying it back is what produced a live-list alias a cold round had to catch, so it stays — but do
   not cite rule 1 as a reason to shave an allocation whose absence costs correctness.

2. **A gate that claims its lock and then throws must still get its `afterComplete`.** The load-bearing
   part is that the `catch` around `beforeEnqueue` FALLS THROUGH to a gated processor; upstream's
   shape returned from inside the catch and left it ungated, stranding the claim. `setFullRecalcGate`
   runs before the consult, which is the obvious way to get that, but the order is not itself the
   invariant — moving it below the try/catch keeps `claimThenThrowStillReleasesTheClaim` green.
   Do not "simplify" by restoring an early return in the catch.

   Either shape releases for a recalc the gate never finished deciding on, so the interface REQUIRES
   an implementation to match a release against `context.getRunToken()` and no-op an unmatched one —
   the framework does not enforce it. That requirement is inherent to failing open, not a cost of
   the arming order, so do not weaken the clause in `RollupFullRecalcGate` on the theory that
   rearranging this method would pay for it.

3. **A recalc that is consulted but never enqueued must still be released.** The gate is consulted at
   BUILD time; `runCalc` decides at RUN time and has several exits that log and return without
   enqueueing anything — `isNoOp`, `RollupControl__mdt.ShouldAbortRun__c`, the
   `RollupSettings__c.IsEnabled__c` kill switch, and "no matching rollups". No job means no finalizer
   means no release, so `RollupAsyncProcessor.runCalc` calls `releaseFullRecalcGate()` on that join
   point and walks its `rollups` (the bailing processor is routinely a plain conductor holding the
   gated one).

   **Walking `this.rollups` at the join point is NOT sufficient, and assuming it was cost two
   rounds.** `ingestRollupControlData` empties that list first, three different ways: it prunes an
   aborted rollup and a duplicate-hash one (which is why both arms release as they remove — a
   silent removal from a conductor that RUNS ON never reaches the bail arm at all, and a surviving
   duplicate carries its own `runToken`, so its release does not cover the one dropped), and it
   _relocates_ a rollup
   that `couldRunSync` into either the local `syncRollups` list or the static cached-rollup list.
   `runCalc` therefore releases from a **pre-ingest snapshot** of `this.rollups`, which covers every
   relocation destination without reaching into the static cache, where a sibling conductor's
   still-live rollups also sit.

   **The two destinations are safe for different reasons, and only one of them is "nothing ran".**
   For `syncRollups` it is exactly that: `process(syncRollups)` sits in the `else`, so a bail arm
   means it never ran. The static cached-rollup list is NOT covered by that argument — it is drained
   and run later in the same transaction via `populateOtherDeferredRollups`, so a gated rollup
   landing there would make the snapshot release EARLY. What keeps it out is
   `getShouldRunSyncDeferred`, which requires `roll.op` to be non-null: `op` is assigned only in the
   inner-rollup constructor, and every `RollupFullRecalcProcessor` routes through
   `super(invokePoint)` instead. That is a **latent** guarantee, not a designed one, and it is not
   pinned by anything — re-derive it if a bump touches either constructor chain. `couldRunSync` is
   satisfied by `ShouldRunAs__c = Synchronous` (which
   `setControlToSyncForSingularParentRecalcs` forces for `FROM_SINGULAR_PARENT_RECALC_LWC`), by any
   already-async run that is not timing out, or by an exceeded org async limit — so this is a live
   combination, not a corner. Pinned by `killSwitchReleasesAClaimRelocatedToTheSyncList`.
   A run that DID process sync rollups cannot reach the bail arm, so the snapshot release cannot
   fire early — but the reason is branch ORDER, not a process-id value: `isNoOp`,
   `ShouldAbortRun__c` and the `IsEnabled__c` kill switch are all evaluated BEFORE the `else` that
   calls `process(syncRollups)`. Do not restate this as "`getNoProcessId()` is never `'no-op'`";
   that sentinel is overwritten unconditionally by the `beginAsyncRollup()` line whenever the tree
   has rollups, so it proves nothing.
   Build-time filtering cannot cover any of this — an operator can flip either switch after the
   consult and before the run. The one case that IS filtered at build time is the recalc still
   `isNoOp` with `recordCount == 0`, which `addRollup` drops outright: it is dropped before any
   finalizer exists, so it must never be consulted in the first place
   (`zeroRecordRecalcIsNeverConsulted`).

4. **Only a processor that will actually release may be gated, enforced at the consult site.** The
   guard that makes this true is the one inside `applyFullRecalcGate`; the near-identical check in
   `buildFullRecalcRollup` is a cost optimisation that skips gate resolution and context
   construction, not a second safety net. Delete the caller's and nothing breaks; delete the
   callee's and `nonCursorProcessorIsNotGated` goes red.

   The test is not `instanceof RollupFullBatchRecalculator` alone. `RollupParentResetProcessor`
   **extends** that class, so it passes — and it overrides `runCalc` without calling super, so
   neither the rule-3 bail-out release nor a finalizer ever runs for it. It is excluded by name.
   Anything else that overrides `runCalc` wholesale needs the same treatment; the type hierarchy
   does not express "will release", so this guard has to enumerate.

5. **The suppression substitute must pass on the conductor role.** `performBulkFullRecalc` promotes
   `processors[0]` and hangs the other calc-item types off its `rollups`. A substitute that lands
   there and returns early cancels rollup groups the gate never suppressed — silently, no job and no
   log. `RollupSuppressedFullRecalc.runCalc` promotes the first live processor instead, mirroring
   `RollupParentResetProcessor.arrangeCabooses`.

   **`runCalc` is not the only override doing work, and a cold round caught us claiming it was.**
   That promotion path is the MULTI-group shape. With exactly one suppressed group — the primary
   case for a concurrency gate — the promotion branch is skipped entirely, `Rollup.batch()` wraps
   the substitute in a plain conductor, and `getAsyncRollup`'s `rollups.size() == 1 && rollups[0]
instanceof RollupFullRecalcProcessor` arm hands it straight to `beginAsyncRollup()`. `runCalc`
   never runs; `startAsyncWork` is the only thing preventing a real enqueued job. Deleting it as
   "dead" makes a suppressed recalc run. `performWork` is genuinely unreachable, but only because
   `startAsyncWork` returns first — keep both.

6. **Only the conductor may release.** `hasNotifiedGate` is a per-instance latch: it rides the cursor
   chain (each page is the serialized previous instance) but does NOT span a sibling copy. So a
   release site reachable by a delegated inner rollup would fire `afterComplete` from that rollup's
   own copy of the conductor while the real conductor is still paging — an early release, which for
   a suppression policy is worse than a late one and which a TTL cannot backstop.

   No such site exists today, and the reason is narrow: `QueueableProcessor.execute` routes a child
   to `finish(BatchableContext)` only when `fullRecalcProcessor.isBatch() != true`, and the only
   gateable conductor is `RollupFullBatchRecalculator`, whose `isBatch()` is always true — so its
   delegates always take `executeFinish()` instead. `RollupDeferredFullRecalcProcessor` does reach
   that branch but is never gated.

   That same routing is why `RollupAsyncProcessor.finish` deliberately does **not** release through
   `fullRecalcProcessor`. It once did. The call could never fire for a real claim (null on the
   Batchable route, non-gateable types on the Queueable one) and the single shape that would have
   reached it is the early release this rule forbids, so it was removed and the absence documented
   in place. Do not reinstate it on a bump.

   **This rule is held by that routing, not by a guard.** An earlier
   revision of this fork carried an `isDelegatedInnerRollup` flag to enforce it; it was removed as
   speculative divergence on upstream-owned files once the routing was traced. If a bump changes
   either `isBatch()` or that branch in `execute`, re-derive this before shipping.

7. **A processor that completes as a Batchable releases on `this`, not on `fullRecalcProcessor`.**
   `startAsyncWork` falls back to `FullBatchQueueableFailsafe` → `Database.executeBatch` whenever
   `Database.getCursor` is refused. That Batchable is deliberately not `Database.Stateful`, so the
   instance reaching `finish(BatchableContext)` is deserialized from the state captured at
   `executeBatch` — before `performWork` assigns the `fullRecalcProcessor` self-reference. The
   inherited release reads that field and finds null, silently. `RollupFullRecalcProcessor` therefore
   overrides `finish(BatchableContext)` and releases `this` in a `finally`. It is deliberately NOT
   gated on `isTimingOut` the way the base implementation is: this override is only ever reached as
   a Batchable, where `finish` is terminal by definition, and the field is a stale serialized
   artifact there — `beginAsyncRollup` sets it false on the line before `startAsyncWork`, while the
   failsafe route bypasses `beginAsyncRollup` entirely and can carry a `true` forward from an
   earlier page. A guard would suppress the only release the job ever gets. Pinned end to end by
   `suppressedConductorStillRunsTheOtherRollupGroups`, which asserts the released KEYS against the
   proceeded ones, and at unit level by `batchableFailsafeCompletionReleasesGate`.

   **Known gap A, org-only and not fixed here — three or more gated groups.** With **three or more gated groups in one chain**,
   `RollupFullRecalcProcessor.finish()` runs `conductor.finalizer = conductor.finalizer ?? this.finalizer`
   (upstream, since v1.7.27) and the promoted conductor inherits a `FullRecalcFinalizer` bound to the
   PROMOTER. When the promoted conductor's job completes on the cursor path, `handleSuccess` releases
   the promoter — already latched — and the promoted group's own claim strands. Rule 7's override does
   not reach it because the cursor path is a Queueable, not a Batchable. It is **not reproducible in
   an Apex test at any layer**: driving three proceeded groups through `performBulkFullRecalc` hits
   the platform's in-test queueable chaining cap (`Too many queueable jobs added to the queue: 2`)
   before the third group starts. Under `aer` every group after the first takes the failsafe route
   anyway, so rule 7 covers them and the gap never shows. A gate implementation must treat a missing
   `afterComplete` as possible and rely on its TTL; do not assume the release is guaranteed for the
   third and later groups of a bulk recalc.

   **Why it is not fixed here, so the next reader does not have to re-derive the call.** The fix is
   roughly ten lines across two upstream-owned files — carrying a release target on the finalizer
   separately from its bound conductor — and no test at any layer can confirm it works, because the
   shape that needs it cannot be built in an Apex test. That is speculative divergence on the exact
   files where divergence costs the most, defending a state we cannot demonstrate, and an earlier
   revision of this fork deleted ~25 lines of precisely that. If the shape ever becomes reproducible
   (a platform change to the in-test queueable chaining cap, or an org-level trace), revisit it.
   Until then the mitigation is the TTL requirement in `RollupFullRecalcGate.afterComplete`'s
   contract — which is a requirement on the consumer, not a control in this repo, and should be
   carried as an acceptance criterion on whatever ticket activates a gate.

   **Known gap B, org-only and not fixed here — a chunk that defers its rollups.** The release this
   override fires is unconditional, and a Batchable chunk can leave work outstanding. `process`
   checks `getIsTimingOut(roll.rollupControl, AT_ROLLUP)` per rollup and hands anything over the
   line to `addProcessorToDeferredRollups`; `processDeferredRollups` then rebuilds a conductor and
   calls `startAsyncWork()` on it. That resolves to `startBatchProcessor`, whose every branch
   produces a SEPARATE async job in a real org — `Database.executeBatch` throws when called from
   inside a batch `execute`, and the catch falls to `new QueueableProcessor(this).startAsyncWork()`.
   The platform then calls `finish(BatchableContext)` after the last chunk and this override
   releases while that job is still queued: an **early** release, the direction rule 6 calls worse
   than a late one and which a TTL cannot backstop. Note the `AT_PARENT` bypass
   (`fullRecalcProcessor != null`) does not apply at the `AT_ROLLUP` call site, so a gated chunk
   genuinely can defer.

   The deferral half is **confirmed by trace**, not inferred: instrumenting `process` and driving a
   gated `RollupFullBatchRecalculator` chunk with a PROCEED gate deferred 16 of 17 rollups and
   reached `conductor.startAsyncWork()`. The early release itself does **not** reproduce, under
   `aer` or in an Apex test: `aer` runs `Database.executeBatch` inline, so the deferred work
   completes inside the same call and the release lands after it — correct, by accident of the
   runtime.

   **Why it is not fixed here.** Nothing observable at `finish(BatchableContext)` distinguishes
   "a chunk re-enqueued deferred work" from "done". The Batchable is deliberately not
   `Database.Stateful`, so the instance reaching `finish` is deserialized from the state captured at
   `executeBatch` and cannot see a flag any chunk set — which is the same reason an `isTimingOut`
   guard here would be wrong (above), not a reason to add one back. Detecting it needs state that
   survives chunks, i.e. making the Batchable Stateful, on an upstream-owned file, defending a
   state no test can demonstrate. Same call as gap A, and the same trigger to revisit. The
   consumer-side consequence is sharper than gap A's, though: a gate must tolerate an `afterComplete`
   that arrives **before** the recalc has actually finished, so a policy that treats the callback as
   proof of completion — rather than as permission to re-claim after its own TTL — is unsafe here.

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

**`RollupFullRecalcGate` — `sfge:UnimplementedType` (Sev4, not suppressed).** `npm run scan` reports
exactly one violation on this fork and this is it: "Extend, implement, or delete interface
RollupFullRecalcGate". It is structural and permanent — a dormant seam has no in-fork implementer by
definition, and the host org supplies one. Sev4 does not fail the gate, so it is left visible rather
than suppressed; a suppression would hide the day the seam genuinely goes unused.

## Preserving the divergence across an upstream bump

The whole stack (carries + seam) is a linear series on top of the upstream base tag. To catch up:

```
git fetch upstream --tags
git rebase --onto <new-upstream-tag> <old-upstream-tag> <fork-branch>
```

Resolve conflicts (historically only in `extra-tests/testSuites/ApexRollupTestSuite.testSuite-meta.xml`
when upstream reorganizes tests). Then **verify with aer** before tagging:

```
aer test rollup extra-tests --skip-errors -f RollupFullRecalcGateTests   # seam: expect 43/43
aer test rollup extra-tests --skip-errors -f ZZ                          # carries: expect 19/19
```

Tag the result `v<upstream>-vacatia.<n>` and vendor it into the Vacatia SalesforceDX monorepo via
`scripts/vendor/vendor-apex-rollup.sh` (bump `ROLLUP_TAG`). A handful of `RollupCalculatorTests` /
`RollupFullRecalcTests` fail under aer on a **clean** upstream checkout too — they are aer-vs-org
environment gaps, not regressions; confirm the same failures exist on the clean upstream tag before
worrying about them. The fastest way to confirm is a throwaway worktree on the base
(`git worktree add /tmp/wt <base-tag>`) and the same `aer` filter, then
`git worktree remove /tmp/wt --force`.

As of v1.7.44 the **unfiltered** `aer test rollup extra-tests --skip-errors` baseline is **40
failures across 9 classes** — `RollupDateLiteralTests` (17), `RollupCalculatorTests` (5),
`RollupRecursionItemTests` (4), `InvocableDrivenTests` (4), `RollupStateTests` (3),
`RollupFullRecalcTests` (2), `RollupIntegrationTests` (2), `CustomMetadataDrivenTests` (2),
`RollupSObjectUpdaterTests` (1). All 40 reproduce on the clean base. Compare the failing SET against
the base, not the count against zero.
