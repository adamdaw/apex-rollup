/**
 * P2 coverage for the custom-Evaluator half of the full-recalc bystander re-inclusion in
 * RollupCalculator.winnowItems:
 *   if (this.isFullRecalc && isUnchangedBystander) { shouldAddToResults = true; }
 *
 * `this.eval` is the COMBINED evaluator (RollupEvaluator.getEvaluator) which ANDs, in order, a
 * caller-supplied custom Evaluator, the where-clause evaluator, the changed-field evaluator, and (for
 * UPDATE ops) RecursiveUpdateEvaluator. `isUnchangedBystander` re-checks only the changed-field and
 * where evaluators, so a full recalc re-includes an item the CUSTOM evaluator rejected — as long as the
 * item also had no tracked-field change and still satisfies the where clause. That silently defeats a
 * caller's explicit exclusion.
 *
 * The custom-evaluator path is reachable ONLY through the imperative
 * Rollup.runFromApex(localMetas, eval, calcItems, oldCalcItems) API — CMDT/trigger rollups have no field
 * to supply a custom Evaluator, so this test drives that API directly.
 *
 * Harness (mirrors ZZSiblingRetrievalTieBreakTest): AVERAGE of NumberField__c into AverageField__c,
 * where TextField__c != 'EXCLUDE', tracked field DateField__c. AVERAGE runs as a full recalc that
 * requeries the parent's full child set.
 *
 * Children: c1(Num=50), c2(Num=100), c3(Num=1000) — all in-where, all DateField = today.
 * One bystander DML: c3.TextField__c 'keep' -> 'kept' (still in-where; DateField__c untouched => c3 is
 * an unchanged bystander, WITH an old record so the changed-field evaluator classifies it "unchanged").
 * The caller's custom Evaluator rejects c3 (NumberField__c == 1000).
 *
 *   * With the fix:   c3 is honored-excluded => AVERAGE{50,100}       = 75.
 *   * Without the fix: c3 is re-included as a bystander => AVERAGE{50,100,1000} = 383.33 (the leak).
 *
 * The control method runs the identical scenario with NO custom Evaluator and asserts the bystander IS
 * re-included (383.33). That proves the re-inclusion path is genuinely active here, so the 75 in the
 * main test is specifically the custom Evaluator being honored — not c3 excluded for some other reason.
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZCustomEvalBystanderTest {
  private static final Decimal LEAK = ((Decimal) (50 + 100 + 1000) / 3).setScale(2); // 383.33

  // Rejects the child the caller means to exclude. NumberField__c is the AVERAGE (op) field, so it is
  // always present on both the DML item and every requeried sibling.
  private class RejectHighValueEval implements Rollup.Evaluator {
    public Boolean matches(Object calcItem) {
      return (Decimal) ((SObject) calcItem).get(RollupChild__c.NumberField__c) != 1000;
    }
  }

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
      new RollupChild__c(Name = 'c3', NumberField__c = 1000, TextField__c = 'keep', DateField__c = System.today(), RollupParent__c = parent.Id)
    };
    return parent;
  }

  static Rollup__mdt avgMeta() {
    return new Rollup__mdt(
      CalcItem__c = 'RollupChild__c',
      CalcItemWhereClause__c = 'TextField__c != \'EXCLUDE\'',
      ChangedFieldsOnCalcItem__c = 'DateField__c',
      LookupFieldOnCalcItem__c = 'RollupParent__c',
      LookupFieldOnLookupObject__c = 'Id',
      LookupObject__c = 'RollupParent__c',
      RollupFieldOnCalcItem__c = 'NumberField__c',
      RollupFieldOnLookupObject__c = 'AverageField__c',
      RollupOperation__c = 'AVERAGE'
    );
  }

  // The bystander DML: c3 stays in-where, its tracked field (DateField__c) is untouched, and it keeps an
  // old record so the changed-field evaluator sees it as "unchanged" (the bystander classification).
  static RollupChild__c bystanderC3(Id pid, Map<Id, SObject> oldCalcItems) {
    RollupChild__c c3 = [SELECT Id, Name, NumberField__c, TextField__c, DateField__c, RollupParent__c FROM RollupChild__c WHERE Name = 'c3' AND RollupParent__c = :pid WITH SYSTEM_MODE];
    oldCalcItems.put(c3.Id, c3.clone(true, true, true, true)); // old == new on the tracked field => unchanged
    c3.TextField__c = 'kept'; // in-where before & after; DateField__c untouched => unchanged bystander
    return c3;
  }

  static Decimal readAvg(Id pid) {
    // AVERAGE of NumberField__c yields a repeating decimal for the leak case; compare at 2dp.
    return [SELECT AverageField__c FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE].AverageField__c?.setScale(2, System.RoundingMode.HALF_UP);
  }

  @IsTest
  static void customEvalRejectedBystanderStaysExcludedDuringFullRecalc() {
    RollupParent__c parent = seed();
    Map<Id, SObject> oldCalcItems = new Map<Id, SObject>();
    RollupChild__c c3 = bystanderC3(parent.Id, oldCalcItems);
    update as system c3;

    Rollup.apexContext = TriggerOperation.AFTER_UPDATE;
    Rollup.shouldRun = true;

    Test.startTest();
    Rollup.runFromApex(new List<Rollup__mdt>{ avgMeta() }, new RejectHighValueEval(), new List<SObject>{ c3 }, oldCalcItems).runCalc();
    Test.stopTest();

    Assert.areEqual(
      75.00,
      readAvg(parent.Id),
      'Caller-supplied Evaluator rejected c3 (Num=1000); a full-recalc bystander re-inclusion must not ' +
        'override it. Expected AVERAGE{50,100}=75; the leak (' + LEAK + '=AVERAGE{50,100,1000}) means c3 was re-included.'
    );
  }

  // Control: identical scenario, NO custom Evaluator. c3 is re-included as an unchanged bystander, so the
  // AVERAGE includes 1000. Proves the re-inclusion path is live here (guards the main test against a
  // false green) and passes both before and after the fix.
  @IsTest
  static void bystanderReincludedWithoutCustomEval() {
    RollupParent__c parent = seed();
    Map<Id, SObject> oldCalcItems = new Map<Id, SObject>();
    RollupChild__c c3 = bystanderC3(parent.Id, oldCalcItems);
    update as system c3;

    Rollup.apexContext = TriggerOperation.AFTER_UPDATE;
    Rollup.shouldRun = true;

    Test.startTest();
    Rollup.runFromApex(new List<Rollup__mdt>{ avgMeta() }, null, new List<SObject>{ c3 }, oldCalcItems).runCalc();
    Test.stopTest();

    Assert.areEqual(
      LEAK,
      readAvg(parent.Id),
      'CONTROL: with no custom Evaluator, unchanged bystander c3 is re-included in the full recalc => ' +
        'AVERAGE{50,100,1000}=' + LEAK + '. Confirms the re-inclusion path is active in this scenario.'
    );
  }
}
