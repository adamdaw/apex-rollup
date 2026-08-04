/**
 * @description Immutable snapshot describing a single full-recalculation, handed to a
 * `RollupFullRecalcGate` so an external policy can decide whether to run or suppress a
 * concurrent duplicate. It exposes the rollup identity (the `Rollup__mdt` group), the
 * calc-item type, the parent record ids and count, the invocation point, a derived
 * recalc key, and a per-invocation run token. The key is derived from the rollup group
 * alone — never from the caller — so gate decisions are caller-agnostic; the run token is
 * distinct per invocation so a policy can correlate a release to the claim that opened it. This is a generic, upstream-shaped seam with no
 * consumer of its own; with no gate registered it is never constructed.
 */
public inherited sharing class RollupFullRecalcContext {
  /**
   * @description The gate's verdict for a given recalc. `PROCEED` runs the recalc exactly
   * as the framework would today; `SUPPRESS` substitutes a no-op processor.
   */
  public enum Decision {
    PROCEED,
    SUPPRESS
  }

  private final Schema.SObjectType calcItemType;
  private final List<Rollup__mdt> rollupMetadata;
  private final Set<String> recordIds;
  private final Integer recordCount;
  private final Rollup.InvocationPoint invocationPoint;
  private final String recalcKey;
  private final String runToken;

  /**
   * @description Builds an immutable context. The id/metadata collections are copied so the gate
   * cannot swap or resize the framework's own collections; the `Rollup__mdt` elements are shared
   * (a shallow list copy) and treated as read-only config — the gate must not mutate them.
   * @param calcItemType the SObjectType of the records being rolled up
   * @param rollupMetadata the `Rollup__mdt` group driving this recalc
   * @param recordIds the parent record ids in scope (may be empty for an all-rows recalc)
   * @param recordCount the count of records the recalc will process
   * @param invocationPoint where the recalc was invoked from
   */
  @SuppressWarnings('PMD.ExcessiveParameterList')
  public RollupFullRecalcContext(
    Schema.SObjectType calcItemType,
    List<Rollup__mdt> rollupMetadata,
    Set<String> recordIds,
    Integer recordCount,
    Rollup.InvocationPoint invocationPoint
  ) {
    this.calcItemType = calcItemType;
    this.rollupMetadata = rollupMetadata == null ? new List<Rollup__mdt>() : rollupMetadata.clone();
    this.recordIds = recordIds == null ? new Set<String>() : new Set<String>(recordIds);
    this.recordCount = recordCount;
    this.invocationPoint = invocationPoint;
    this.recalcKey = deriveRecalcKey(this.calcItemType, this.rollupMetadata);
    this.runToken = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
  }

  /**
   * @description The SObjectType of the calc items being rolled up.
   * @return the calc-item SObjectType
   */
  public Schema.SObjectType getCalcItemType() {
    return this.calcItemType;
  }

  /**
   * @description The `Rollup__mdt` group driving this recalc.
   * @return a defensive copy of the rollup metadata list
   */
  public List<Rollup__mdt> getRollupMetadata() {
    return this.rollupMetadata.clone();
  }

  /**
   * @description The parent record ids in scope for this recalc.
   * @return a defensive copy of the record ids
   */
  public Set<String> getRecordIds() {
    return new Set<String>(this.recordIds);
  }

  /**
   * @description The count of records the recalc will process.
   * @return the record count
   */
  public Integer getRecordCount() {
    return this.recordCount;
  }

  /**
   * @description Where the recalc was invoked from.
   * @return the invocation point
   */
  public Rollup.InvocationPoint getInvocationPoint() {
    return this.invocationPoint;
  }

  /**
   * @description A stable key identifying this logical recalc, derived from the rollup
   * group (calc-item type + sorted `Rollup__mdt` DeveloperNames) and never from the caller.
   * @return the derived recalc key
   */
  public String getRecalcKey() {
    return this.recalcKey;
  }

  /**
   * @description A correlation token unique to this context instance — one logical recalc
   * invocation — minted once at construction. The recalc key is deliberately shared across
   * concurrent duplicates of the same rollup group; the run token is the opposite, distinct
   * per invocation. A gate stamps it on any state it claims in `beforeEnqueue` and matches on
   * it in `afterComplete`, so a TTL-reclaimed recalc key cannot let a stale run's completion
   * release a successor's claim. The framework carries one context instance from `beforeEnqueue`
   * through completion, so the token a gate reads at release is the one it claimed with.
   * @return the per-invocation run token
   */
  public String getRunToken() {
    return this.runToken;
  }

  private static String deriveRecalcKey(Schema.SObjectType calcItemType, List<Rollup__mdt> rollupMetadata) {
    List<String> developerNames = new List<String>();
    for (Rollup__mdt meta : rollupMetadata) {
      developerNames.add(meta.DeveloperName == null ? '' : meta.DeveloperName);
    }
    developerNames.sort();
    String calcItemPart = calcItemType == null ? '' : calcItemType.toString();
    return calcItemPart + '|' + String.join(developerNames, ',');
  }
}
