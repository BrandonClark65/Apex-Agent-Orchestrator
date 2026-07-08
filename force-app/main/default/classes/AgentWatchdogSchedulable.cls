/**
 * @description Safety net for runs and sessions stuck in transient states: a run whose
 * queueable died without reaching `finishRun` stays `Running` forever (and, if it is a
 * sub-agent child, leaves its parent suspended — the known limitation from the
 * multi-agent work), and a session whose turn died the same way stays `Busy`. On each
 * scheduled execution this hard-fails runs `Running` longer than the timeout via
 * `ExecutionLogger.finishRun` (which releases sessions and resumes parents through the
 * normal choke point) and releases any `Busy` session with no live run left.
 *
 * Schedule it (e.g. hourly) with:
 * `System.schedule('AAO Watchdog', '0 0 * * * ?', new AgentWatchdogSchedulable());`
 * @group Agent Engine
 */
public with sharing class AgentWatchdogSchedulable implements Schedulable {
  /** @description Runs `Running` longer than this are considered dead. */
  @TestVisible
  private static Integer timeoutMinutes = 60;

  private static final Integer BATCH_LIMIT = 100;

  /**
   * @description Scheduled entry point: times out dead runs, then releases orphaned
   * `Busy` sessions.
   * @param context Scheduler context (unused).
   */
  public void execute(SchedulableContext context) {
    timeOutStuckRuns();
    releaseOrphanedSessions();
  }

  private static void timeOutStuckRuns() {
    Datetime cutoff = System.now().addMinutes(-timeoutMinutes);
    List<aao__Agent_Run__c> stuck = [
      SELECT Id
      FROM aao__Agent_Run__c
      WHERE aao__Status__c = 'Running' AND aao__Started_At__c < :cutoff
      LIMIT :BATCH_LIMIT
    ];

    for (aao__Agent_Run__c run : stuck) {
      try {
        // finishRun releases the run's session and resumes a suspended parent,
        // exactly like any other termination.
        ExecutionLogger.finishRun(
          run.Id,
          null,
          'Failed',
          'Timed out by watchdog after ' + timeoutMinutes + ' minutes'
        );
      } catch (Exception e) {
        System.debug(
          LoggingLevel.ERROR,
          'Watchdog could not finish run ' + run.Id + ': ' + e.getMessage()
        );
      }
    }
  }

  private static void releaseOrphanedSessions() {
    Datetime cutoff = System.now().addMinutes(-timeoutMinutes);
    List<Agent_Session__c> busySessions = [
      SELECT Id
      FROM Agent_Session__c
      WHERE Status__c = 'Busy' AND Last_Activity__c < :cutoff
      LIMIT :BATCH_LIMIT
    ];
    if (busySessions.isEmpty()) {
      return;
    }

    // Only release sessions with no live run — an in-flight (younger than cutoff)
    // turn still owns its session.
    Set<Id> withLiveRuns = new Set<Id>();
    for (aao__Agent_Run__c run : [
      SELECT Session__c
      FROM aao__Agent_Run__c
      WHERE Session__c IN :busySessions AND aao__Status__c = 'Running'
    ]) {
      withLiveRuns.add(run.Session__c);
    }

    List<Agent_Session__c> toRelease = new List<Agent_Session__c>();
    for (Agent_Session__c session : busySessions) {
      if (!withLiveRuns.contains(session.Id)) {
        toRelease.add(
          new Agent_Session__c(Id = session.Id, Status__c = 'Active')
        );
      }
    }
    if (!toRelease.isEmpty()) {
      update toRelease;
    }
  }
}
