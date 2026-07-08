/**
 * @description Memory hygiene: deactivates expired memories (`Expires_At__c` in the
 * past) and stale ones that were captured long ago but never recalled (no
 * `Last_Accessed__c`, `Access_Count__c` 0/null, older than the stale window).
 * Deactivation is a soft delete — `Is_Active__c = false` keeps the row auditable and
 * reversible while removing it from recall.
 *
 * Schedule it (e.g. nightly) with:
 * `System.schedule('AAO Memory Janitor', '0 0 3 * * ?', new MemoryJanitorSchedulable());`
 * @group Memory
 */
public with sharing class MemoryJanitorSchedulable implements Schedulable {
  /** @description Never-recalled memories older than this many days go inactive. */
  @TestVisible
  private static Integer staleDays = 180;

  private static final Integer BATCH_LIMIT = 2000;

  /**
   * @description Scheduled entry point.
   * @param context Scheduler context (unused).
   */
  public void execute(SchedulableContext context) {
    List<Agent_Memory__c> toDeactivate = new List<Agent_Memory__c>();

    for (Agent_Memory__c row : [
      SELECT Id
      FROM Agent_Memory__c
      WHERE Is_Active__c = TRUE AND Expires_At__c < :System.now()
      LIMIT :BATCH_LIMIT
    ]) {
      toDeactivate.add(new Agent_Memory__c(Id = row.Id, Is_Active__c = false));
    }

    Datetime staleCutoff = System.now().addDays(-staleDays);
    for (Agent_Memory__c row : [
      SELECT Id
      FROM Agent_Memory__c
      WHERE
        Is_Active__c = TRUE
        AND Last_Accessed__c = NULL
        AND (Access_Count__c = NULL
        OR Access_Count__c = 0)
        AND CreatedDate < :staleCutoff
      LIMIT :BATCH_LIMIT
    ]) {
      toDeactivate.add(new Agent_Memory__c(Id = row.Id, Is_Active__c = false));
    }

    if (!toDeactivate.isEmpty()) {
      update toDeactivate;
    }
  }
}
