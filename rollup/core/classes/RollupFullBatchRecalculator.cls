public without sharing virtual class RollupFullBatchRecalculator extends RollupFullRecalcProcessor {
  private final RollupState state = new RollupState();
  // @TestVisible test seam: lets a unit test inject a fake CalcItemRetriever so
  // FullRecalcFinalizer.handleSuccess's paging-vs-terminal branch can be driven without a
  // live Database.getCursor. Mirrors the package's existing @TestVisible mocks.
  @TestVisible
  private CalcItemRetriever retriever;

  private static final Integer DEFAULT_CHUNK_SIZE = 500;

  public class NonResettingBulkFullRecalc extends RollupFullBatchRecalculator {
    @SuppressWarnings('PMD.ExcessiveParameterList')
    public NonResettingBulkFullRecalc(String queryString, InvocationPoint invokePoint, List<Rollup__mdt> rollupMetas, SObjectType calcItemType) {
      super(queryString, invokePoint, rollupMetas, calcItemType, new Set<String>(), null);
    }

    public override Boolean getShouldResetParentRecordsDuringRecalculation() {
      return false;
    }
  }

  @SuppressWarnings('PMD.ExcessiveParameterList')
  public RollupFullBatchRecalculator(
    String queryString,
    InvocationPoint invokePoint,
    List<Rollup__mdt> rollupMetas,
    SObjectType calcItemType,
    Set<String> recordIds,
    RollupFullRecalcProcessor postProcessor
  ) {
    super(RollupQueryBuilder.Current.getAllRowSafeQuery(calcItemType, queryString), invokePoint, rollupMetas, calcItemType, recordIds, postProcessor);
    this.rollupControl.BatchChunkSize__c = this.rollupControl.BatchChunkSize__c ?? DEFAULT_CHUNK_SIZE;
  }

  public override RollupState getState() {
    if (this.rollupControl.ShouldUseJSONSerializationStrategy__c == true) {
      this.state.setSerializationStrategy(new RollupState.JSONSerializationStrategy());
    }
    return this.state;
  }

  protected override void performWork() {
    this.process(this.getDelegatedFullRecalcRollups(this.calcItems));
  }

  protected override Boolean isBatch() {
    return true;
  }

  protected override List<RollupAsyncProcessor> transformFullRecalcRollups() {
    if (this.isProcessed == false && this.rollupControl.ShouldRunAs__c == RollupMetaPicklists.ShouldRunAs.Synchronous && System.isBatch() == false) {
      this.startAsyncWork();
    }
    return new List<RollupAsyncProcessor>();
  }

  protected virtual override String getTypeName() {
    return RollupFullBatchRecalculator.class.getName();
  }

  @SuppressWarnings('PMD.ApexCRUDViolation')
  protected virtual override String startAsyncWork() {
    this.logger.setExistingStack();
    if (this.finalizer != null) {
      while (this.cabooses.isEmpty() == false) {
        this.finalizer.addCaboose(this.cabooses.remove(0));
      }
    }
    if (this.retriever == null) {
      try {
        this.retriever = new CursorBasedRetriever(this.preStart(), this.rollupControl);
      } catch (Exception ex) {
        this.logger.log('cursor use disallowed', ex, System.LoggingLevel.WARN);
        return System.enqueueJob(new FullBatchQueueableFailsafe(this));
      }
    }

    this.calcItems = this.retriever.fetch();
    String jobId = super.startAsyncWork();
    insert new RollupState__c(RelatedJobId__c = jobId);
    return jobId;
  }

  private String runBatch() {
    return this.startBatchProcessor();
  }

  @TestVisible
  protected override RollupFinalizer getFinalizer() {
    return new FullRecalcFinalizer(this);
  }

  @TestVisible
  private interface CalcItemRetriever {
    List<SObject> fetch();
    Boolean shouldContinue();
  }

  private class CursorBasedRetriever implements CalcItemRetriever {
    private final Database.Cursor cursor;
    private Integer countOfRecordsToReturn;
    private Integer currentPosition = 0;

    public CursorBasedRetriever(RollupRepository repo, RollupControl__mdt control) {
      this.cursor = repo.getCursor();
      this.countOfRecordsToReturn = control.BatchChunkSize__c.intValue();
    }

    public List<SObject> fetch() {
      if (this.countOfRecordsToReturn + this.currentPosition > this.cursor.getNumRecords()) {
        this.countOfRecordsToReturn = this.cursor.getNumRecords() - this.currentPosition;
      }
      List<SObject> fetchedRecords = this.cursor.fetch(this.currentPosition, this.countOfRecordsToReturn);
      this.currentPosition += this.countOfRecordsToReturn;
      return fetchedRecords;
    }

    public Boolean shouldContinue() {
      return this.currentPosition < this.cursor.getNumRecords();
    }
  }

  private class FullBatchQueueableFailsafe implements System.Queueable {
    private final RollupFullBatchRecalculator roll;

    public FullBatchQueueableFailsafe(RollupFullBatchRecalculator roll) {
      this.roll = roll;
    }

    public void execute(QueueableContext qc) {
      this.roll.runBatch();
    }
  }

  private class FullRecalcFinalizer extends RollupFinalizer {
    private final RollupFullBatchRecalculator conductor;
    public FullRecalcFinalizer(RollupFullBatchRecalculator conductor) {
      this.conductor = conductor;
    }

    public override void handleSuccess() {
      if (this.conductor.retriever?.shouldContinue() ?? false) {
        this.conductor.startAsyncWork();
        this.hasAlreadyStartedConductor = true;
      } else {
        try {
          this.conductor.finish();
        } finally {
          // terminal success (no more cursor pages): release the full-recalc gate once, even if
          // finish()'s final bookkeeping DML throws — an in-finalizer throw is NOT routed to
          // handleUnhandledException, so without this finally a gate claim would strand.
          this.conductor.notifyGateComplete();
        }
      }
    }

    public override void handleUnhandledException(FinalizerContext fc) {
      // catchable failure: release the full-recalc gate once
      this.conductor.notifyGateComplete();
    }
  }
}
