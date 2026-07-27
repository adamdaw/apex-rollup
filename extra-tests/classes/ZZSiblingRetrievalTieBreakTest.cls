/**
 * RETRIEVED-SIBLING coverage for the F1 bystander fix in RollupCalculator.winnowItems:
 *   if (this.isFullRecalc && isUnchangedBystander) { shouldAddToResults = true; }
 * paired with the requery fix in RollupAsyncProcessor.populateObjectFields (add every tracked field
 * to the sibling requery SELECT).
 *
 * A RETRIEVED SIBLING is a calc item pulled by the full-recalc sibling requery that is NEVER part of
 * the triggering DML. The sibling requery is not where-clause filtered, so an out-of-where sibling IS
 * retrieved and reaches winnowItems; it must be kept OUT of the recalculated aggregate. Two independent
 * guards do that, either sufficient on its own:
 *   1. The .4 where-clause conjunct in isUnchangedBystander (whereEvaluator.matches(c3) == false) drops
 *      an out-of-where sibling regardless of tracked-field presence.
 *   2. SObjectChangedFieldEvaluator flags a retrieved sibling CHANGED via the `calcSObject == oldRecord`
 *      short-circuit (RollupEvaluator.cls:117-131) whenever its tracked field is present in
 *      getPopulatedFieldsAsMap() -> not an unchanged bystander. A retrieved sibling only carries the
 *      fields the requery SELECTed, so this guard depends on the tracked field being queried.
 *
 * This class fires two rollups from ONE bystander DML so their requeries compare in the same transaction:
 *   Rollup.WhereAvgChangedFields  -> WhereAvgField__c    tracked = NumberField__c (== the AVERAGE field,
 *                                    so it is in the requery for op-field reasons regardless).
 *   Rollup.SiblingNullTrackedAvg  -> SiblingNullField__c tracked = DateField__c   (NOT the average field,
 *                                    NOT the where field, NOT an order-by). Before the requery fix this
 *                                    field was NEVER added to the sibling SELECT on its own, so guard 2
 *                                    was unreliable and coverage leaned on DateField__c incidentally
 *                                    riding in via a sibling GROUP BY rollup's field set. The requery fix
 *                                    now adds every ChangedFieldsOnCalcItem__c field explicitly, so
 *                                    DateField__c is present deterministically -> guard 2 is reliable.
 * SiblingNullTrackedAvg is therefore the direct regression for the requery fix: its tracked field reaches
 * the sibling SELECT only because populateObjectFields now adds tracked fields, not by coincidence.
 * Both: AVERAGE of NumberField__c, where TextField__c != 'EXCLUDE'. Controls (no changed-fields) write
 * WhereAvgControl__c / SiblingNullControl__c.
 *
 * Children: c1(Num=50,Text='keep',Date=today), c2(Num=100,Text='keep',Date=today),
 *           c3(Num=1000,Text='EXCLUDE',Date=today).  Baseline in-where AVERAGE {c1,c2} = 75; c3 out.
 *
 * OUTCOME (both assertions land at 75, no leak): out-of-where c3 is excluded by guard 1 (where-clause)
 * and, now that its tracked field is deterministically queried, also by guard 2 (flagged CHANGED). A
 * leak would read 383.33 = avg{50,100,1000}.
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

  // ONE bystander edit on in-where child c1 (TextField 'keep'->'kept': still in-where; neither tracked
  // field, NumberField__c nor DateField__c, is touched => bystander for BOTH changed-fields rollups).
  // c3 is a PURE RETRIEVED SIBLING - never in the DML.
  //
  // Both changed-fields rollups run the AVERAGE as a full recalc and both requery c2+c3 as siblings.
  // With the requery fix, every tracked field is added to the sibling SELECT, so both rollups carry
  // their tracked field on the retrieved sibling:
  //   * WhereAvgField__c    (tracked = NumberField__c = the average field, selected for op reasons too):
  //       c3.NumberField__c present => matches()==true (CHANGED) => c3 NOT re-included => 75.
  //   * SiblingNullField__c (tracked = DateField__c, selected ONLY because of the requery fix):
  //       c3.DateField__c now present => matches()==true (CHANGED) => c3 NOT re-included => 75.
  // The where-clause conjunct (guard 1) also drops out-of-where c3 independently. Both assertions
  // expect 75; a leak would read 383.33.
  @IsTest
  static void retrievedOutOfWhereSiblingStaysExcludedAfterRequeryFix() {
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

    // Tracked field is the average field, always queried => flagged CHANGED => sibling excluded.
    Assert.areEqual(
      75,
      a.WhereAvgField__c,
      'TRACKED-QUERIED: retrieved sibling c3 carries NumberField__c => flagged CHANGED (absent-from-old) => excluded => 75'
    );

    // Direct regression for the requery fix: DateField__c reaches the sibling SELECT only because
    // populateObjectFields now adds tracked fields, so c3 is flagged CHANGED; the where-clause conjunct
    // excludes it independently. A leak would read 383.33 = avg{50,100,1000}.
    Assert.areEqual(
      75,
      a.SiblingNullField__c,
      'REQUERY FIX: c3 tracked field (DateField__c) is now deterministically queried => flagged CHANGED, ' +
        'and the .4 where-clause conjunct in isUnchangedBystander drops out-of-where c3 independently ' +
        '(=> 75, not a 383.33 = avg{50,100,1000} leak).'
    );
  }
}
