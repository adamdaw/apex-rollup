/**
 * Question 2 (WHERE-CLAUSE INTERACTION) audit of the F1 bystander fix in RollupCalculator.winnowItems:
 *   if (this.isFullRecalc && isUnchangedBystander) { shouldAddToResults = true; }
 *
 * Central question: on a FULL RECALC (AVERAGE), can the flip wrongly INCLUDE a calc item that FAILS
 * the per-rollup CalcItemWhereClause__c but had no tracked-field change?
 *
 * Config: AVERAGE of RollupChild__c.NumberField__c into RollupParent__c, with
 *   CalcItemWhereClause__c = TextField__c != 'EXCLUDE'
 *   ChangedFieldsOnCalcItem__c = NumberField__c
 * A no-changed-fields CONTROL rollup with the same where clause writes WhereAvgControl__c.
 *
 * Children: c1(Num=50,Text='keep'), c2(Num=100,Text='keep'), c3(Num=1000,Text='EXCLUDE').
 * Baseline AVERAGE over in-where children = avg(50,100) = 75; c3 (out-of-where) must never count.
 * The "bystander" edit touches DateField__c only: NumberField__c (tracked) and TextField__c (where)
 * are BOTH untouched, so c3 stays out-of-where AND is an unchanged bystander.
 *
 * Each test asserts the parent stays 75. A failure with actual 383.33 (= avg{50,100,1000}) proves the
 * fix pulled the excluded child into the aggregate.
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZWhereClauseBystanderTest {
  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  static RollupParent__c seed() {
    RollupParent__c parent = new RollupParent__c(Name = 'p');
    insert as system parent;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 50, TextField__c = 'keep', RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 100, TextField__c = 'keep', RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c3', NumberField__c = 1000, TextField__c = 'EXCLUDE', RollupParent__c = parent.Id)
    };
    return parent;
  }
  static RollupChild__c child(Id pid, String nm) {
    return [SELECT Id, DateField__c, NumberField__c, TextField__c FROM RollupChild__c WHERE Name = :nm AND RollupParent__c = :pid WITH SYSTEM_MODE];
  }
  static RollupParent__c read(Id pid) {
    return [SELECT WhereAvgField__c, WhereAvgControl__c FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE];
  }
  // bystander edit: only DateField__c changes; NumberField__c (tracked) + TextField__c (where) untouched.
  static RollupChild__c bystander(RollupChild__c c) {
    c.DateField__c = System.today();
    return c;
  }

  // Sanity: the where clause excludes c3 at baseline for BOTH rollups.
  @IsTest
  static void baselineExcludesOutOfWhereChild() {
    RollupParent__c parent = seed();
    RollupParent__c b = read(parent.Id);
    Assert.areEqual(75, b.WhereAvgField__c, 'baseline changed-fields AVERAGE excludes out-of-where c3');
    Assert.areEqual(75, b.WhereAvgControl__c, 'baseline control AVERAGE excludes out-of-where c3');
  }

  // Scenario A: bystander-update ONLY the out-of-where child c3.
  // Expected: c3 fails the where clause on both new and old value, so Rollup.filter drops it -> no recalc.
  @IsTest
  static void bystanderUpdateOnlyOutOfWhereChild() {
    RollupParent__c parent = seed();
    Test.startTest();
    update as system bystander(child(parent.Id, 'c3'));
    Test.stopTest();
    RollupParent__c a = read(parent.Id);
    Assert.areEqual(75, a.WhereAvgControl__c, 'CONTROL: out-of-where bystander update must not change the average');
    Assert.areEqual(75, a.WhereAvgField__c, 'FIX: out-of-where bystander update must not pull c3 into the average');
  }

  // Scenario B: bystander-update an IN-where child c1 ONLY (c3 is merely a retrieved sibling, not in the DML).
  // Expected: c3 not in oldCalcItems -> changedFieldEvaluator.matches(c3)==true -> not an unchanged
  // bystander -> excluded by the where clause as usual. Stays 75.
  @IsTest
  static void bystanderUpdateInWhereChildOutOfWhereIsSibling() {
    RollupParent__c parent = seed();
    Test.startTest();
    update as system bystander(child(parent.Id, 'c1'));
    Test.stopTest();
    RollupParent__c a = read(parent.Id);
    Assert.areEqual(75, a.WhereAvgControl__c, 'CONTROL: in-where bystander update keeps average at 75');
    Assert.areEqual(75, a.WhereAvgField__c, 'FIX: in-where bystander update must keep out-of-where sibling c3 excluded');
  }

  // Scenario C (the dangerous case): MIXED DML batch -> bystander-update an in-where child c1 AND the
  // out-of-where child c3 in the SAME transaction. c1 forces the AVERAGE full recalc; c3 rides along in
  // oldCalcItems, so during winnowItems it is out-of-where AND an unchanged bystander.
  // If the fix flips c3 into the result set, the average becomes avg{50,100,1000} = 383.33.
  @IsTest
  static void bystanderUpdateMixedBatchInAndOutOfWhere() {
    RollupParent__c parent = seed();
    Test.startTest();
    update as system new List<RollupChild__c>{ bystander(child(parent.Id, 'c1')), bystander(child(parent.Id, 'c3')) };
    Test.stopTest();
    RollupParent__c a = read(parent.Id);
    Assert.areEqual(75, a.WhereAvgControl__c, 'CONTROL: mixed-batch bystander update keeps average at 75');
    Assert.areEqual(75, a.WhereAvgField__c, 'FIX: mixed-batch bystander update must NOT pull out-of-where c3 into the average');
  }
}
