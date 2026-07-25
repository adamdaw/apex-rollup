/**
 * Empirical repro of audit finding F1 (changed-fields bystander scope).
 *
 * The vendored "bystander" fix keeps an unchanged bystander child inside the aggregate on a
 * changed-fields update so it is not silently dropped (the SUM 100->50 defect it closed).
 * F1: AverageRollupCalculator / FirstLastRollupCalculator / GroupByCalculator OVERRIDE
 * performRollup without calling super, so the fix's "unchanged bystander" early-return guard
 * never runs for AVERAGE / FIRST / LAST / GROUP BY. On an all-bystander update the updated
 * child is dropped and the parent is recomputed over the INCOMPLETE remaining set.
 *
 * Each test asserts BOTH halves of the contrast:
 *   - control (identical rollup, NO ChangedFieldsOnCalcItem__c)  -> stays correct  (guard N/A)
 *   - changed-fields rollup                                       -> corrupted value (F1)
 * Green = F1 reproduced exactly. The SUM base op is verified unaffected by the sibling test
 * CustomMetadataDrivenTests.changedFieldBystanderUpdateShouldNotDropChildFromRollup.
 */
// Engine-correctness test: runs in system mode (no System.runAs persona) to isolate the rollup
// calculation from FLS. The RollupReproAccess permission set grants its test-only fields.
@IsTest
private class ZZF1ReproTest {
  @TestSetup
  static void setup() {
    upsert as system new RollupSettings__c(IsEnabled__c = true);
  }

  // parent + children c1=50, c2=100; the changed-fields rollups AND their no-changed-fields
  // controls all run on RollupChild__c DML.
  static RollupParent__c seed() {
    RollupParent__c parent = new RollupParent__c(Name = 'p');
    insert as system parent;
    insert as system new List<RollupChild__c>{
      new RollupChild__c(Name = 'c1', NumberField__c = 50, TextField__c = 'a', RollupParent__c = parent.Id),
      new RollupChild__c(Name = 'c2', NumberField__c = 100, TextField__c = 'b', RollupParent__c = parent.Id)
    };
    return parent;
  }
  static RollupChild__c child(Id pid, String nm) {
    return [SELECT Id, TextField__c FROM RollupChild__c WHERE Name = :nm AND RollupParent__c = :pid WITH SYSTEM_MODE];
  }
  static RollupParent__c read(Id pid) {
    return [
      SELECT AverageField__c, AverageControl__c, LastField__c, LastControl__c
      FROM RollupParent__c WHERE Id = :pid WITH SYSTEM_MODE
    ];
  }
  static void bystanderUpdate(RollupChild__c c) {
    c.TextField__c = 'bystander only - NumberField__c untouched';
    update as system c;
  }

  // AVERAGE: baseline avg(50,100)=75. Bystander-update c1 -> F1 drops c1 -> avg({100})=100.
  @IsTest
  static void averageBystanderDropsUpdatedChild() {
    RollupParent__c parent = seed();
    RollupParent__c b = read(parent.Id);
    Assert.areEqual(75, b.AverageField__c, 'baseline changed-fields AVERAGE');
    Assert.areEqual(75, b.AverageControl__c, 'baseline control AVERAGE');

    Test.startTest();
    bystanderUpdate(child(parent.Id, 'c1'));
    Test.stopTest();

    RollupParent__c a = read(parent.Id);
    Assert.areEqual(75, a.AverageControl__c, 'CONTROL (no changed-fields): AVERAGE unaffected by a bystander update');
    Assert.areEqual(75, a.AverageField__c, 'FIX: changed-fields AVERAGE must stay 75 after a bystander update');
  }

  // AVERAGE mirror: bystander-update c2 -> F1 drops c2 -> avg({50})=50.
  @IsTest
  static void averageBystanderDropsUpdatedChildMirror() {
    RollupParent__c parent = seed();
    Test.startTest();
    bystanderUpdate(child(parent.Id, 'c2'));
    Test.stopTest();
    RollupParent__c a = read(parent.Id);
    Assert.areEqual(75, a.AverageControl__c, 'CONTROL: AVERAGE stays 75');
    Assert.areEqual(75, a.AverageField__c, 'FIX: changed-fields AVERAGE (mirror) must stay 75');
  }

  // LAST (cursor-heavy op the remediation targets): order by NumberField asc -> LAST=c2(100).
  // Bystander-update c2 -> F1 drops c2 -> LAST over {c1=50}=50.
  @IsTest
  static void lastBystanderDropsUpdatedChild() {
    RollupParent__c parent = seed();
    RollupParent__c b = read(parent.Id);
    Assert.areEqual(100, b.LastField__c, 'baseline changed-fields LAST');
    Assert.areEqual(100, b.LastControl__c, 'baseline control LAST');

    Test.startTest();
    bystanderUpdate(child(parent.Id, 'c2')); // c2 is the current LAST
    Test.stopTest();

    RollupParent__c a = read(parent.Id);
    Assert.areEqual(100, a.LastControl__c, 'CONTROL (no changed-fields): LAST unaffected by a bystander update');
    Assert.areEqual(100, a.LastField__c, 'FIX: changed-fields LAST must stay 100 after a bystander update');
  }
}
