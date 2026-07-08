/**
 * @description Tests `AgentMonitorController` (run list/detail/tree, cancel, rerun),
 * the engine's cancelled-run guards, and `AgentWatchdogSchedulable` (stuck-run timeout
 * and orphaned-Busy-session release).
 * @group Tests
 */
@IsTest
private class AgentMonitorControllerTest {
  private static Id makeRun(String status) {
    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{"task":"x"}', 'Apex');
    if (status != 'Running') {
      update new aao__Agent_Run__c(Id = runId, aao__Status__c = status);
    }
    return runId;
  }

  @IsTest
  static void testGetRunsFilters() {
    makeRun('Running');
    Id doneId = makeRun('Succeeded');

    List<AgentMonitorController.RunSummary> all = AgentMonitorController.getRuns(
      null,
      null
    );
    System.assertEquals(2, all.size());

    List<AgentMonitorController.RunSummary> succeeded = AgentMonitorController.getRuns(
      'Succeeded',
      null
    );
    System.assertEquals(1, succeeded.size());
    System.assertEquals(doneId, succeeded[0].runId);

    System.assertEquals(
      2,
      AgentMonitorController.getRuns(null, 'CRUD_Agent').size()
    );
    System.assertEquals(
      0,
      AgentMonitorController.getRuns(null, 'Orchestrator_Agent').size()
    );
  }

  @IsTest
  static void testGetRunDetailWithSteps() {
    Id runId = makeRun('Running');
    ExecutionLogger.logStep(
      runId,
      new AgentStepLog(
        1,
        'ToolCall',
        null,
        null,
        '{"object":"Account"}',
        '{"success":true}',
        'Completed',
        'QuerySalesforceTool'
      )
    );

    AgentMonitorController.RunDetail detail = AgentMonitorController.getRunDetail(
      runId
    );
    System.assertEquals(runId, detail.summary.runId);
    System.assertEquals(1, detail.steps.size());
    System.assertEquals('QuerySalesforceTool', detail.steps[0].toolName);
    System.assertEquals(1, detail.steps[0].stepNumber);

    AgentMonitorController.StepDetail full = AgentMonitorController.getStepDetail(
      detail.steps[0].stepId
    );
    System.assert(
      full.toolInput.contains('Account'),
      'lazy-loaded detail carries the full tool input'
    );
  }

  @IsTest
  static void testGetRunTreeWalksFamily() {
    Id parentId = makeRun('Running');
    Id childId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'SubAgent');
    update new aao__Agent_Run__c(
      Id = childId,
      Parent_Run__c = parentId,
      Depth__c = 1
    );

    // From the child, the tree resolves the root and returns the whole family.
    List<AgentMonitorController.RunSummary> family = AgentMonitorController.getRunTree(
      childId
    );
    System.assertEquals(2, family.size());
    System.assertEquals(parentId, family[0].runId, 'root first');
    System.assertEquals(childId, family[1].runId);
    System.assertEquals(parentId, family[1].parentRunId);
  }

  @IsTest
  static void testCancelRunStopsEngine() {
    Id runId = makeRun('Running');

    Test.startTest();
    AgentMonitorController.cancelRun(runId);
    Test.stopTest();

    aao__Agent_Run__c run = [
      SELECT aao__Status__c, aao__Error_Message__c, aao__Finished_At__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
    ];
    System.assertEquals('Cancelled', run.aao__Status__c);
    System.assertNotEquals(null, run.aao__Finished_At__c);

    // The engine's guard refuses to run further steps for the cancelled run.
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"should never be used"}}');
    LLMClientFactory.setMock(mock);
    AgentEngine.runLLMStep(
      'CRUD_Agent',
      '{}',
      'Apex',
      runId,
      new List<LLMMessage>{ new LLMMessage('user', '{}') }
    );

    List<aao__Agent_Step__c> steps = [
      SELECT aao__Status__c, aao__Step_Type__c
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId
    ];
    System.assertEquals(1, steps.size());
    System.assertEquals('Cancelled', steps[0].aao__Status__c);
    System.assertEquals(
      'Cancelled',
      [SELECT aao__Status__c FROM aao__Agent_Run__c WHERE Id = :runId]
      .aao__Status__c,
      'run stays Cancelled — the LLM step must not finish it as Succeeded'
    );
  }

  @IsTest
  static void testCancelRejectsFinishedRun() {
    Id runId = makeRun('Succeeded');
    try {
      AgentMonitorController.cancelRun(runId);
      System.assert(false, 'expected AuraHandledException');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @IsTest
  static void testRerunStartsFreshRun() {
    Id originalId = makeRun('Succeeded');

    Test.startTest();
    Id newRunId = AgentMonitorController.rerun(originalId);
    Test.stopTest();

    System.assertNotEquals(originalId, newRunId);
    aao__Agent_Run__c newRun = [
      SELECT aao__Agent__c, aao__Input_Context__c, aao__Trigger_Type__c
      FROM aao__Agent_Run__c
      WHERE Id = :newRunId
    ];
    System.assertEquals('CRUD_Agent', newRun.aao__Agent__c);
    System.assertEquals('{"task":"x"}', newRun.aao__Input_Context__c);
  }

  @IsTest
  static void testWatchdogTimesOutStuckRunAndReleasesSession() {
    // Stuck run: Running with an old Started_At.
    Id stuckId = makeRun('Running');
    Datetime old = System.now().addHours(-3);
    update new aao__Agent_Run__c(Id = stuckId, aao__Started_At__c = old);

    // Fresh run: must be left alone.
    Id freshId = makeRun('Running');

    // Orphaned Busy session: no live run attached.
    Id orphanedSessionId = SessionService.startSession('CRUD_Agent', 'hi');
    update new Agent_Session__c(
      Id = orphanedSessionId,
      Status__c = 'Busy',
      Last_Activity__c = old
    );

    Test.startTest();
    new AgentWatchdogSchedulable().execute(null);
    Test.stopTest();

    System.assertEquals(
      'Failed',
      [SELECT aao__Status__c FROM aao__Agent_Run__c WHERE Id = :stuckId]
      .aao__Status__c,
      'stuck run hard-failed'
    );
    System.assert(
      [
        SELECT aao__Error_Message__c
        FROM aao__Agent_Run__c
        WHERE Id = :stuckId
      ]
      .aao__Error_Message__c.contains('watchdog')
    );
    System.assertEquals(
      'Running',
      [SELECT aao__Status__c FROM aao__Agent_Run__c WHERE Id = :freshId]
      .aao__Status__c,
      'fresh run untouched'
    );
    System.assertEquals(
      'Active',
      [SELECT Status__c FROM Agent_Session__c WHERE Id = :orphanedSessionId]
      .Status__c,
      'orphaned Busy session released'
    );
  }

  @IsTest
  static void testWatchdogSparesBusySessionWithLiveRun() {
    Id sessionId = SessionService.startSession('CRUD_Agent', 'hi');
    Id runId = makeRun('Running'); // young Running run
    update new aao__Agent_Run__c(Id = runId, Session__c = sessionId);
    update new Agent_Session__c(
      Id = sessionId,
      Status__c = 'Busy',
      Last_Activity__c = System.now().addHours(-3)
    );

    Test.startTest();
    new AgentWatchdogSchedulable().execute(null);
    Test.stopTest();

    System.assertEquals(
      'Busy',
      [SELECT Status__c FROM Agent_Session__c WHERE Id = :sessionId]
      .Status__c,
      'session with a live run stays Busy'
    );
  }
}
