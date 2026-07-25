/**
 * DEFECT A repro: multi-field GROUP BY omits the 2nd+ grouping field from the full-recalc
 * sibling requery SELECT.
 *
 * A grouped rollup is always a full recalc (RollupAsyncProcessor.isValidAdditionalCalcItemRetrieval
 * -> flagFullRecalcRollups sets isFullRecalc=true), so it REQUERIES the sibling calc items that were
 * NOT part of the triggering DML (retrieveAdditionalCalcItems, ~line 604-668). That sibling SELECT is
 * built from calcObjectToUniqueFieldNames, populated in populateObjectFields (~1116-1141). That method
 * adds the op field, lookup field, where-clause fields and order-by fields to the SELECT but NOT the
 * GroupByFields__c fields. With GroupByFields__c = "TextField__c,DateField__c", ONLY the FIRST field
 * (TextField__c) lands in the requery through some other path is coincidental - the SECOND grouping
 * field (DateField__c) is never added, so requeried siblings read DateField__c = null and
 * GroupByCalculator.performRollup (RollupCalculator.cls:1414-1419) buckets them under '(blank)'.
 *
 * Scenario (forces the sibling requery by updating ONE child while its siblings stay out of the DML):
 *   c1(Number=7,  Text='A', Date=D1)   c2(Number=13, Text='A', Date=D1)
 *   c3(Number=400,Text='A', Date=D2)   c4(Number=5000,Text='B', Date=D1)
 *   correct GROUP BY (Text,Date): (A,D1)=20, (A,D2)=400, (B,D1)=5000
 *
 *   update ONLY c1: Number 7 -> 77. c1 stays in the DML with a fully-populated Date; c2/c3/c4 are
 *   requeried as siblings.
 *     CORRECT: (A,D1)=90, (A,D2)=400, (B,D1)=5000
 *     BUGGY  : siblings lose DateField__c -> null -> '(blank)':
 *              (A,D1)={c1}=77, (A,'(blank)')={c2,c3}=413, (B,'(blank)')={c4}=5000
 *
 * CONTROL: the SAME children rolled up by a SINGLE grouping field (TextField__c only, via the
 * pre-existing Rollup.GroupByControlNoChangedFields -> GroupByControl__c). The single grouping field
 * IS present in the requery, so the single-field GROUP BY stays correct regardless. (See also
 * ZZF1GroupByReproTest for the single-field GROUP BY baseline.)
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZAGroupByMultiFieldReproTest {
  static final Date D1 = Date.newInstance(2026, 1, 1);
  static final Date D2 = Date.newInstance(2026, 6, 1);

  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  static RollupParent__c seed() {
    RollupParent__c parent = new RollupParent__c(Name = 'p');
    insert as system parent;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 7, TextField__c = 'A', DateField__c = D1, RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 13, TextField__c = 'A', DateField__c = D1, RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c3', NumberField__c = 400, TextField__c = 'A', DateField__c = D2, RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c4', NumberField__c = 5000, TextField__c = 'B', DateField__c = D1, RollupParent__c = parent.Id)
    };
    return parent;
  }

  static RollupChild__c child(Id pid, String nm) {
    return [SELECT Id, NumberField__c FROM RollupChild__c WHERE Name = :nm AND RollupParent__c = :pid WITH SYSTEM_MODE];
  }

  static RollupParent__c read(Id pid) {
    return [SELECT GroupByMultiField__c, GroupByControl__c FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE];
  }

  @IsTest
  static void multiFieldGroupBySurvivesSiblingRequery() {
    RollupParent__c parent = seed();
    RollupParent__c before = read(parent.Id);
    // baseline: the full, correct two-field grouping is present before any update
    Assert.isTrue(before.GroupByMultiField__c?.contains('20'), 'baseline (A,D1) should SUM to 20: ' + before.GroupByMultiField__c);
    Assert.isTrue(before.GroupByMultiField__c?.contains('400'), 'baseline (A,D2) should SUM to 400: ' + before.GroupByMultiField__c);
    Assert.isFalse(before.GroupByMultiField__c?.contains('(blank)'), 'baseline must have NO blank grouping bucket: ' + before.GroupByMultiField__c);

    Test.startTest();
    // update ONLY c1 -> forces full-recalc sibling requery of c2/c3/c4 (not in this DML)
    RollupChild__c c1 = child(parent.Id, 'c1');
    c1.NumberField__c = 77;
    update as system c1;
    Test.stopTest();

    RollupParent__c after = read(parent.Id);

    // DEFECT A signature: requeried siblings lose the 2nd grouping field (DateField__c) -> '(blank)'
    Assert.isFalse(
      after.GroupByMultiField__c?.contains('(blank)'),
      'DEFECT A: requeried siblings dropped DateField__c into a blank bucket: ' + after.GroupByMultiField__c
    );
    // both grouping fields must bucket correctly after the requery
    Assert.isTrue(
      after.GroupByMultiField__c?.contains('90'),
      'FIX: (A,D1) must SUM c1(77)+c2(13)=90 - both grouping fields honored on requeried siblings: ' + after.GroupByMultiField__c
    );
    Assert.isTrue(
      after.GroupByMultiField__c?.contains('400'),
      'FIX: (A,D2) must stay its own bucket SUM 400 (c3 not merged into a blank date bucket): ' + after.GroupByMultiField__c
    );
    Assert.isTrue(
      after.GroupByMultiField__c?.contains('5000'),
      'FIX: (B,D1) must stay SUM 5000: ' + after.GroupByMultiField__c
    );
  }

  // CONTROL: single-field GROUP BY (TextField__c only) is unaffected - its lone grouping field is
  // always carried in the requery SELECT, so it groups correctly before and after the fix.
  @IsTest
  static void singleFieldGroupByControlStaysCorrect() {
    RollupParent__c parent = seed();
    RollupParent__c before = read(parent.Id);
    Assert.isTrue(before.GroupByControl__c?.contains('420'), 'baseline control: group A = 7+13+400 = 420: ' + before.GroupByControl__c);
    Assert.isTrue(before.GroupByControl__c?.contains('5000'), 'baseline control: group B = 5000: ' + before.GroupByControl__c);

    Test.startTest();
    RollupChild__c c1 = child(parent.Id, 'c1');
    c1.NumberField__c = 77;
    update as system c1;
    Test.stopTest();

    RollupParent__c after = read(parent.Id);
    Assert.isFalse(after.GroupByControl__c?.contains('(blank)'), 'CONTROL: single-field GROUP BY never blanks: ' + after.GroupByControl__c);
    Assert.isTrue(after.GroupByControl__c?.contains('490'), 'CONTROL: group A = 77+13+400 = 490 (single-field requery correct): ' + after.GroupByControl__c);
    Assert.isTrue(after.GroupByControl__c?.contains('5000'), 'CONTROL: group B stays 5000: ' + after.GroupByControl__c);
  }
}
