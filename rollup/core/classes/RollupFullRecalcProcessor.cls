@SuppressWarnings('PMD.AvoidGlobalModifier')
global abstract without sharing class RollupFullRecalcProcessor extends RollupAsyncProcessor.QueueableProcessor {
  protected final List<Rollup__mdt> rollupMetas;
  protected final Set<String> objIds = new Set<String>();
  protected String queryString;

  private final RollupFullRecalcProcessor postProcessor;
  private final Map<Id, SObject> parentRecordsToClear = new Map<Id, SObject>();
  protected final List<RollupFullRecalcProcessor> cabooses = new List<RollupFullRecalcProcessor>();
  private final Set<String> jobIds = new Set<String>();
  private Map<Schema.SObjectType, Set<Id>> typeToOldIntermediateGrandparents;
  private Boolean hasProcessedParentRecords = false;
  private RollupFullRecalcGate fullRecalcGate;
  private RollupFullRecalcContext fullRecalcContext;
  private Boolean hasNotifiedGate = false;

  private RollupFullRecalcProcessor(InvocationPoint invokePoint) {
    super(invokePoint);
  }

  @SuppressWarnings('PMD.ExcessiveParameterList')
  protected RollupFullRecalcProcessor(
    String queryString,
    InvocationPoint invokePoint,
    List<Rollup__mdt> rollupMetas,
    SObjectType calcItemType,
    Set<String> recordIds,
    RollupFullRecalcProcessor postProcessor
  ) {
    super(invokePoint);
    this.isFullRecalc = true;
    this.calcItemType = calcItemType;
    this.queryString = queryString;
    this.rollupMetas = rollupMetas;
    this.recordIds = recordIds;
    this.postProcessor = postProcessor;
    this.processMetadata();
  }

  public void addCaboose(RollupFullRecalcProcessor caboose) {
    this.cabooses.add(caboose);
  }

  /**
   * @description Carries the full-recalc gate and the context captured at `beforeEnqueue`
   * through to terminal completion, so the release keys the same logical recalc.
   * @param gate the resolved gate, or null when no gate is registered
   * @param context the recalc context captured when the gate proceeded
   */
  public void setFullRecalcGate(RollupFullRecalcGate gate, RollupFullRecalcContext context) {
    this.fullRecalcGate = gate;
    this.fullRecalcContext = context;
  }

  /**
   * @description Notifies the gate that this recalc has terminally completed, exactly once
   * per logical recalc. Fails open: a throwing `afterComplete` is contained so it never breaks
   * the finalizer.
   *
   * `hasNotifiedGate` is a per-INSTANCE latch, which is what the cursor chain needs — each page's
   * Queueable is the serialized previous instance, so the latch travels with it. It does NOT span a
   * sibling copy, so every release site must be one that only the owning processor reaches. Both
   * current sites qualify; see SEAM.md rule 6 for why a delegated inner rollup cannot reach one.
   */
  public void notifyGateComplete() {
    if (this.fullRecalcGate == null || this.hasNotifiedGate) {
      return;
    }
    this.hasNotifiedGate = true;
    try {
      this.fullRecalcGate.afterComplete(this.fullRecalcContext);
    } catch (Exception ex) {
      RollupLogger.Instance.log('full recalc gate afterComplete threw ' + ex.getTypeName() + ', continuing', ex, System.LoggingLevel.WARN);
    }
  }

  public void addMetadata(Rollup__mdt meta) {
    this.rollupMetas.add(meta);
  }

  public void setQuery(String replacementQuery) {
    this.queryString = replacementQuery;
  }

  public SObjectType getCalcItemType() {
    return this.calcItemType;
  }

  public virtual RollupState getState() {
    return null;
  }

  global override Rollup addLimit(Integer limitAmount, Schema.SObjectField calcItemRollupField) {
    for (Rollup__mdt rollupMeta : this.rollupMetas) {
      this.addLimitToMetadata(rollupMeta, limitAmount, calcItemRollupField);
    }
    return this;
  }

  global override Rollup addOrderBys(List<RollupOrderBy__mdt> orderBys, Schema.SObjectField calcItemRollupField) {
    for (Integer index = 0; index < this.rollupMetas.size(); index++) {
      Rollup__mdt rollupMeta = this.addOrderBys(this.rollupMetas[index], orderBys, calcItemRollupField);
      this.rollupMetas.set(index, rollupMeta);
    }
    return this;
  }

  global override Rollup modifyMetadata(Rollup__mdt template) {
    this.modifyMetadata(this.rollupMetas, template);
    return this;
  }

  public void finish() {
    this.jobIds.add(this.jobId);
    if (this.cabooses.isEmpty() == false) {
      RollupFullRecalcProcessor conductor = this.cabooses.remove(0);
      conductor.jobIds.add(this.jobId);
      for (Rollup__mdt meta : conductor.rollupMetas) {
        conductor.storeUniqueParentFields(meta);
      }
      for (RollupFullRecalcProcessor caboose : this.cabooses) {
        conductor.finalizer = conductor.finalizer ?? this.finalizer;
        conductor.finalizer.addCaboose(caboose);
      }
      if (this.isBatch()) {
        conductor.startAsyncWork();
      } else {
        this.finalizer.addCaboose(conductor);
      }
    } else {
      if (this.postProcessor != null) {
        this.logger.log('Post processor added as caboose', this.postProcessor, System.LoggingLevel.INFO);
        this.finalizer.addCaboose(this.postProcessor);
      }
      this.getState()?.cleanup(this.jobIds);
    }
    if (this.hasProcessedParentRecords == false) {
      List<SObject> parentRecords = new List<SObject>();
      this.processParentFieldsToReset(parentRecords);
      this.getDML().doUpdate(parentRecords);
    }
  }

  public Set<String> getRecordIdentifiers() {
    return new Set<String>(this.recordIds);
  }

  public void trackParentRecord(SObject parent) {
    this.postProcessor?.recordIds.add(parent.Id);
  }

  public void storeParentFieldsToClear(List<SObject> parentRecordsToClear) {
    this.parentRecordsToClear.putAll(parentRecordsToClear);
  }

  public void processParentFieldsToReset(List<SObject> relatedParentRecords) {
    if (this.hasProcessedParentRecords || this.rollupControl.ShouldSkipResettingParentFields__c == true) {
      return;
    }
    this.hasProcessedParentRecords = true;
    Map<Id, SObject> relatedParentRecordsMap = new Map<Id, SObject>(relatedParentRecords);
    for (Rollup__mdt meta : this.rollupMetas) {
      Object defaultVal = this.getDefaultValue(meta);
      for (SObject parentRecordToReset : this.parentRecordsToClear.values()) {
        if (parentRecordToReset.getSObjectType().toString() != meta.LookupObject__c) {
          continue;
        }
        SObject relatedParentRecord = relatedParentRecordsMap.get(parentRecordToReset.Id);
        if (relatedParentRecord == null) {
          relatedParentRecord = RollupCurrencyInfo.createNewRecord(parentRecordToReset);
          relatedParentRecordsMap.put(parentRecordToReset.Id, relatedParentRecord);
        }
        relatedParentRecord.put(meta.RollupFieldOnLookupObject__c, defaultVal);
      }
    }
    relatedParentRecords.clear();
    relatedParentRecords.addAll(relatedParentRecordsMap.values());
    this.parentRecordsToClear.clear();
  }

  public void setOldIntermediateGrandparents(Map<Schema.SObjectType, Set<Id>> typeToOldIntermediateGrandparents) {
    this.typeToOldIntermediateGrandparents = typeToOldIntermediateGrandparents;
  }

  public Map<Schema.SObjectType, Set<Id>> getOldIntermediateGrandparents() {
    return this.typeToOldIntermediateGrandparents ?? new Map<Schema.SObjectType, Set<Id>>();
  }

  protected override RollupRepository preStart() {
    return new RollupRepository(this.runAsMode).setArg(this.objIds).setArg('recordIds', this.recordIds).setQuery(this.queryString);
  }

  protected override void releaseFullRecalcGate() {
    this.notifyGateComplete();
    super.releaseFullRecalcGate();
  }

  protected List<RollupAsyncProcessor> getDelegatedFullRecalcRollups(List<SObject> calcItems) {
    for (Schema.SObjectType intermediateGrandparent : this.getOldIntermediateGrandparents().keySet()) {
      for (Id resetId : this.getOldIntermediateGrandparents().get(intermediateGrandparent)) {
        this.parentRecordsToClear.put(resetId, resetId.getSObjectType().newSObject(resetId));
      }
    }
    RollupAsyncProcessor processor = this.getAsyncRollup(this.rollupMetas, this.calcItemType, calcItems, new Map<Id, SObject>(), null, this.invokePoint);
    for (Rollup innerRoll : this.rollups) {
      if (innerRoll.getTypeName() == this.getTypeName()) {
        this.cabooses.add((RollupFullRecalcProcessor) innerRoll);
      }
    }
    for (RollupAsyncProcessor innerRoll : processor.rollups) {
      innerRoll.fullRecalcProcessor = this;
      innerRoll.isFullRecalc = this.getShouldResetParentRecordsDuringRecalculation();
      innerRoll.calcItems = calcItems;
    }
    this.fullRecalcProcessor = this;
    return processor.rollups;
  }

  protected virtual Boolean getShouldResetParentRecordsDuringRecalculation() {
    return true;
  }

  protected virtual override Map<String, String> customizeToStringEntries(Map<String, String> props) {
    super.customizeToStringEntries(props);
    Integer numberOfRollups = this.rollupMetas?.size();
    this.addToMap(props, 'Rollup Metadata', numberOfRollups > 5 ? (Object) numberOfRollups : (Object) this.rollupMetas);
    this.addToMap(props, 'Query String', this.queryString);
    this.addToMap(props, 'Caboose Count', this.cabooses.size());
    this.addToMap(props, 'Inner rollups', numberOfRollups);
    return props;
  }

  protected override String getHashedContents() {
    return String.valueOf(this.rollupMetas);
  }

  protected override Boolean getCanRollupWithoutCustomSetting() {
    Boolean canRollupWithoutCustomSetting = false;
    for (Rollup__mdt rollupMeta : this.rollupMetas) {
      canRollupWithoutCustomSetting = rollupMeta.ShouldRunWithoutCustomSettingEnabled__c;
      // all included rollups need to have the override enabled; if even one does NOT, we can stop
      if (canRollupWithoutCustomSetting == false) {
        break;
      }
    }
    return canRollupWithoutCustomSetting;
  }

  private void processMetadata() {
    for (Rollup__mdt meta : this.rollupMetas) {
      if (meta.RollupControl__c != null) {
        RollupControl__mdt specificControl = this.getSpecificControl(meta.RollupControl__c);
        this.overrideParentRollupControlValues(specificControl);
      }
      this.runAsMode = RollupMetaPicklists.getAccessLevel(meta);
    }
  }
}
