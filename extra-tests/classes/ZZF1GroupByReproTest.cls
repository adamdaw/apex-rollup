/**
 * GROUP BY coverage for the changed-fields "unchanged bystander" full-recalc fix (finding F1),
 * Question-3 (blast-radius) lens.
 *
 * No GROUP BY repro existed. GroupByCalculator.performRollup (RollupCalculator.cls:1388) does NOT
 * call super, but it DOES call the shared winnowItems (RollupCalculator.cls:1398) where the fix
 * lives, then GROUPS the SURVIVING winnowed items (1400-1416) and dispatches one aggregate per
 * group (1421). So a bystander that winnowItems drops never reaches its group, and that group is
 * recomputed from an incomplete child set. GROUP BY is a full-recalc op (Rollup.cls:2766/2837 ->
 * IsFullRecordSet__c=true -> isFullRecalc=true), so the fix's `this.isFullRecalc && isUnchangedBystander`
 * branch (RollupCalculator.cls:377) is exactly the path that re-includes the bystander here.
 *
 * Config: group RollupChild__c by TextField__c, SUM(NumberField__c) per group, tracked changed
 * field = NumberField__c. The bystander update touches DateField__c only - not tracked, not the
 * grouping field, not the aggregated field - so it is a pure bystander.
 *
 *   children: c1(Number=50, Text='groupA'), c2(Number=100, Text='groupA'), c3(Number=200, Text='groupB')
 *   correct GROUP BY: groupA => SUM 150, groupB => SUM 200
 *   bystander-update c1.DateField only -> pre-fix drops c1 -> groupA recomputed as SUM{100}=100 (CORRUPT)
 *                                       -> WITH fix c1 retained -> groupA stays SUM{50,100}=150 (CORRECT)
 *
 * A pure bystander update must leave the GROUP BY output byte-for-byte unchanged, so each test
 * snapshots the field before the update and asserts equality after, plus a control (identical
 * rollup with NO ChangedFieldsOnCalcItem__c) that is unaffected regardless.
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZF1GroupByReproTest {
  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  static RollupParent__c seed() {
    RollupParent__c parent = new RollupParent__c(Name = 'p');
    insert as system parent;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 50, TextField__c = 'groupA', DateField__c = Date.newInstance(2026, 1, 1), RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 100, TextField__c = 'groupA', DateField__c = Date.newInstance(2026, 1, 1), RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c3', NumberField__c = 200, TextField__c = 'groupB', DateField__c = Date.newInstance(2026, 1, 1), RollupParent__c = parent.Id)
    };
    return parent;
  }

  static RollupChild__c child(Id pid, String nm) {
    return [SELECT Id, DateField__c FROM RollupChild__c WHERE Name = :nm AND RollupParent__c = :pid WITH SYSTEM_MODE];
  }

  static RollupParent__c read(Id pid) {
    return [SELECT GroupByField__c, GroupByControl__c, GroupByAvgField__c FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE];
  }

  // bystander: only DateField__c changes; NumberField__c (tracked) and TextField__c (grouping) untouched
  static void bystanderUpdate(RollupChild__c c) {
    c.DateField__c = Date.newInstance(2026, 12, 31);
    update as system c;
  }

  // Bystander-update a child in groupA. That group must keep SUM 150; the whole GROUP BY string is invariant.
  @IsTest
  static void groupByBystanderKeepsGroupComplete() {
    RollupParent__c parent = seed();
    RollupParent__c before = read(parent.Id);
    // baseline: both the changed-fields rollup and the control computed the full, correct grouping
    Assert.isTrue(before.GroupByField__c?.contains('150'), 'baseline changed-fields GROUP BY should sum groupA to 150: ' + before.GroupByField__c);
    Assert.isTrue(before.GroupByControl__c?.contains('150'), 'baseline control GROUP BY should sum groupA to 150: ' + before.GroupByControl__c);
    Assert.areEqual(before.GroupByControl__c, before.GroupByField__c, 'baseline: changed-fields and control GROUP BY identical');

    Test.startTest();
    bystanderUpdate(child(parent.Id, 'c1')); // pure bystander in groupA
    Test.stopTest();

    RollupParent__c after = read(parent.Id);
    Assert.areEqual(before.GroupByControl__c, after.GroupByControl__c, 'CONTROL (no changed-fields): GROUP BY unaffected by a bystander update');
    Assert.areEqual(before.GroupByField__c, after.GroupByField__c, 'FIX: changed-fields GROUP BY must be byte-identical after a pure bystander update');
    Assert.isTrue(after.GroupByField__c?.contains('150'), 'FIX: groupA must still SUM to 150 (c1 not dropped): ' + after.GroupByField__c);
  }

  // Mirror: bystander-update the OTHER groupA child. Same invariant.
  @IsTest
  static void groupByBystanderKeepsGroupCompleteMirror() {
    RollupParent__c parent = seed();
    RollupParent__c before = read(parent.Id);

    Test.startTest();
    bystanderUpdate(child(parent.Id, 'c2')); // pure bystander in groupA
    Test.stopTest();

    RollupParent__c after = read(parent.Id);
    Assert.areEqual(before.GroupByControl__c, after.GroupByControl__c, 'CONTROL: GROUP BY stays constant');
    Assert.areEqual(before.GroupByField__c, after.GroupByField__c, 'FIX: changed-fields GROUP BY (mirror) must stay byte-identical');
    Assert.isTrue(after.GroupByField__c?.contains('150'), 'FIX: groupA must still SUM to 150: ' + after.GroupByField__c);
  }

  // Contrast: the SAME GROUP BY dispatch, but base op AVERAGE (a custom-state calculator that
  // re-aggregates over the winnowed items directly rather than via the matchesCurrent-gated
  // UPDATE_SUM delta). The fix's re-included bystander IS counted here, so groupA avg(50,100)=75
  // stays correct. This proves the fix reaches the GROUP BY path; the SUM/COUNT gap above is the
  // downstream delta-aggregation, not GROUP BY dispatch.
  @IsTest
  static void groupByAverageBystanderStaysCorrect() {
    RollupParent__c parent = seed();
    RollupParent__c before = read(parent.Id);
    Assert.isTrue(before.GroupByAvgField__c?.contains('75'), 'baseline: groupA AVERAGE(50,100)=75: ' + before.GroupByAvgField__c);

    Test.startTest();
    bystanderUpdate(child(parent.Id, 'c1')); // pure bystander in groupA
    Test.stopTest();

    RollupParent__c after = read(parent.Id);
    Assert.areEqual(before.GroupByAvgField__c, after.GroupByAvgField__c, 'GROUP BY + AVERAGE base op: bystander update leaves the grouping unchanged');
    Assert.isTrue(after.GroupByAvgField__c?.contains('75'), 'GROUP BY + AVERAGE: groupA must stay avg 75 (bystander counted): ' + after.GroupByAvgField__c);
  }
}
