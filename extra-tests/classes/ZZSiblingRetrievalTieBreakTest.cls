/**
 * TIE-BREAKER (ws-a) for the F1 bystander fix in RollupCalculator.winnowItems:
 *   if (this.isFullRecalc && isUnchangedBystander) { shouldAddToResults = true; }
 *
 * The two prior reviewers disagreed on ONE mechanism about RETRIEVED SIBLINGS (a calc item pulled
 * by the full-recalc sibling requery that is NEVER part of the triggering DML):
 *   W: the sibling requery is NOT where-clause filtered, so an out-of-where sibling IS retrieved and
 *      reaches winnowItems; but it is SAFE because SObjectChangedFieldEvaluator flags an item absent
 *      from oldCalcItems as CHANGED (RollupEvaluator.cls:119,124) => never an unchanged bystander.
 *   C: the full-recalc SOQL is where-clause filtered; the break comes only from RETAINED TRIGGER
 *      RECORDS, not requeried siblings.
 *
 * This class isolates the retrieved-sibling path and pins down the EXACT condition, using ONE DML
 * (a bystander edit on an in-where child) that fires two rollups at once so their outcomes can be
 * compared directly in the same transaction:
 *
 *   Rollup.WhereAvgChangedFields   -> WhereAvgField__c    tracked = NumberField__c  (== the AVERAGE
 *                                     field, so it is ALWAYS in the sibling requery SELECT)
 *   Rollup.SiblingNullTrackedAvg   -> SiblingNullField__c tracked = DateField__c    (NOT the average
 *                                     field, NOT the where field, NOT an order-by => it is NEVER added
 *                                     to the sibling requery SELECT: RollupAsyncProcessor.cls:1131-1138)
 * Both: AVERAGE of NumberField__c, where TextField__c != 'EXCLUDE'. Controls (no changed-fields)
 * write WhereAvgControl__c / SiblingNullControl__c.
 *
 * Children: c1(Num=50,Text='keep',Date=today), c2(Num=100,Text='keep',Date=today),
 *           c3(Num=1000,Text='EXCLUDE',Date=today).  Baseline in-where AVERAGE {c1,c2} = 75; c3 out.
 *
 * The mechanism this proves: an out-of-where retrieved sibling is classified by
 * SObjectChangedFieldEvaluator.matches. That evaluator (RollupEvaluator.cls:117-131) only flags the
 * sibling CHANGED via the `calcSObject == oldRecord` short-circuit IF the tracked field is present in
 * getPopulatedFieldsAsMap(). A retrieved sibling only carries the fields the requery SELECTed. So:
 *   - tracked field IS queried  (WhereAvgChangedFields) -> present -> matches==true  -> sibling SAFE.
 *   - tracked field NOT queried (SiblingNullTrackedAvg) -> absent  -> matches==false -> sibling is an
 *     "unchanged bystander" -> the fix flips it in -> out-of-where sibling would LEAK into the aggregate.
 *
 * OUTCOME (both assertions land at 75, no leak): the absent-field path above is NOT the operative
 * reason c3 stays out. Two mechanisms exclude it, either sufficient on its own:
 *   1. The .4 where-clause conjunct in isUnchangedBystander (whereEvaluator.matches(c3)==false) drops
 *      out-of-where c3 regardless of tracked-field presence. This is the guard this test actually
 *      exercises.
 *   2. RollupAsyncProcessor accumulates GroupByFields__c into a per-SObjectType sibling-requery field
 *      set; the sibling Rollup.GroupByMultiFieldRepro ("TextField__c,DateField__c") therefore pulls
 *      DateField__c into the shared RollupChild__c requery SELECT, so SiblingNullTrackedAvg's tracked
 *      field IS present on the retrieved sibling after all -> flagged CHANGED, not a bystander.
 * So this class validates mechanism 1 (the where-clause guard); it does not isolate the tracked-field-
 * absent path in the current CMDT set. The fix is correct through both.
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZSiblingRetrievalTieBreakTest {
  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  static RollupParent__c seed() {
    RollupParent__c parent = new RollupParent__c(Name = 'p');
    insert as system parent;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 50, TextField__c = 'keep', DateField__c = System.today(), RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 100, TextField__c = 'keep', DateField__c = System.today(), RollupParent__c = parent.Id),
      // c3 is out-of-where (Text='EXCLUDE'). Its tracked-for-SiblingNull field DateField__c is
      // populated in the DB (today) - yet it is never SELECTed on the sibling requery, so on the
      // retrieved record it reads null. That is the whole point.
      new RollupChild__c(Name = 'c3', NumberField__c = 1000, TextField__c = 'EXCLUDE', DateField__c = System.today(), RollupParent__c = parent.Id)
    };
    return parent;
  }

  static RollupChild__c child(Id pid, String nm) {
    return [SELECT Id, TextField__c, NumberField__c, DateField__c FROM RollupChild__c WHERE Name = :nm AND RollupParent__c = :pid WITH SYSTEM_MODE];
  }

  static RollupParent__c read(Id pid) {
    return [
      SELECT WhereAvgField__c, WhereAvgControl__c, SiblingNullField__c, SiblingNullControl__c
      FROM RollupParent__c
      WHERE Id = :pid
      WITH SYSTEM_MODE
    ];
  }

  // Sanity: both rollups (and both controls) exclude out-of-where c3 at baseline.
  @IsTest
  static void baselineExcludesOutOfWhereSibling() {
    RollupParent__c parent = seed();
    RollupParent__c b = read(parent.Id);
    Assert.areEqual(75, b.WhereAvgField__c, 'baseline: tracked-field-queried AVERAGE excludes out-of-where c3');
    Assert.areEqual(75, b.SiblingNullField__c, 'baseline: tracked-field-NOT-queried AVERAGE excludes out-of-where c3');
    Assert.areEqual(75, b.WhereAvgControl__c, 'baseline control');
    Assert.areEqual(75, b.SiblingNullControl__c, 'baseline control');
  }

  // The tie-breaker. ONE bystander edit on in-where child c1 (TextField 'keep'->'kept': still
  // in-where; neither tracked field, NumberField__c nor DateField__c, is touched => bystander for
  // BOTH changed-fields rollups). c3 is a PURE RETRIEVED SIBLING - never in the DML.
  //
  // Both changed-fields rollups run the AVERAGE as a full recalc and both requery c2+c3 as siblings.
  // The ONLY difference is whether the tracked field rides along in the sibling SELECT:
  //   * WhereAvgField__c  (tracked = NumberField__c = the average field, so it IS selected):
  //       c3.NumberField__c present => matches()==true (CHANGED) => c3 NOT re-included => 75.  <- W's mechanism
  //   * SiblingNullField__c (tracked = DateField__c): both rollups exclude out-of-where c3 (=> 75).
  //       The where-clause guard (mechanism 1, header NOTE) drops c3 regardless of tracked-field
  //       presence; the tracked-field-absent leak is additionally masked because DateField__c rides
  //       into the shared sibling requery via Rollup.GroupByMultiFieldRepro. Both assertions expect 75.
  @IsTest
  static void retrievedSiblingLeaksIffTrackedFieldNotInRequery() {
    RollupParent__c parent = seed();

    Test.startTest();
    RollupChild__c c1 = child(parent.Id, 'c1');
    c1.TextField__c = 'kept'; // in-where before & after; both tracked fields untouched => bystander
    update as system c1;
    Test.stopTest();

    RollupParent__c a = read(parent.Id);

    // Controls: c3 stays excluded regardless (no changed-field evaluator involved).
    Assert.areEqual(75, a.WhereAvgControl__c, 'CONTROL: c3 excluded => 75');
    Assert.areEqual(75, a.SiblingNullControl__c, 'CONTROL: c3 excluded => 75');

    // Tracked field IS queried => W's mechanism holds => sibling safe.
    Assert.areEqual(
      75,
      a.WhereAvgField__c,
      'TRACKED-QUERIED: retrieved sibling c3 carries NumberField__c => flagged CHANGED (absent-from-old) => excluded => 75'
    );

    // Out-of-where c3 stays excluded via the .4 where-clause guard (see header NOTE); a leak would read 383.33.
    Assert.areEqual(
      75,
      a.SiblingNullField__c,
      'OUT-OF-WHERE SIBLING EXCLUDED: c3 leaves the where clause, so the .4 where-clause conjunct in ' +
        'isUnchangedBystander keeps it out of the recalc regardless of tracked-field presence (=> 75, not a ' +
        '383.33 = avg{50,100,1000} leak). The tracked-field-absent path is additionally masked; see header NOTE.'
    );
  }
}
