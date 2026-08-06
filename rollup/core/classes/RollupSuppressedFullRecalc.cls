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
 * through. It IS enqueued: the overrides below are what make it inert, not the flag. With no
 * records in scope the flag survives and `addRollup` drops it instead, which is equally correct
 * because there is no work either way.
 *
 * The gate is not carried through to this substitute on purpose. A suppressed run claimed nothing
 * of its own — the state it collided with belongs to the run already in flight — so there is
 * nothing here to release.
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

  public override String runCalc() {
    return this.getNoProcessId();
  }

  protected override String startAsyncWork() {
    return this.getNoProcessId();
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected override void performWork() {
    // intentional no-op: the gate suppressed this concurrent duplicate full recalculation
  }

  protected override List<RollupAsyncProcessor> transformFullRecalcRollups() {
    return new List<RollupAsyncProcessor>();
  }

  protected override String getTypeName() {
    return RollupSuppressedFullRecalc.class.getName();
  }
}
