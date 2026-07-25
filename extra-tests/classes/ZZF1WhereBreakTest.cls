/**
 * Adversarial follow-up to ZZF1ReproTest (F1 fix review, ws-a).
 *
 * The F1 fix in RollupCalculator.winnowItems force-includes an "unchanged bystander" on a full
 * recalc:
 *
 *   Boolean isUnchangedBystander = changedFieldEvaluator != null
 *     && shouldAddToResults == false
 *     && changedFieldEvaluator.matches(transformedItem) == false;
 *   ...
 *   if (this.isFullRecalc && isUnchangedBystander) { shouldAddToResults = true; }
 *
 * `isUnchangedBystander` consults ONLY the changed-field evaluator - it never re-checks the
 * CalcItemWhereClause__c, even though the accompanying comment claims the item "still satisfies
 * the where clause." So when a calc-item UPDATE leaves the TRACKED changed-fields untouched
 * (=> bystander) but changes a DIFFERENT field that the where clause filters on, the child is
 * moved OUT of the where-clause scope, yet the fix force-re-includes it in the recomputed
 * aggregate. The parent is then computed from a child that should have been excluded.
 *
 * Config (already scaffolded in this repo, no test used it before):
 *   Rollup.WhereAvgChangedFields            - AVERAGE, tracked=NumberField__c,
 *                                             where=TextField__c != 'EXCLUDE', target WhereAvgField__c
 *   Rollup.WhereAvgControlNoChangedFields   - identical but NO ChangedFieldsOnCalcItem__c (control)
 *
 * Scenario: parent p, children c1=50 (Text='keep'), c2=100 (Text='keep'); baseline avg=75.
 * Bystander-but-scope-exiting update: c1.TextField__c = 'EXCLUDE' (NumberField__c untouched).
 *   TRUE full-recalc value  = avg over the in-scope set {c2=100}           = 100
 *   CONTROL (no changed-fields) rollup                                     -> 100 (correct)
 *   FIXED changed-fields rollup (F1 fix)                                   -> 75  (WRONG: c1 re-included)
 *
 * Red here (actual 75, not 100) = the fix is BROKEN for this pattern; a correct fix keeps WhereAvgField__c at 100.
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZF1WhereBreakTest {
  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  static RollupParent__c seed() {
    RollupParent__c parent = new RollupParent__c(Name = 'p');
    insert as system parent;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 50, TextField__c = 'keep', RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 100, TextField__c = 'keep', RollupParent__c = parent.Id)
    };
    return parent;
  }

  static RollupChild__c child(Id pid, String nm) {
    return [SELECT Id, TextField__c FROM RollupChild__c WHERE Name = :nm AND RollupParent__c = :pid WITH SYSTEM_MODE];
  }

  static RollupParent__c read(Id pid) {
    return [SELECT WhereAvgField__c, WhereAvgControl__c FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE];
  }

  // A "bystander" update (tracked NumberField__c unchanged) that ALSO changes the where-clause
  // field TextField__c, moving c1 out of the rollup's scope.
  @IsTest
  static void bystanderThatExitsWhereClauseIsWronglyReincluded() {
    RollupParent__c parent = seed();
    RollupParent__c b = read(parent.Id);
    Assert.areEqual(75, b.WhereAvgField__c, 'baseline changed-fields AVERAGE (both children in scope)');
    Assert.areEqual(75, b.WhereAvgControl__c, 'baseline control AVERAGE (both children in scope)');

    Test.startTest();
    RollupChild__c c1 = child(parent.Id, 'c1');
    c1.TextField__c = 'EXCLUDE'; // NumberField__c untouched => bystander for the changed-fields rollup
    update as system c1;
    Test.stopTest();

    RollupParent__c a = read(parent.Id);
    // Control proves the correct post-update value: c1 left the where scope, so avg over {c2} = 100.
    Assert.areEqual(
      100,
      a.WhereAvgControl__c,
      'CONTROL (no changed-fields): c1 exited the where clause, AVERAGE recomputes over {c2}=100'
    );
    // The F1 fix should match the control. It does not: it force-re-includes the out-of-scope c1.
    Assert.areEqual(
      100,
      a.WhereAvgField__c,
      'FIX BREAK: changed-fields AVERAGE must exclude c1 (now out of where scope) and equal 100, not 75'
    );
  }

  // Disambiguates the break from mere staleness. A single batch updates BOTH:
  //   c1: scope-exit bystander (Text -> 'EXCLUDE', NumberField__c untouched)
  //   c2: a real tracked change (NumberField__c 100 -> 200) => proves the rollup DID run
  // Three distinct outcomes:
  //   correct     = avg over in-scope {c2=200}          = 200
  //   fix-buggy   = avg over {c1=50, c2=200}            = 125  (c1 wrongly re-included)
  //   stale/no-op = 75                                  (rollup never ran)
  // Actual == 125 proves the value comes from re-inclusion, not from the rollup failing to run.
  @IsTest
  static void mixedBatchProvesReinclusionNotStaleness() {
    RollupParent__c parent = seed();

    Test.startTest();
    RollupChild__c c1 = child(parent.Id, 'c1');
    c1.TextField__c = 'EXCLUDE'; // bystander + scope exit
    RollupChild__c c2 = [SELECT Id, NumberField__c FROM RollupChild__c WHERE Name = 'c2' AND RollupParent__c = :parent.Id WITH SYSTEM_MODE];
    c2.NumberField__c = 200; // real tracked change -> forces the aggregate to recompute
    update as system new List<RollupChild__c>{ c1, c2 };
    Test.stopTest();

    RollupParent__c a = read(parent.Id);
    Assert.areEqual(
      200,
      a.WhereAvgControl__c,
      'CONTROL (no changed-fields): c1 excluded, c2=200 => avg({200})=200'
    );
    Assert.areEqual(
      200,
      a.WhereAvgField__c,
      'FIX BREAK: expected 200 (c1 out of scope). Actual 125 = c1 re-included; 75 would mean no-op.'
    );
  }
}
