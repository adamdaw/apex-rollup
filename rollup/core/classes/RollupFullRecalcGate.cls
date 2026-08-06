/**
 * @description Generic, dormant seam that lets an external policy suppress a concurrent
 * duplicate full recalculation. The framework consults `beforeEnqueue` before it enqueues a
 * full-recalc processor and calls `afterComplete` once when that recalc terminally finishes
 * (success or catchable failure). With no implementation registered via `RollupPlugin__mdt`
 * the framework behaves exactly as it does today (fail-open). The gate keys on the rollup
 * (see `RollupFullRecalcContext`), never on the caller. Shaped for contribution upstream.
 */
public interface RollupFullRecalcGate {
  /**
   * @description Consulted before a full-recalc processor is returned/enqueued.
   * @param context immutable description of the recalc about to run
   * @return `PROCEED` to run the recalc unchanged, or `SUPPRESS` to substitute a no-op
   */
  RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context);

  /**
   * @description Fired once when a proceeded recalc terminally completes, on both the
   * success and catchable-failure paths, so a policy can release any state it claimed.
   *
   * The framework arms this release before it consults `beforeEnqueue`, so a gate that claims
   * state and then throws is still released. It cannot fire, however, if the transaction dies
   * between the gate consult and the enqueue (an uncaught exception, a governor limit). An
   * implementation that claims state MUST therefore carry its own expiry — a TTL on the claim is
   * the only backstop for that window, and a policy without one can strand a claim forever.
   * @param context the same context captured at `beforeEnqueue` for this recalc
   */
  void afterComplete(RollupFullRecalcContext context);
}
