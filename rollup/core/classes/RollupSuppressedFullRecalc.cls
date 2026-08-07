/**
 * @description Substitute full-recalc processor returned when a registered
 * `RollupFullRecalcGate` suppresses a concurrent duplicate. It is a `RollupFullRecalcProcessor`
 * (so it survives the framework's no-op guard) but is deliberately NOT a
 * `RollupFullBatchRecalculator`, and every async entry point is a no-op so the duplicate recalc
 * never runs.
 *
 * Which guard does it actually reach? `Rollup.buildFullRecalcRollup` hands this back to
 * `transformWrappedMetadataToFullRecalcRollups`, which resets `isNoOp` to `recordCount == 0`.
 * Whenever records are in scope — the normal case, and the only one where suppressing a duplicate
 * is worth anything — that resets the constructor's `isNoOp = true` back to false, so
 * `Rollup.addRollup` keeps this processor and `RollupAsyncProcessor`'s no-op guard passes it
 * through. It survives into the processor tree and is driven like a real one. With no records in
 * scope the flag survives and `addRollup` drops it instead, which is equally correct because there
 * is no work either way.
 *
 * **Two different overrides make it inert, depending on how many groups the recalc covers, and
 * neither is optional.** With two or more groups, `performBulkFullRecalcInternal` promotes
 * `processors[0]` to conductor and `runCalc` below is the entry point. With exactly ONE group —
 * the primary case for a concurrency gate — that promotion branch is skipped, `Rollup.batch()`
 * builds a plain conductor around the substitute, and `getAsyncRollup`'s
 * `rollups.size() == 1 && rollups[0] instanceof RollupFullRecalcProcessor` arm hands the substitute
 * straight to `beginAsyncRollup()`. `runCalc` is never called on that path; `startAsyncWork` is the
 * only thing standing between a suppressed recalc and a real enqueued job.
 *
 * `performWork` is genuinely unreachable — but only because `startAsyncWork` returns without
 * enqueueing, so `execute` never runs. It is kept as belt-and-braces on a file the fork owns
 * outright (no upstream rebase surface), because the cost of a substitute that quietly does real
 * work is far higher than one dead override.
 *
 * An earlier revision of this docstring claimed `startAsyncWork` was dead too, on the strength of a
 * `Limits.getQueueableJobs()` assertion that sat AFTER `Test.stopTest()` and therefore read the
 * restored outer limit context — it could not fail. Both assertions now sit inside the test block,
 * and deleting this override reddens `realPathSuppressSubstitutesBuiltProcessor` with an actual
 * enqueued job. Do not trust a queueable-count assertion placed after `stopTest`.
 *
 * The gate is not carried through to this substitute on purpose. A suppressed run claimed nothing
 * of its own — the state it collided with belongs to the run already in flight — so there is
 * nothing here to release.
 *
 * Suppression is scoped to THIS rollup group. It never cancels another calc-item type's recalc
 * (see `runCalc`), and it does discard the suppressed group's pending parent-field resets along
 * with the recalc that would have repopulated them — blanking parents without recomputing would
 * be worse than leaving the in-flight winner's values in place.
 */
public without sharing class RollupSuppressedFullRecalc extends RollupFullRecalcProcessor {
  /**
   * @description Builds the substitute from the suppressed recalc's context.
   * @param context the recalc context the gate suppressed
   */
  public RollupSuppressedFullRecalc(RollupFullRecalcContext context) {
    super('', context.getInvocationPoint(), context.getRollupMetadata(), context.getCalcItemType(), new Set<String>(), null);
    this.overridesRunCalc = true;
    this.isNoOp = true;
  }

  /**
   * @description Suppresses this recalc without cancelling anyone else's. `performBulkFullRecalc`
   * promotes `processors[0]` to conductor and hangs the OTHER calc-item types' processors off its
   * `rollups`, so a substitute that lands in first position is holding work the gate either
   * proceeded or never saw. Returning early there would drop it silently — no job, no error, no
   * log, just parent fields that stay stale. So hand the conductor role to the first live
   * processor, mirroring `RollupParentResetProcessor.arrangeCabooses`, which exists for exactly
   * this reason. With nothing in tow this is the plain no-op it looks like.
   * @return the promoted conductor's process id, or the no-op id when nothing was in tow
   */
  public override String runCalc() {
    if (this.rollups.isEmpty()) {
      return this.getNoProcessId();
    }
    RollupAsyncProcessor newConductor = this.rollups.remove(0);
    newConductor.rollups.addAll(this.rollups);
    this.rollups.clear();
    return newConductor.runCalc();
  }

  protected override String startAsyncWork() {
    return this.getNoProcessId();
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected override void performWork() {
    // intentional no-op: the gate suppressed this concurrent duplicate full recalculation
  }

  protected override String getTypeName() {
    return RollupSuppressedFullRecalc.class.getName();
  }
}
