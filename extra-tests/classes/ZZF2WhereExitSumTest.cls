/**
 * F2 repro: changed-fields SUM (base op, INCREMENTAL path) + a where clause.
 * A child leaves the where scope (TextField__c -> 'EXCLUDE') while the TRACKED field NumberField__c
 * is untouched. isUnchangedBystander (RollupCalculator.cls) checks only the changed-field list, not
 * the where clause, so it misclassifies the departing child as an unchanged bystander -> the no-op
 * guard fires (or the departure is never subtracted) -> the parent stays stale-high.
 *   children c1=50, c2=100 (both 'keep'); baseline SUM=150.
 *   update c1.TextField__c='EXCLUDE' (NumberField untouched): c1 exits scope.
 *     correct  = SUM over in-scope {c2} = 100  (control proves this)
 *     F2 bug   = 150 (c1 never removed)  |  no-op also = 150
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZF2WhereExitSumTest {
  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }
  static RollupParent__c seed() {
    RollupParent__c p = new RollupParent__c(Name = 'p');
    insert as system p;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 50, TextField__c = 'keep', RollupParent__c = p.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 100, TextField__c = 'keep', RollupParent__c = p.Id)
    };
    return p;
  }
  static RollupParent__c read(Id pid) {
    return [SELECT WhereSumField__c, WhereSumControl__c FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE];
  }
  @IsTest
  static void whereExitBystanderMustBeRemovedFromSum() {
    RollupParent__c parent = seed();
    RollupParent__c b = read(parent.Id);
    Assert.areEqual(150, b.WhereSumField__c, 'baseline changed-fields SUM');
    Assert.areEqual(150, b.WhereSumControl__c, 'baseline control SUM');

    Test.startTest();
    RollupChild__c c1 = [SELECT Id, TextField__c FROM RollupChild__c WHERE Name = 'c1' AND RollupParent__c = :parent.Id WITH SYSTEM_MODE];
    c1.TextField__c = 'EXCLUDE'; // exits where clause; NumberField__c (tracked) untouched
    update as system c1;
    Test.stopTest();

    RollupParent__c a = read(parent.Id);
    Assert.areEqual(100, a.WhereSumControl__c, 'CONTROL (no changed-fields): c1 exited scope, SUM={c2}=100');
    Assert.areEqual(100, a.WhereSumField__c, 'F2: changed-fields SUM must drop departed c1 and equal 100, not 150 (stale)');
  }
}
