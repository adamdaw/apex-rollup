/**
 * @description Tests for the generic, dormant full-recalc gate seam
 * (`RollupFullRecalcGate` / `RollupFullRecalcContext`) wired into
 * `Rollup.buildFullRecalcRollup`, the release hook on `RollupFinalizer`, and the
 * suppression substitute processor. Written tests-first per the VSDD Slice 1 ACs.
 * With no gate registered the framework must behave exactly as it does today
 * (fail-open); the seam keys on the rollup, never on the caller.
 */
@IsTest
public class RollupFullRecalcGateTests {
  // Apex forbids static fields on inner classes, so the stub-gate counters live here.
  static Integer beforeEnqueueCount = 0;
  static Integer afterCompleteCount = 0;
  static Integer claimCount = 0;
  static RollupFullRecalcContext capturedContext;
  static RollupFullRecalcContext capturedCompleteContext;
  static List<String> probeProceeded = new List<String>();
  static List<String> probeReleased = new List<String>();
  static Integer notAGateConstructions = 0;

  @TestSetup
  static void setup() {
    insert as system new Account(Name = RollupFullRecalcGateTests.class.getName());
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  // ---- Stub gates (resolvable via Type.forName by .class.getName()) ----

  public class ProceedGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      beforeEnqueueCount++;
      return RollupFullRecalcContext.Decision.PROCEED;
    }
    public void afterComplete(RollupFullRecalcContext context) {
      afterCompleteCount++;
    }
  }

  public class SuppressGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      beforeEnqueueCount++;
      return RollupFullRecalcContext.Decision.SUPPRESS;
    }
    @SuppressWarnings('PMD.EmptyStatementBlock')
    public void afterComplete(RollupFullRecalcContext context) {
    }
  }

  public class ThrowingGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      throw new IllegalArgumentException('gate blew up on beforeEnqueue');
    }
    public void afterComplete(RollupFullRecalcContext context) {
      throw new IllegalArgumentException('gate blew up on afterComplete');
    }
  }

  // Models the dangerous real-world shape: the policy claims its lock and THEN fails.
  public class ClaimThenThrowGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      claimCount++;
      throw new IllegalArgumentException('gate claimed its lock, then blew up');
    }
    public void afterComplete(RollupFullRecalcContext context) {
      afterCompleteCount++;
    }
  }

  // Suppresses whichever rollup group is consulted FIRST and proceeds for every one after it.
  // Consult order is build order, so this deterministically makes the substitute processors[0] —
  // the conductor slot in performBulkFullRecalc — without depending on map iteration order.
  public class SuppressFirstThenProceedGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      beforeEnqueueCount++;
      if (beforeEnqueueCount == 1) {
        return RollupFullRecalcContext.Decision.SUPPRESS;
      }
      probeProceeded.add(context.getRecalcKey());
      return RollupFullRecalcContext.Decision.PROCEED;
    }
    public void afterComplete(RollupFullRecalcContext context) {
      afterCompleteCount++;
      probeReleased.add(context.getRecalcKey());
    }
  }

  public class RecordingGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      capturedContext = context;
      return RollupFullRecalcContext.Decision.PROCEED;
    }
    public void afterComplete(RollupFullRecalcContext context) {
      capturedCompleteContext = context;
      afterCompleteCount++;
    }
  }

  public class SuppressAndCountCompleteGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      return RollupFullRecalcContext.Decision.SUPPRESS;
    }
    public void afterComplete(RollupFullRecalcContext context) {
      afterCompleteCount++;
    }
  }

  public class ProceedThenThrowOnCompleteGate implements RollupFullRecalcGate {
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      return RollupFullRecalcContext.Decision.PROCEED;
    }
    public void afterComplete(RollupFullRecalcContext context) {
      afterCompleteCount++;
      throw new IllegalArgumentException('gate blew up in afterComplete after recording');
    }
  }

  public class ConstructorThrowsGate implements RollupFullRecalcGate {
    public ConstructorThrowsGate() {
      throw new IllegalArgumentException('gate blew up in its no-arg constructor');
    }
    public RollupFullRecalcContext.Decision beforeEnqueue(RollupFullRecalcContext context) {
      return RollupFullRecalcContext.Decision.SUPPRESS;
    }
    @SuppressWarnings('PMD.EmptyStatementBlock')
    public void afterComplete(RollupFullRecalcContext context) {
    }
  }

  // A resolvable type that does NOT implement the gate interface.
  @SuppressWarnings('PMD.EmptyStatementBlock')
  // Resolves via Type.forName but does not implement the interface. The constructor records that it
  // ran, which is the whole point of the assignability guard: without it the resolver would call
  // newInstance() and execute an arbitrary misconfigured class's constructor before the cast failed.
  public class NotAGate {
    public NotAGate() {
      notAGateConstructions++;
    }
  }

  // Records that the base finalizer failure branch invoked the new virtual hook.
  public class RecordingFinalizer extends RollupFinalizer {
    public Boolean handleUnhandledExceptionCalled = false;
    protected override void handleUnhandledException(System.FinalizerContext fc) {
      this.handleUnhandledExceptionCalled = true;
    }
  }

  public class UnhandledContext implements System.FinalizerContext {
    public Id getAsyncApexJobId() {
      return RollupTestUtils.createId(AsyncApexJob.SObjectType);
    }
    public String getRequestId() {
      return System.Request.getCurrent().getRequestId();
    }
    public ParentJobResult getResult() {
      return ParentJobResult.UNHANDLED_EXCEPTION;
    }
    public Exception getException() {
      return new DmlException();
    }
  }

  public class SuccessContext implements System.FinalizerContext {
    public Id getAsyncApexJobId() {
      return RollupTestUtils.createId(AsyncApexJob.SObjectType);
    }
    public String getRequestId() {
      return System.Request.getCurrent().getRequestId();
    }
    public ParentJobResult getResult() {
      return ParentJobResult.SUCCESS;
    }
    public Exception getException() {
      return null;
    }
  }

  // ---- Helpers ----

  // Registers the gate the way a real org would: the parameter ATTACHED to the plugin record.
  // Every shipped RollupPluginParameter__mdt sets RollupPlugin__c, so a mock with a null plugin Id
  // and an unattached parameter would slip through getMatchingParameters' tolerance branch and
  // prove nothing about the scoping — the whole suite would pass with or without it.
  static void registerGate(String gateClassName) {
    Id gatePluginId = RollupTestUtils.createId(RollupPlugin__mdt.SObjectType);
    RollupPlugin.pluginMocks = new List<RollupPlugin__mdt>{ new RollupPlugin__mdt(Id = gatePluginId, DeveloperName = Rollup.FULL_RECALC_GATE_NAME) };
    // DeveloperName matters too: resolution matches the parameter by name within the parameters
    // scoped to the gate plugin, so a differently-named parameter no longer activates the gate.
    RollupPlugin.parameterMock = new RollupPluginParameter__mdt(
      DeveloperName = Rollup.FULL_RECALC_GATE_PARAM_NAME,
      Value__c = gateClassName,
      RollupPlugin__c = gatePluginId
    );
  }

  // THREE rollups on three DIFFERENT calc-item types, so transformWrappedMetadataToFullRecalcRollups
  // returns three processors and the conductor-promotion branch of performBulkFullRecalc is reached
  // with a non-empty tail. Two would also reach the branch, but after `remove(0)` the tail is empty
  // and the substitute's `rollups.addAll(...)` becomes a no-op that no assertion can see.
  static List<Rollup__mdt> bulkMetasForThreeCalcItemTypes() {
    return new List<Rollup__mdt>{
      new Rollup__mdt(
        DeveloperName = 'Contact_To_Account_Count',
        CalcItem__c = 'Contact',
        LookupObject__c = 'Account',
        LookupFieldOnCalcItem__c = 'AccountId',
        LookupFieldOnLookupObject__c = 'Id',
        RollupFieldOnCalcItem__c = 'LastName',
        RollupFieldOnLookupObject__c = 'NumberOfEmployees',
        RollupOperation__c = 'COUNT'
      ),
      new Rollup__mdt(
        DeveloperName = 'Opportunity_To_Account_Sum',
        CalcItem__c = 'Opportunity',
        LookupObject__c = 'Account',
        LookupFieldOnCalcItem__c = 'AccountId',
        LookupFieldOnLookupObject__c = 'Id',
        RollupFieldOnCalcItem__c = 'Amount',
        RollupFieldOnLookupObject__c = 'AnnualRevenue',
        RollupOperation__c = 'SUM'
      ),
      new Rollup__mdt(
        DeveloperName = 'Application_To_Parent_Application_Sum',
        CalcItem__c = 'Application__c',
        LookupObject__c = 'ParentApplication__c',
        LookupFieldOnCalcItem__c = 'ParentApplication__c',
        LookupFieldOnLookupObject__c = 'Id',
        RollupFieldOnCalcItem__c = 'Engagement_Score__c',
        RollupFieldOnLookupObject__c = 'Engagement_Rollup__c',
        RollupOperation__c = 'SUM'
      )
    };
  }

  static List<Rollup__mdt> concatMetas() {
    return new List<Rollup__mdt>{
      new Rollup__mdt(
        DeveloperName = 'Child_To_Parent_Concat',
        CalcItem__c = 'RollupChild__c',
        LookupObject__c = 'RollupParent__c',
        LookupFieldOnCalcItem__c = 'RollupParent__c',
        LookupFieldOnLookupObject__c = 'Id',
        RollupFieldOnCalcItem__c = 'Name',
        RollupFieldOnLookupObject__c = 'Name',
        RollupOperation__c = 'CONCAT'
      )
    };
  }

  static List<Rollup__mdt> grandparentMetas() {
    return new List<Rollup__mdt>{
      new Rollup__mdt(
        DeveloperName = 'Contact_To_Account_Grandparent',
        CalcItem__c = 'Contact',
        GrandparentRelationshipFieldPath__c = 'ReportsTo.Account.Name',
        LookupFieldOnCalcItem__c = 'ReportsToId',
        LookupFieldOnLookupObject__c = 'Id',
        LookupObject__c = 'Account',
        RollupFieldOnCalcItem__c = 'FirstName',
        RollupFieldOnLookupObject__c = 'Name',
        RollupOperation__c = 'CONCAT'
      )
    };
  }

  static RollupFullRecalcContext buildContext() {
    return new RollupFullRecalcContext(RollupChild__c.SObjectType, concatMetas(), new Set<String>{ 'anId' }, 5, Rollup.InvocationPoint.FROM_APEX);
  }

  static RollupFullRecalcProcessor stubProcessor() {
    return new RollupParentResetProcessor(new List<Rollup__mdt>(), null, '', new Set<String>(), Rollup.InvocationPoint.FROM_APEX);
  }

  // A real cursor-consumer processor, built the way the framework builds it.
  static RollupFullBatchRecalculator buildBatchRecalc() {
    return new RollupFullBatchRecalculator(
      'SELECT Id, Name, RollupParent__c FROM RollupChild__c',
      Rollup.InvocationPoint.FROM_APEX,
      concatMetas(),
      RollupChild__c.SObjectType,
      new Set<String>(),
      null
    );
  }

  // Fake retrievers injected via the @TestVisible seam to choose the paging vs terminal branch.
  // Two intent-named types rather than one taking a boolean, so a call site reads as the branch it
  // forces — which is what every `new TerminalRetriever() // force the terminal branch` comment was
  // compensating for.
  public class PagingRetriever implements RollupFullBatchRecalculator.CalcItemRetriever {
    public List<SObject> fetch() {
      return new List<SObject>();
    }
    public Boolean shouldContinue() {
      return true;
    }
  }

  public class TerminalRetriever implements RollupFullBatchRecalculator.CalcItemRetriever {
    public List<SObject> fetch() {
      return new List<SObject>();
    }
    public Boolean shouldContinue() {
      return false;
    }
  }

  // Overrides startAsyncWork so the non-terminal handleSuccess branch does not enqueue a real
  // batch (which would trip aer's cursor/JSON simulator bug); the terminal branch is untouched.
  public class NoEnqueueBatchRecalc extends RollupFullBatchRecalculator {
    public NoEnqueueBatchRecalc() {
      super(
        'SELECT Id, Name, RollupParent__c FROM RollupChild__c',
        Rollup.InvocationPoint.FROM_APEX,
        concatMetas(),
        RollupChild__c.SObjectType,
        new Set<String>(),
        null
      );
    }
    protected override String startAsyncWork() {
      return this.getNoProcessId();
    }
  }

  // Forces the terminal finish()'s parent-reset DML to throw, so we can prove the gate is still
  // released when finish() fails on the SUCCESS path (the try/finally guarantee).
  public class ThrowingUpdater extends RollupSObjectUpdater {
    public override void doUpdate(List<SObject> recordsToUpdate) {
      throw new IllegalArgumentException('simulated terminal finish() DML failure');
    }
  }

  // ---- AC1: no gate registered leaves the processor choice unchanged ----
  @IsTest
  static void noGateRegisteredReturnsBatchRecalculatorUnchanged() {
    // pinned to mocks only: otherwise this consults the host org's real policy inside a test
    // transaction and goes red in exactly the org that registers the gate
    RollupPlugin.onlyUseMockPlugins = true;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'no gate full recalc');

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Test.stopTest();

    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupFullBatchRecalculator, 'no gate => the cursor batch recalculator is returned unchanged');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'no gate must never substitute a suppressed processor');
  }

  // ---- (real path) SUPPRESS substitutes the built cursor processor via performBulkFullRecalc ----
  @IsTest
  static void realPathSuppressSubstitutesBuiltProcessor() {
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'suppress real path');
    registerGate(SuppressGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    // read the substitution synchronously, before any async logging runs at stopTest
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupSuppressedFullRecalc, 'SUPPRESS must substitute the built cursor processor on the real entry path');
    Assert.isFalse(cached instanceof RollupFullBatchRecalculator, 'the substitute must not be the cursor batch recalculator');
    // INSIDE the test block on purpose: Test.stopTest() restores the outer limit context, so a
    // getQueueableJobs() assertion after it reads zero whatever the substitute did. This one is the
    // only thing standing between a suppressed recalc and actually running.
    Assert.areEqual(0, Limits.getQueueableJobs(), 'the suppressed substitute enqueues no async work through the real entry path');
    Test.stopTest();
  }

  // ---- (real path) PROCEED keeps the cursor processor AND consults the gate exactly once ----
  @IsTest
  static void realPathProceedKeepsBatchRecalculatorAndConsults() {
    beforeEnqueueCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'proceed real path');
    registerGate(ProceedGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupFullBatchRecalculator, 'PROCEED must leave the cursor batch recalculator in place');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'PROCEED must not substitute a suppressed processor');
    Assert.areEqual(1, beforeEnqueueCount, 'the gate must be consulted exactly once on the real entry path');
    Test.stopTest();
  }

  // ---- (real finalizer) terminal-success release fires afterComplete exactly once ----
  @IsTest
  static void realFinalizerSuccessBranchReleasesOnce() {
    afterCompleteCount = 0;
    RollupFullBatchRecalculator batch = buildBatchRecalc();
    batch.setFullRecalcGate(new ProceedGate(), buildContext());
    RollupFinalizer finalizer = batch.getFinalizer();

    Test.startTest();
    // no retriever has been started => shouldContinue() is false => terminal finish() else-branch
    finalizer.execute(new SuccessContext());
    Test.stopTest();

    Assert.areEqual(1, afterCompleteCount, 'the real FullRecalcFinalizer must release the gate exactly once on terminal success');
  }

  // ---- (real finalizer) failure branch releases afterComplete ----
  @IsTest
  static void realFinalizerFailureBranchReleasesOnce() {
    afterCompleteCount = 0;
    RollupFullBatchRecalculator batch = buildBatchRecalc();
    batch.setFullRecalcGate(new ProceedGate(), buildContext());
    RollupFinalizer finalizer = batch.getFinalizer();

    Test.startTest();
    finalizer.execute(new UnhandledContext());
    Test.stopTest();

    Assert.areEqual(1, afterCompleteCount, 'the real FullRecalcFinalizer must release the gate on the UNHANDLED_EXCEPTION branch');
  }

  // ---- no double-notify — the failure hook must NOT fire on the success branch ----
  @IsTest
  static void successBranchDoesNotInvokeHandleUnhandledException() {
    RecordingFinalizer finalizer = new RecordingFinalizer();

    Test.startTest();
    finalizer.execute(new SuccessContext());
    Test.stopTest();

    Assert.isFalse(finalizer.handleUnhandledExceptionCalled, 'handleUnhandledException must fire only on the exception branch, never on success');
  }

  // ---- (real path) a resolvable-but-non-assignable class fails open, no ClassCastException ----
  @IsTest
  static void nonAssignableGateFailsOpenOnRealPath() {
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'not a gate real path');
    notAGateConstructions = 0;
    // NotAGate resolves via Type.forName but does not implement RollupFullRecalcGate
    registerGate(NotAGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupFullBatchRecalculator, 'a non-assignable gate class must resolve null and proceed unchanged');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'a non-assignable gate class must never substitute a processor');
    // pins the guard rather than the outcome: dropping the isAssignableFrom check also fails open,
    // via the cast throwing into the catch — but only after newInstance() has run this constructor.
    Assert.areEqual(0, notAGateConstructions, 'a class that cannot be a gate must never be instantiated');
    Test.stopTest();
  }

  // ---- (real path) a gate whose no-arg constructor throws fails open ----
  @IsTest
  static void constructorThrowingGateFailsOpenOnRealPath() {
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'ctor throws real path');
    registerGate(ConstructorThrowsGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupFullBatchRecalculator, 'a gate whose constructor throws must resolve null and proceed unchanged');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'a throwing-constructor gate must never substitute a processor');
    Test.stopTest();
  }

  // ---- (real path) a gate whose beforeEnqueue throws fails open ----
  @IsTest
  static void beforeEnqueueThrowingGateFailsOpenOnRealPath() {
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'beforeEnqueue throws real path');
    registerGate(ThrowingGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupFullBatchRecalculator, 'a gate whose beforeEnqueue throws must be contained and proceed unchanged');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'a throwing beforeEnqueue must never substitute a processor');
    Test.stopTest();
  }

  // ---- (real path) the deferred/small-set branch is never consulted ----
  @IsTest
  static void deferredPathIsNotConsultedOnRealPath() {
    beforeEnqueueCount = 0;
    // high batching threshold + a small set => shouldQueue == true => deferred (non-cursor) processor.
    // FROM_FULL_RECALC_APEX keeps isFullRecalcApp false so the count==0 parent-reset early-return is not taken.
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 5000);
    insert as system new Contact(LastName = 'deferred real path');
    registerGate(SuppressGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_APEX.name());
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupDeferredFullRecalcProcessor, 'a small set under a high batching threshold must produce the deferred processor');
    Assert.isFalse(cached instanceof RollupFullBatchRecalculator, 'the deferred processor is not the cursor consumer');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'the deferred path must never be substituted');
    Assert.areEqual(0, beforeEnqueueCount, 'the gate must not be consulted off the cursor path (it pairs no afterComplete there)');
    Test.stopTest();
  }

  // ---- (real finalizer, mocked retriever) afterComplete fires ONCE at terminal completion, NOT per cursor page ----
  // The distinguishing logic lives in FullRecalcFinalizer.handleSuccess:
  //   if (conductor.retriever?.shouldContinue()) { startAsyncWork(); } else { finish(); notifyGateComplete(); }
  // A fake retriever drives both branches without a live Database.getCursor; the NoEnqueueBatchRecalc subclass
  // no-ops startAsyncWork so the paging branch does not enqueue a real batch (which would trip aer's sim bug).
  // A per-page-fire (latch) impl would show count==1 after the paging call; we assert it is 0 there.
  @IsTest
  static void afterCompleteFiresOnceAtTerminalNotPerPage() {
    afterCompleteCount = 0;
    NoEnqueueBatchRecalc batch = new NoEnqueueBatchRecalc();
    batch.setFullRecalcGate(new ProceedGate(), buildContext());
    RollupFinalizer finalizer = batch.getFinalizer();

    Test.startTest();
    // non-terminal page: shouldContinue() == true => still paging => no release
    batch.retriever = new PagingRetriever();
    finalizer.execute(new SuccessContext());
    Assert.areEqual(0, afterCompleteCount, 'afterComplete must NOT fire while the cursor is still paging');
    // terminal page: shouldContinue() == false => finish() else-branch => release exactly once
    batch.retriever = new TerminalRetriever();
    finalizer.execute(new SuccessContext());
    Assert.areEqual(1, afterCompleteCount, 'afterComplete must fire exactly once at terminal completion, not per page');
    Test.stopTest();
  }

  // ---- (real finalizer) a throwing afterComplete is contained at the real terminal release site ----
  @IsTest
  static void afterCompleteThrowIsContainedAtRealSite() {
    afterCompleteCount = 0;
    RollupFullBatchRecalculator batch = buildBatchRecalc();
    batch.setFullRecalcGate(new ProceedThenThrowOnCompleteGate(), buildContext());
    RollupFinalizer finalizer = batch.getFinalizer();

    Test.startTest();
    // no retriever started => terminal branch => finish() + notifyGateComplete(); afterComplete throws
    finalizer.execute(new SuccessContext());
    Test.stopTest();

    // reaching here proves the throw was swallowed; the counter proves afterComplete was actually invoked
    Assert.areEqual(1, afterCompleteCount, 'afterComplete must have been invoked once, and its throw contained by notifyGateComplete');
  }

  // ---- (real path) a bogus, unresolvable gate class name fails open ----
  @IsTest
  static void bogusGateClassNameFailsOpenOnRealPath() {
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'bogus gate real path');
    // a name Type.forName cannot resolve
    registerGate('Totally_Bogus_Gate_Class_Name_9x7');

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Assert.areEqual(1, Rollup.CACHED_FULL_RECALCS.size(), 'exactly one full recalc processor should be cached');
    RollupFullRecalcProcessor cached = Rollup.CACHED_FULL_RECALCS.get(0);
    Assert.isTrue(cached instanceof RollupFullBatchRecalculator, 'a bogus, unresolvable gate class name must resolve null and proceed unchanged');
    Assert.isFalse(cached instanceof RollupSuppressedFullRecalc, 'a bogus gate class name must never substitute a processor');
    Test.stopTest();
  }

  // ---- (payload) the gate actually receives a correctly-populated RollupFullRecalcContext ----
  @IsTest
  static void gateReceivesPopulatedContextOnRealPath() {
    capturedContext = null;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'context payload real path');
    registerGate(RecordingGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    // the gate is consulted synchronously while the processor is built, before the async run
    Assert.isNotNull(capturedContext, 'the gate must receive a RollupFullRecalcContext');
    Assert.areEqual(Contact.SObjectType, capturedContext.getCalcItemType(), 'context exposes the calc-item type');
    List<Rollup__mdt> metas = capturedContext.getRollupMetadata();
    Assert.areEqual(1, metas.size(), 'context carries the rollup group');
    Assert.areEqual('Contact_To_Account_Grandparent', metas[0].DeveloperName, 'context carries the group DeveloperName');
    Assert.areEqual(Rollup.InvocationPoint.FROM_FULL_RECALC_LWC, capturedContext.getInvocationPoint(), 'context exposes the invocation point');
    Assert.areEqual(1, capturedContext.getRecordCount(), 'context exposes the exact record count for the single inserted calc item');
    Assert.isTrue(capturedContext.getRecordIds().isEmpty(), 'no parent ids were passed, so the context exposes an empty record-id set');
    String key = capturedContext.getRecalcKey();
    Assert.isNotNull(key, 'the derived recalc key must be non-null');
    Assert.areNotEqual('', key, 'the derived recalc key must be non-empty');
    // key is derived from the rollup group only: stable + caller-agnostic (same key for a different invoke point)
    RollupFullRecalcContext sameGroupDifferentCaller = new RollupFullRecalcContext(
      Contact.SObjectType,
      grandparentMetas(),
      new Set<String>{ 'someOtherParent' },
      9999,
      Rollup.InvocationPoint.FROM_SCHEDULED
    );
    Assert.areEqual(key, sameGroupDifferentCaller.getRecalcKey(), 'the recalc key is derived from the rollup group only — stable and caller-agnostic');
    Test.stopTest();
  }

  // ---- (real finalizer) failure branch with a THROWING afterComplete is contained ----
  @IsTest
  static void failureBranchAfterCompleteThrowIsContained() {
    afterCompleteCount = 0;
    RollupFullBatchRecalculator batch = buildBatchRecalc();
    batch.setFullRecalcGate(new ProceedThenThrowOnCompleteGate(), buildContext());
    RollupFinalizer finalizer = batch.getFinalizer();

    Test.startTest();
    // UNHANDLED_EXCEPTION branch -> handleUnhandledException override -> notifyGateComplete -> afterComplete throws
    finalizer.execute(new UnhandledContext());
    Test.stopTest();

    // reaching here proves the throw was contained; the counter proves afterComplete was actually invoked
    Assert.areEqual(1, afterCompleteCount, 'afterComplete must be invoked once on the failure branch and its throw contained');
  }

  // ---- a SUPPRESS-substituted processor never fires afterComplete (the winner owns the release) ----
  @IsTest
  static void suppressedSubstituteStaysSilent() {
    afterCompleteCount = 0;
    // no registerGate: applyFullRecalcGate takes the gate instance directly and never reads the
    // plugin registry. The gate below both suppresses AND would count an afterComplete if the
    // substitute wrongly released.
    RollupFullRecalcProcessor original = buildBatchRecalc();

    Test.startTest();
    RollupFullRecalcProcessor substitute = Rollup.applyFullRecalcGate(original, new SuppressAndCountCompleteGate(), buildContext());
    // the substitute carries no gate, so a completion notification must be a no-op
    substitute.notifyGateComplete();
    Test.stopTest();

    Assert.isTrue(substitute instanceof RollupSuppressedFullRecalc, 'precondition: the gate suppressed and substituted');
    Assert.areEqual(0, afterCompleteCount, 'the suppressed substitute must never fire afterComplete — the winner owns the release');
  }

  // ---- the Batchable failsafe completion path also releases the gate (container-agnostic) ----
  @IsTest
  static void batchableFailsafeCompletionReleasesGate() {
    afterCompleteCount = 0;
    RollupFullBatchRecalculator batch = buildBatchRecalc();
    batch.setFullRecalcGate(new ProceedGate(), buildContext());
    // deliberately NOT setting fullRecalcProcessor: the Batchable is not Database.Stateful, so the
    // instance that reaches finish() is deserialized from the state captured at
    // Database.executeBatch — before performWork ever assigns the self-reference. An end-to-end
    // trace of performBulkFullRecalc through the failsafe route confirms it arrives null. The
    // release therefore has to come from `this`, not from the field.

    Test.startTest();
    // the real Batchable success-completion entry point (a null context is handled internally)
    batch.finish((Database.BatchableContext) null);
    Test.stopTest();

    Assert.areEqual(1, afterCompleteCount, 'the Batchable failsafe completion path must release the gate exactly once');
  }

  // ---- the REAL performBulkFullRecalc build path arms the release (terminal success) ----
  @IsTest
  static void realEntryPathArmsReleaseOnSuccess() {
    afterCompleteCount = 0;
    capturedContext = null;
    capturedCompleteContext = null;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'real arm success');
    registerGate(RecordingGate.class.getName());

    Test.startTest();
    // FROM_FULL_RECALC_APEX keeps isFullRecalcApp false, so no parent-reset postProcessor is attached
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_APEX.name());
    // pull the batch armed by the REAL applyFullRecalcGate (no manual setFullRecalcGate)
    RollupFullBatchRecalculator batch = (RollupFullBatchRecalculator) Rollup.CACHED_FULL_RECALCS.get(0);
    batch.retriever = new TerminalRetriever();
    batch.getFinalizer().execute(new SuccessContext());
    Assert.areEqual(1, afterCompleteCount, 'the real build path must arm the release; terminal success fires afterComplete once');
    // F2(c): the context released to afterComplete is the SAME one delivered to beforeEnqueue (same recalc/key)
    Assert.isTrue(capturedCompleteContext === capturedContext, 'afterComplete receives the same context captured at beforeEnqueue');
    Test.stopTest();
  }

  // ---- the REAL build path arms the release on the failure branch too ----
  @IsTest
  static void realEntryPathArmsReleaseOnFailure() {
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'real arm failure');
    registerGate(RecordingGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_APEX.name());
    RollupFullBatchRecalculator batch = (RollupFullBatchRecalculator) Rollup.CACHED_FULL_RECALCS.get(0);
    batch.retriever = new TerminalRetriever();
    batch.getFinalizer().execute(new UnhandledContext());
    Assert.areEqual(1, afterCompleteCount, 'the real build path must arm the release; the failure branch fires afterComplete once');
    Test.stopTest();
  }

  // ---- a throwing terminal finish() on the SUCCESS path must STILL release the gate ----
  // Without try/finally the finish() throw skips notifyGateComplete() and is NOT routed to
  // handleUnhandledException (in-finalizer throw != job UNHANDLED_EXCEPTION) => a stranded gate claim.
  @IsTest
  static void terminalSuccessThrowingFinishStillReleasesGate() {
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'throwing finish release');
    registerGate(RecordingGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_APEX.name());
    RollupFullBatchRecalculator batch = (RollupFullBatchRecalculator) Rollup.CACHED_FULL_RECALCS.get(0);
    batch.retriever = new TerminalRetriever();
    Rollup.DML = new ThrowingUpdater(); // finish()'s parent-reset doUpdate throws
    Boolean finishThrew = false;
    try {
      batch.getFinalizer().execute(new SuccessContext());
    } catch (Exception ex) {
      finishThrew = true;
    } finally {
      Rollup.DML = new RollupSObjectUpdater(); // restore so the stopTest async flush is clean
    }
    // assert synchronously (mirrors realEntryPathArmsReleaseOnSuccess) — before any async flush
    Assert.isTrue(finishThrew, 'the throwing terminal finish() still propagates its exception');
    Assert.areEqual(1, afterCompleteCount, 'the gate must be released even when terminal finish() throws (try/finally), else a gate claim deadlocks');
    Test.stopTest();
  }

  // ---- Gate seam: the run token is minted, non-empty, and unique per context instance ----
  // Unlike the recalc key (stable + shared across concurrent duplicates of the same rollup group),
  // the run token is unique per invocation — that is the correlation a TTL-reclaimed key can't give.
  @IsTest
  static void runTokenIsMintedUniquePerContext() {
    RollupFullRecalcContext runA = buildContext();
    RollupFullRecalcContext runB = buildContext(); // same rollup group => same recalc key

    Test.startTest();
    Assert.isTrue(String.isNotBlank(runA.getRunToken()), 'the run token must be minted non-empty');
    Assert.areEqual(runA.getRecalcKey(), runB.getRecalcKey(), 'precondition: same rollup group => same recalc key');
    Assert.areNotEqual(
      runA.getRunToken(),
      runB.getRunToken(),
      'each context instance (one logical recalc invocation) must mint a distinct run token, even for the same recalc key'
    );
    Test.stopTest();
  }

  // ---- Gate seam: the run token is stable across the async hop (echoed unchanged to afterComplete) ----
  @IsTest
  static void runTokenIsStableFromBeforeEnqueueToAfterComplete() {
    capturedContext = null;
    capturedCompleteContext = null;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    insert as system new Contact(LastName = 'run token stable');
    registerGate(RecordingGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_APEX.name());
    RollupFullBatchRecalculator batch = (RollupFullBatchRecalculator) Rollup.CACHED_FULL_RECALCS.get(0);
    batch.retriever = new TerminalRetriever();
    batch.getFinalizer().execute(new SuccessContext());
    Assert.isNotNull(capturedContext, 'beforeEnqueue must have captured the context');
    Assert.areEqual(
      capturedContext.getRunToken(),
      capturedCompleteContext.getRunToken(),
      'afterComplete must receive the same run token minted at beforeEnqueue — the release matches on it'
    );
    Test.stopTest();
  }

  // ---- the recalc key discriminates between different rollup groups ----
  @IsTest
  static void recalcKeyDiscriminatesRollupGroups() {
    // group one: RollupChild__c / 'Child_To_Parent_Concat'
    RollupFullRecalcContext groupOne = new RollupFullRecalcContext(
      RollupChild__c.SObjectType,
      concatMetas(),
      new Set<String>(),
      1,
      Rollup.InvocationPoint.FROM_APEX
    );
    // group two: different calc-item type AND different DeveloperName
    RollupFullRecalcContext groupTwo = new RollupFullRecalcContext(
      Contact.SObjectType,
      grandparentMetas(),
      new Set<String>(),
      1,
      Rollup.InvocationPoint.FROM_APEX
    );
    // group three: same calc-item type as group one, different DeveloperName only
    List<Rollup__mdt> renamed = concatMetas();
    renamed[0].DeveloperName = 'Child_To_Parent_Sum';
    RollupFullRecalcContext groupThree = new RollupFullRecalcContext(
      RollupChild__c.SObjectType,
      renamed,
      new Set<String>(),
      1,
      Rollup.InvocationPoint.FROM_APEX
    );

    Test.startTest();
    Assert.areNotEqual(groupOne.getRecalcKey(), groupTwo.getRecalcKey(), 'different calc-item type + group must derive different keys');
    Assert.areNotEqual(
      groupOne.getRecalcKey(),
      groupThree.getRecalcKey(),
      'a different DeveloperName alone must derive a different key (a constant key would collide)'
    );
    Test.stopTest();
  }

  // ---- AC2: gate consulted before the processor is enqueued ----
  @IsTest
  static void gateConsultedProceedReturnsOriginalProcessor() {
    beforeEnqueueCount = 0;
    RollupFullRecalcProcessor original = buildBatchRecalc();

    Test.startTest();
    RollupFullRecalcProcessor result = Rollup.applyFullRecalcGate(original, new ProceedGate(), buildContext());
    Test.stopTest();

    Assert.areEqual(1, beforeEnqueueCount, 'beforeEnqueue must be consulted exactly once before returning the processor');
    Assert.isTrue(result == original, 'PROCEED must return the same processor the framework built');
    Assert.isFalse(result instanceof RollupSuppressedFullRecalc, 'PROCEED must not substitute a suppressed processor');
  }

  // ---- AC3: SUPPRESS returns a substitute, not the cursor processor ----
  @IsTest
  static void suppressReturnsSubstituteNotBatchRecalculator() {
    RollupFullRecalcProcessor original = buildBatchRecalc();

    Test.startTest();
    RollupFullRecalcProcessor result = Rollup.applyFullRecalcGate(original, new SuppressGate(), buildContext());
    String runResult = result.runCalc();
    // see realPathSuppressSubstitutesBuiltProcessor: after stopTest this reads the outer context
    Assert.areEqual(0, Limits.getQueueableJobs(), 'the suppressed substitute enqueues no async work');
    Test.stopTest();

    Assert.isTrue(result instanceof RollupSuppressedFullRecalc, 'SUPPRESS must return the no-op substitute');
    Assert.isFalse(result instanceof RollupFullBatchRecalculator, 'the substitute must not be a RollupFullBatchRecalculator');
    Assert.isFalse(result == original, 'the substitute must replace the original processor');
    Assert.areEqual(result.getNoProcessId(), runResult, 'the substitute performs no async work');
  }

  // ---- the kill switches abort AFTER the gate was consulted — release anyway ----
  @IsTest
  static void killSwitchReleasesTheClaimItNeverGotToUse() {
    beforeEnqueueCount = 0;
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    registerGate(ProceedGate.class.getName());
    insert as system new Contact(LastName = 'kill switch full recalc');
    // the shape an operator produces by pausing rollups during a data load. Update the EXISTING
    // org-default record from @TestSetup — a bare `upsert new RollupSettings__c(...)` leaves the
    // true one in place, the recalc runs normally and its finalizer releases, which makes this
    // whole test pass for the wrong reason.
    RollupSettings__c settings = RollupSettings__c.getInstance();
    settings.IsEnabled__c = false;
    upsert as system settings;

    Test.startTest();
    String processId = Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Test.stopTest();

    Assert.areEqual(1, beforeEnqueueCount, 'precondition: the gate was consulted at build time, before runCalc could bail');
    // name the switch, not just 'exiting early' — all three bail branches emit that substring, so
    // the looser assert would still pass if the fixture silently landed on a different one
    Assert.isTrue(
      processId.contains('IsEnabled__c is false'),
      'precondition: the IsEnabled__c kill switch aborted the recalc, so no finalizer will ever run. Got: ' + processId
    );
    Assert.areEqual(1, afterCompleteCount, 'a recalc aborted after the consult must still release — nothing downstream can');
  }

  // ---- the OTHER operator kill switch also releases ----
  @IsTest
  static void abortSwitchReleasesTheClaimItNeverGotToUse() {
    beforeEnqueueCount = 0;
    afterCompleteCount = 0;
    // the sibling of the IsEnabled__c switch, and the harder one: ingestRollupControlData prunes
    // aborted rollups out of the tree BEFORE runCalc's release walk runs, so the walk alone misses
    // a gate armed on one of them
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0, ShouldAbortRun__c = true);
    registerGate(ProceedGate.class.getName());
    insert as system new Contact(LastName = 'abort switch full recalc');

    Test.startTest();
    String processId = Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Test.stopTest();

    Assert.areEqual(1, beforeEnqueueCount, 'precondition: the gate was consulted at build time, before the control record could abort the run');
    // name the switch: 'exiting early' alone cannot tell this branch from the IsEnabled__c one
    Assert.isTrue(
      processId.contains('ShouldAbortRun__c set to true'),
      'precondition: ShouldAbortRun__c aborted the recalc, so no finalizer will ever run. Got: ' + processId
    );
    Assert.areEqual(1, afterCompleteCount, 'an aborted recalc must release even though it was pruned out of the tree before the walk');
  }

  // ---- the build-time no-op filter is what stops the other strand ----
  @IsTest
  static void zeroRecordRecalcIsNeverConsulted() {
    beforeEnqueueCount = 0;
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    registerGate(ProceedGate.class.getName());
    // deliberately no calc items: the processor is built, then transformWrappedMetadataToFullRecalcRollups
    // resets isNoOp and addRollup drops it, so no job and no finalizer ever exist for it. Consulting
    // it would take a claim with nothing left to release it — the build-time filter is load-bearing.
    //
    // FROM_FULL_RECALC_APEX, not the LWC point: the LWC/Flow points set isFullRecalcApp, and a
    // zero-record recalc under those returns the parent-reset processor before the gate block is
    // ever reached — which makes this test vacuous and green with the filter deleted.

    Test.startTest();
    Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_APEX.name());
    Test.stopTest();

    Assert.areEqual(0, beforeEnqueueCount, 'a recalc with nothing in scope must never be consulted — it is dropped before any finalizer could release it');
    Assert.areEqual(0, afterCompleteCount, 'nothing was claimed, so nothing should be released');
  }

  // ---- suppressing one rollup group must not cancel the others ----
  @IsTest
  static void suppressedConductorStillRunsTheOtherRollupGroups() {
    // three calc-item types, so performBulkFullRecalc promotes processors[0] to conductor and hangs
    // the other two off its rollups. The gate suppresses whichever lands first. Three and not two:
    // with two, the substitute's own `rollups.addAll(tail)` operates on an already-empty tail, so
    // deleting that line is invisible and the promotion is only half proven.
    Account parentAccount = [SELECT Id FROM Account WITH SYSTEM_MODE];
    insert as system new Contact(LastName = 'gate bulk contact', AccountId = parentAccount.Id);
    insert as system new Opportunity(
      Name = 'gate bulk opp',
      StageName = 'Prospecting',
      CloseDate = System.today(),
      AccountId = parentAccount.Id,
      Amount = 1000
    );
    ParentApplication__c parentApp = new ParentApplication__c(Name = 'gate bulk parent app', Account__c = parentAccount.Id);
    insert as system parentApp;
    insert as system new Application__c(Name = 'gate bulk app', ParentApplication__c = parentApp.Id, Engagement_Score__c = 7);

    // set AFTER the fixtures: these inserts fire CMT-driven rollups of their own, and those
    // overwrite Rollup.defaultControl. Set it first and every processor here takes the deferred
    // path, which is never gated — the gate would see nothing and the test would prove nothing.
    // MaxLookupRowsBeforeBatching__c = 0 forces the cursor path; ShouldRunAs__c left null keeps
    // performBulkFullRecalc's conductor-promotion branch in play.
    beforeEnqueueCount = 0;
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    registerGate(SuppressFirstThenProceedGate.class.getName());

    Test.startTest();
    Rollup.performBulkFullRecalc(bulkMetasForThreeCalcItemTypes(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Test.stopTest();

    Assert.areEqual(3, beforeEnqueueCount, 'precondition: the gate saw all three rollup groups');
    // order-independent: exactly one group was suppressed, so the other TWO must both be rolled up.
    // Before the fix the substitute short-circuited runCalc as conductor and none of them ran.
    Account rolledUp = [SELECT AnnualRevenue, NumberOfEmployees FROM Account WHERE Id = :parentAccount.Id WITH SYSTEM_MODE];
    Integer rolledUpParents = 0;
    if ([SELECT Engagement_Rollup__c FROM ParentApplication__c WHERE Id = :parentApp.Id WITH SYSTEM_MODE].Engagement_Rollup__c == 7) {
      rolledUpParents++;
    }
    if (rolledUp.AnnualRevenue == 1000) {
      rolledUpParents++;
    }
    if (rolledUp.NumberOfEmployees == 1) {
      rolledUpParents++;
    }
    Assert.areEqual(2, rolledUpParents, 'both groups the gate proceeded must still run when the suppressed one is promoted to conductor');
    // the release accounting, which is the whole point of the seam: one afterComplete per PROCEEDED
    // group, no more and no fewer. Asserting the keys and not just the count catches the failure
    // this replaced — a second release fired for the FIRST group's key while the second stranded.
    probeProceeded.sort();
    probeReleased.sort();
    Assert.areEqual(probeProceeded, probeReleased, 'exactly one release per proceeded group, keyed to that group');
  }

  // ---- ingestRollupControlData relocates a couldRunSync rollup OUT of this.rollups before the
  // bail arm walks the tree, so the release has to come from the pre-ingest snapshot ----
  @IsTest
  static void killSwitchReleasesAClaimRelocatedToTheSyncList() {
    beforeEnqueueCount = 0;
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(
      IsRollupLoggingEnabled__c = true,
      MaxLookupRowsBeforeBatching__c = 0,
      ShouldRunAs__c = RollupMetaPicklists.ShouldRunAs.Synchronous
    );
    registerGate(ProceedGate.class.getName());
    insert as system new Contact(LastName = 'sync relocation kill switch');
    RollupSettings__c settings = RollupSettings__c.getInstance();
    settings.IsEnabled__c = false;
    upsert as system settings;

    Test.startTest();
    String processId = Rollup.performBulkFullRecalc(grandparentMetas(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Test.stopTest();

    Assert.areEqual(1, beforeEnqueueCount, 'precondition: the gate was consulted at build time');
    Assert.isTrue(processId.contains('IsEnabled__c is false'), 'precondition: the kill switch aborted the recalc. Got: ' + processId);
    Assert.areEqual(1, afterCompleteCount, 'a claim relocated into the sync list must still be released on a bail');
  }

  // ---- the bail-out release must walk DOWN, not just release the processor whose
  // runCalc bailed. performBulkFullRecalc hangs the other groups off the conductor's `rollups`, so a
  // conductor-only release strands every group but the first. ----
  @IsTest
  static void killSwitchReleasesEveryGroupTheConductorCarries() {
    Account parentAccount = [SELECT Id FROM Account WITH SYSTEM_MODE];
    insert as system new Contact(LastName = 'gate walk contact', AccountId = parentAccount.Id);
    insert as system new Opportunity(
      Name = 'gate walk opp',
      StageName = 'Prospecting',
      CloseDate = System.today(),
      AccountId = parentAccount.Id,
      Amount = 1000
    );
    ParentApplication__c parentApp = new ParentApplication__c(Name = 'gate walk parent app', Account__c = parentAccount.Id);
    insert as system parentApp;
    insert as system new Application__c(Name = 'gate walk app', ParentApplication__c = parentApp.Id, Engagement_Score__c = 7);

    // set AFTER the fixtures, for the reason spelled out in the suppressed-conductor test below.
    beforeEnqueueCount = 0;
    afterCompleteCount = 0;
    Rollup.defaultControl = new RollupControl__mdt(IsRollupLoggingEnabled__c = true, MaxLookupRowsBeforeBatching__c = 0);
    registerGate(ProceedGate.class.getName());
    RollupSettings__c settings = RollupSettings__c.getInstance();
    settings.IsEnabled__c = false;
    upsert as system settings;

    Test.startTest();
    String processId = Rollup.performBulkFullRecalc(bulkMetasForThreeCalcItemTypes(), Rollup.InvocationPoint.FROM_FULL_RECALC_LWC.name());
    Test.stopTest();

    Assert.areEqual(3, beforeEnqueueCount, 'precondition: the gate claimed all three groups at build time');
    Assert.isTrue(
      processId.contains('IsEnabled__c is false'),
      'precondition: the kill switch aborted the recalc, so no finalizer will ever run for any group. Got: ' + processId
    );
    Assert.areEqual(3, afterCompleteCount, 'the conductor must release the groups it carries in `rollups`, not only its own claim');
  }

  // ---- the parent-reset processor passes the type test and must still not be gated ----
  @IsTest
  static void parentResetProcessorIsNotGated() {
    beforeEnqueueCount = 0;
    // it EXTENDS RollupFullBatchRecalculator, so `instanceof` alone waves it through. It overrides
    // runCalc without calling super, so no bail-out release and no finalizer ever fire for it —
    // gating one strands the claim outright.
    RollupFullRecalcProcessor parentReset = stubProcessor();

    Test.startTest();
    RollupFullRecalcProcessor result = Rollup.applyFullRecalcGate(parentReset, new SuppressGate(), buildContext());
    Test.stopTest();

    Assert.isTrue(parentReset instanceof RollupFullBatchRecalculator, 'precondition: it satisfies the type test the guard starts from');
    Assert.areEqual(0, beforeEnqueueCount, 'a processor that never releases must not be consulted, whatever it extends');
    Assert.isTrue(result == parentReset, 'it must come back untouched, even from a gate that suppresses');
  }

  // ---- a non-cursor processor is never gated, even when handed straight in ----
  @IsTest
  static void nonCursorProcessorIsNotGated() {
    beforeEnqueueCount = 0;
    // a deferred/small-set processor: it delegates to the regular queueable path, so no
    // FullRecalcFinalizer ever fires notifyGateComplete for it and a claim taken here would never
    // be released. buildFullRecalcRollup filters this shape out; the guard inside
    // applyFullRecalcGate is what protects a future second call site, and this is its only proof.
    RollupFullRecalcProcessor deferred = new RollupDeferredFullRecalcProcessor(
      concatMetas(),
      RollupChild__c.SObjectType,
      'SELECT Id, Name, RollupParent__c FROM RollupChild__c',
      new Set<String>(),
      Rollup.InvocationPoint.FROM_APEX,
      null
    );

    Test.startTest();
    RollupFullRecalcProcessor result = Rollup.applyFullRecalcGate(deferred, new SuppressGate(), buildContext());
    Test.stopTest();

    Assert.areEqual(0, beforeEnqueueCount, 'a processor that never releases must not be consulted — the claim would strand');
    Assert.isTrue(result == deferred, 'a non-cursor processor must come back untouched, even from a gate that suppresses');
  }

  // ---- AC4: completion notifies afterComplete once on terminal success ----
  @IsTest
  static void completionNotifiesAfterCompleteOnceOnSuccess() {
    afterCompleteCount = 0;
    RollupFullRecalcProcessor processor = stubProcessor();
    processor.setFullRecalcGate(new ProceedGate(), buildContext());

    Test.startTest();
    // the terminal-success else-branch of FullRecalcFinalizer.handleSuccess fires this;
    // it must be idempotent (once per logical recalc, not per cursor page)
    processor.notifyGateComplete();
    processor.notifyGateComplete();
    Test.stopTest();

    Assert.areEqual(1, afterCompleteCount, 'afterComplete must fire exactly once per logical recalc');
  }

  // ---- AC5: completion notifies on the finalizer failure branch ----
  @IsTest
  static void finalizerFailureBranchInvokesHandleUnhandledException() {
    RecordingFinalizer finalizer = new RecordingFinalizer();

    Test.startTest();
    finalizer.execute(new UnhandledContext());
    Test.stopTest();

    Assert.isTrue(
      finalizer.handleUnhandledExceptionCalled,
      'the UNHANDLED_EXCEPTION branch must invoke the new handleUnhandledException hook (FullRecalcFinalizer overrides it to fire afterComplete)'
    );
  }

  // ---- AC6: unresolvable gate fails open ----
  @IsTest
  static void unresolvableGateFailsOpen() {
    registerGate('Definitely.Not.A.Real.Class');

    Test.startTest();
    RollupFullRecalcGate gate = Rollup.resolveFullRecalcGate();
    Test.stopTest();

    // resolution returning null is the whole fail-open mechanism: buildFullRecalcRollup returns the
    // processor untouched without ever building a context (see bogusGateClassNameFailsOpenOnRealPath)
    Assert.isNull(gate, 'a gate naming an uninstantiable class must resolve null');
  }

  // ---- AC7: a throwing gate fails open (both call sites) ----
  @IsTest
  static void throwingGateFailsOpen() {
    RollupFullRecalcProcessor original = buildBatchRecalc();
    RollupFullRecalcContext context = buildContext();

    RollupFullRecalcProcessor releaseProcessor = stubProcessor();
    releaseProcessor.setFullRecalcGate(new ThrowingGate(), context);

    Test.startTest();
    RollupFullRecalcProcessor result = Rollup.applyFullRecalcGate(original, new ThrowingGate(), context);
    // a throwing afterComplete must also be contained
    releaseProcessor.notifyGateComplete();
    Test.stopTest();

    Assert.isTrue(result == original, 'a gate whose beforeEnqueue throws must proceed unchanged (exception contained)');
  }

  // ---- AC8: with nothing registered the seam resolves nothing (the whole fail-open mechanism) ----
  @IsTest
  static void dormantSeamIsInert() {
    // pinned to mocks only, so this still asserts "nothing registered" in the org that DOES
    // register the gate. Parity of the built processor is covered on the real path by
    // noGateRegisteredReturnsBatchRecalculatorUnchanged.
    RollupPlugin.onlyUseMockPlugins = true;

    Test.startTest();
    RollupFullRecalcGate gate = Rollup.resolveFullRecalcGate();
    Test.stopTest();

    Assert.isNull(gate, 'with no plugin record the gate resolves null');
  }

  // ---- a gate that claims state then throws must still get its release ----
  @IsTest
  static void claimThenThrowStillReleasesTheClaim() {
    claimCount = 0;
    afterCompleteCount = 0;
    RollupFullRecalcProcessor original = buildBatchRecalc();

    Test.startTest();
    RollupFullRecalcProcessor result = Rollup.applyFullRecalcGate(original, new ClaimThenThrowGate(), buildContext());
    // whatever terminal path runs, the finalizer calls this
    result.notifyGateComplete();
    Test.stopTest();

    Assert.areEqual(1, claimCount, 'precondition: the gate claimed before it threw');
    Assert.isTrue(result == original, 'a throwing beforeEnqueue must proceed unchanged');
    // what this actually pins is the catch FALLING THROUGH to an armed processor, not the arming
    // order — moving setFullRecalcGate below the try/catch keeps this green. The bug it guards is
    // upstream's `return fullRecalc;` inside the catch, which left the processor ungated.
    Assert.areEqual(1, afterCompleteCount, 'a claim taken by a gate that then throws must still be released, not stranded until TTL');
  }

  // ---- the gate class name must come from a parameter scoped to the gate plugin ----
  @IsTest
  static void parameterAttachedToAnotherPluginDoesNotActivateTheGate() {
    // the plugin carries a real Id and the parameter names a DIFFERENT one, which is the only shape
    // that actually discriminates: with a null plugin Id the scoping filter cannot fire at all
    RollupPlugin.pluginMocks = new List<RollupPlugin__mdt>{
      new RollupPlugin__mdt(Id = RollupTestUtils.createId(RollupPlugin__mdt.SObjectType), DeveloperName = Rollup.FULL_RECALC_GATE_NAME)
    };
    RollupPlugin.parameterMock = new RollupPluginParameter__mdt(
      DeveloperName = Rollup.FULL_RECALC_GATE_PARAM_NAME,
      Value__c = ProceedGate.class.getName(),
      RollupPlugin__c = RollupTestUtils.createId(RollupPlugin__mdt.SObjectType)
    );

    Test.startTest();
    RollupFullRecalcGate gate = Rollup.resolveFullRecalcGate();
    Test.stopTest();

    Assert.isNull(gate, 'a FullRecalcGateClass parameter attached to a DIFFERENT plugin must not activate this gate');
  }

  // ---- removing the plugin record disarms the gate, parameter or no parameter ----
  @IsTest
  static void removingThePluginRecordDisarmsTheGate() {
    RollupPlugin.onlyUseMockPlugins = true;
    // the operator's emergency lever: delete the FullRecalcGate plugin record and the seam goes
    // dormant even though the FullRecalcGateClass parameter is still deployed. Without the
    // plugin-record null check the parameter alone would keep resolving a live gate.
    RollupPlugin.pluginMocks = new List<RollupPlugin__mdt>();
    RollupPlugin.parameterMock = new RollupPluginParameter__mdt(DeveloperName = Rollup.FULL_RECALC_GATE_PARAM_NAME, Value__c = ProceedGate.class.getName());

    Test.startTest();
    RollupFullRecalcGate gate = Rollup.resolveFullRecalcGate();
    Test.stopTest();

    Assert.isNull(gate, 'with the plugin record gone the gate must resolve null even though its parameter survives');
  }

  // ---- an UNATTACHED parameter still activates — documenting the real behaviour ----
  @IsTest
  static void unattachedParameterStillActivatesTheGate() {
    RollupPlugin.pluginMocks = new List<RollupPlugin__mdt>{
      new RollupPlugin__mdt(Id = RollupTestUtils.createId(RollupPlugin__mdt.SObjectType), DeveloperName = Rollup.FULL_RECALC_GATE_NAME)
    };
    // RollupPlugin__c left null. getMatchingParameters only drops a parameter whose plugin is set
    // AND differs, so this one survives. No shipped record has this shape — it is tolerance, not
    // convention — but it is the framework's behaviour and the seam inherits it.
    RollupPlugin.parameterMock = new RollupPluginParameter__mdt(DeveloperName = Rollup.FULL_RECALC_GATE_PARAM_NAME, Value__c = ProceedGate.class.getName());

    Test.startTest();
    RollupFullRecalcGate gate = Rollup.resolveFullRecalcGate();
    Test.stopTest();

    Assert.isInstanceOfType(gate, ProceedGate.class, 'an unattached parameter is tolerated by getMatchingParameters and still resolves');
  }

  // ---- a parameter under the right plugin but the wrong name is ignored ----
  @IsTest
  static void parameterWithAnotherNameDoesNotActivateTheGate() {
    RollupPlugin.pluginMocks = new List<RollupPlugin__mdt>{ new RollupPlugin__mdt(DeveloperName = Rollup.FULL_RECALC_GATE_NAME) };
    RollupPlugin.parameterMock = new RollupPluginParameter__mdt(DeveloperName = 'SomeOtherParameter', Value__c = ProceedGate.class.getName());

    Test.startTest();
    RollupFullRecalcGate gate = Rollup.resolveFullRecalcGate();
    Test.stopTest();

    Assert.isNull(gate, 'only the FullRecalcGateClass parameter may name the gate implementation');
  }
}
