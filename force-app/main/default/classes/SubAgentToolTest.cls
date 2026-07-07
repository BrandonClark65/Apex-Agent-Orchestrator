/**
 * @description Tests the multi-agent collaboration flow: `SubAgentTool` starting a child run,
 * the parent run suspending on a `'Pending'` ToolCall step, and `ExecutionLogger.finishRun`
 * resuming the parent with the child's final output (success and failure), plus the
 * nesting-depth guard and argument validation, and a sub-agent inside a parallel tool batch.
 *
 * Like `AgentEngineTest`, these tests drive `runLLMStep`/`runToolStep` directly in the same
 * sequence the platform-event trigger would, rather than relying on the event bus in a test
 * context. The parent runs as `Orchestrator_Agent` delegating to `CRUD_Agent`, using the
 * deployed custom metadata for both.
 * @group Tests
 */
@IsTest
private class SubAgentToolTest {
  private static final String PARENT_AGENT = 'Orchestrator_Agent';
  private static final String CHILD_AGENT = 'CRUD_Agent';

  private static aao__Agent_Run__c getRun(Id runId) {
    return [
      SELECT
        aao__Status__c,
        aao__Final_Output__c,
        aao__Error_Message__c,
        History_Json__c,
        PendingToolCount__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
    ];
  }

  private static aao__Agent_Run__c getChildRun(Id parentRunId) {
    return [
      SELECT
        Id,
        aao__Status__c,
        aao__Trigger_Type__c,
        aao__Input_Context__c,
        History_Json__c,
        Parent_Run__c,
        Parent_Step__c,
        Depth__c
      FROM aao__Agent_Run__c
      WHERE Parent_Run__c = :parentRunId
      LIMIT 1
    ];
  }

  // Runs the parent up to the point where it has delegated to the child and suspended.
  private static Id startDelegatedRun(
    String inputJson,
    List<LLMMessage> history
  ) {
    Id parentRunId = ExecutionLogger.startRun(PARENT_AGENT, inputJson, 'Apex');
    history.add(new LLMMessage('user', inputJson));

    AgentEngine.runLLMStep(
      PARENT_AGENT,
      inputJson,
      'Apex',
      parentRunId,
      history
    );
    AgentEngine.runToolStep(
      PARENT_AGENT,
      'Apex',
      parentRunId,
      history,
      'SubAgentTool',
      new Map<String, Object>{
        'agentName' => CHILD_AGENT,
        'input' => new Map<String, Object>{ 'task' => 'Count accounts' }
      }
    );
    return parentRunId;
  }

  // Simulates the event hop that starts the child's LLM step.
  private static void driveChildLLMStep(aao__Agent_Run__c childRun) {
    List<LLMMessage> childHistory = (List<LLMMessage>) JSON.deserialize(
      childRun.History_Json__c,
      List<LLMMessage>.class
    );
    AgentEngine.runLLMStep(
      CHILD_AGENT,
      childRun.aao__Input_Context__c,
      'SubAgent',
      childRun.Id,
      childHistory
    );
  }

  // Simulates the event hop that re-enters the parent's LLM step after resume.
  private static void driveParentLLMStep(Id parentRunId, String inputJson) {
    List<LLMMessage> mergedHistory = (List<LLMMessage>) JSON.deserialize(
      getRun(parentRunId).History_Json__c,
      List<LLMMessage>.class
    );
    AgentEngine.runLLMStep(
      PARENT_AGENT,
      inputJson,
      'Apex',
      parentRunId,
      mergedHistory
    );
  }

  @IsTest
  static void testDelegationHappyPath() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse(
      '{"tool":"SubAgentTool","args":{"agentName":"CRUD_Agent","input":{"task":"Count accounts"}}}'
    );
    mock.addResponse('{"final":{"answer":"42 accounts"}}'); // child run
    mock.addResponse('{"final":{"message":"Delegation complete"}}'); // parent resumes
    LLMClientFactory.setMock(mock);

    String inputJson = '{"task":"Have the CRUD agent count accounts"}';
    List<LLMMessage> history = new List<LLMMessage>();

    Test.startTest();
    Id parentRunId = startDelegatedRun(inputJson, history);

    // Parent is suspended: still Running, with a Pending ToolCall step and no next step scheduled.
    System.assertEquals('Running', getRun(parentRunId).aao__Status__c);
    aao__Agent_Step__c pendingStep = [
      SELECT Id, aao__Status__c, aao__Tool__c, aao__Tool_Output__c
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :parentRunId AND aao__Step_Type__c = 'ToolCall'
      LIMIT 1
    ];
    System.assertEquals('Pending', pendingStep.aao__Status__c);
    System.assertEquals('SubAgentTool', pendingStep.aao__Tool__c);

    // Child run was created and linked back to the parent's pending step.
    aao__Agent_Run__c childRun = getChildRun(parentRunId);
    System.assertEquals('Running', childRun.aao__Status__c);
    System.assertEquals('SubAgent', childRun.aao__Trigger_Type__c);
    System.assertEquals(pendingStep.Id, childRun.Parent_Step__c);
    System.assertEquals(1, Integer.valueOf(childRun.Depth__c));

    // Child finishes -> finishRun resumes the parent.
    driveChildLLMStep(childRun);

    System.assertEquals(
      'Succeeded',
      [
        SELECT aao__Status__c
        FROM aao__Agent_Run__c
        WHERE Id = :childRun.Id
      ]
      .aao__Status__c
    );

    aao__Agent_Step__c resumedStep = [
      SELECT aao__Status__c, aao__Tool_Output__c
      FROM aao__Agent_Step__c
      WHERE Id = :pendingStep.Id
    ];
    System.assertEquals('Completed', resumedStep.aao__Status__c);
    System.assert(
      resumedStep.aao__Tool_Output__c.contains('42 accounts'),
      'Pending step should be completed with the child final output'
    );
    System.assert(
      getRun(parentRunId).History_Json__c.contains('42 accounts'),
      'Child output should be merged into parent history'
    );

    // Parent re-enters its LLM loop and finalizes.
    driveParentLLMStep(parentRunId, inputJson);
    Test.stopTest();

    aao__Agent_Run__c parent = getRun(parentRunId);
    System.assertEquals('Succeeded', parent.aao__Status__c);
    System.assert(parent.aao__Final_Output__c.contains('Delegation complete'));
  }

  @IsTest
  static void testChildFailureSurfacesToParent() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse(
      '{"tool":"SubAgentTool","args":{"agentName":"CRUD_Agent","input":{"task":"Count accounts"}}}'
    );
    mock.addResponse('{"final":{"error":"Cannot comply"}}'); // child hard-fails
    mock.addResponse('{"final":{"message":"Handled sub-agent failure"}}');
    LLMClientFactory.setMock(mock);

    String inputJson = '{"task":"Have the CRUD agent count accounts"}';
    List<LLMMessage> history = new List<LLMMessage>();

    Test.startTest();
    Id parentRunId = startDelegatedRun(inputJson, history);
    aao__Agent_Run__c childRun = getChildRun(parentRunId);

    driveChildLLMStep(childRun);

    System.assertEquals(
      'Failed',
      [
        SELECT aao__Status__c
        FROM aao__Agent_Run__c
        WHERE Id = :childRun.Id
      ]
      .aao__Status__c
    );

    // The parent's pending step failed, but the parent itself resumed and can recover.
    aao__Agent_Step__c resumedStep = [
      SELECT aao__Status__c, aao__Tool_Output__c
      FROM aao__Agent_Step__c
      WHERE Id = :childRun.Parent_Step__c
    ];
    System.assertEquals('Failed', resumedStep.aao__Status__c);
    System.assert(
      resumedStep.aao__Tool_Output__c.contains('Cannot comply'),
      'Failed step output should carry the child error'
    );

    driveParentLLMStep(parentRunId, inputJson);
    Test.stopTest();

    aao__Agent_Run__c parent = getRun(parentRunId);
    System.assertEquals('Succeeded', parent.aao__Status__c);
    System.assert(
      parent.aao__Final_Output__c.contains('Handled sub-agent failure')
    );
  }

  @IsTest
  static void testSubAgentInParallelBatch() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse(
      '{"tools":[{"tool":"QuerySalesforceTool","args":{"object":"Account"}},' +
      '{"tool":"SubAgentTool","args":{"agentName":"CRUD_Agent","input":{"task":"Describe Account"}}}]}'
    );
    mock.addResponse('{"final":{"answer":"Account described"}}'); // child run
    mock.addResponse('{"final":{"message":"Parallel batch done"}}'); // parent
    LLMClientFactory.setMock(mock);

    String inputJson = '{"task":"Query accounts and delegate a describe"}';
    List<LLMMessage> history = new List<LLMMessage>();
    Id parentRunId = ExecutionLogger.startRun(PARENT_AGENT, inputJson, 'Apex');
    history.add(new LLMMessage('user', inputJson));

    Test.startTest();
    AgentEngine.runLLMStep(
      PARENT_AGENT,
      inputJson,
      'Apex',
      parentRunId,
      history
    );

    // Parallel mode: pass empty histories, tools read/write History_Json__c directly.
    AgentEngine.runToolStep(
      PARENT_AGENT,
      'Apex',
      parentRunId,
      new List<LLMMessage>(),
      'QuerySalesforceTool',
      new Map<String, Object>{ 'object' => 'Account' }
    );
    AgentEngine.runToolStep(
      PARENT_AGENT,
      'Apex',
      parentRunId,
      new List<LLMMessage>(),
      'SubAgentTool',
      new Map<String, Object>{
        'agentName' => CHILD_AGENT,
        'input' => new Map<String, Object>{ 'task' => 'Describe Account' }
      }
    );

    // Query tool decremented 2 -> 1; the suspended sub-agent call must NOT have decremented.
    System.assertEquals(
      1,
      Integer.valueOf(getRun(parentRunId).PendingToolCount__c),
      'Suspended sub-agent call must defer its decrement until the child finishes'
    );

    // Child finishes -> resume performs the deferred decrement (1 -> 0) and merges history.
    driveChildLLMStep(getChildRun(parentRunId));

    aao__Agent_Run__c parentAfterResume = getRun(parentRunId);
    System.assertEquals(
      0,
      Integer.valueOf(parentAfterResume.PendingToolCount__c)
    );
    System.assert(
      parentAfterResume.History_Json__c.contains('Account described'),
      'Child output should be merged into parent history'
    );

    driveParentLLMStep(parentRunId, inputJson);
    Test.stopTest();

    aao__Agent_Run__c parent = getRun(parentRunId);
    System.assertEquals('Succeeded', parent.aao__Status__c);
    System.assert(parent.aao__Final_Output__c.contains('Parallel batch done'));
  }

  @IsTest
  static void testDepthLimitBlocksNesting() {
    Id runId = ExecutionLogger.startRun(PARENT_AGENT, '{"task":"x"}', 'Apex');
    AgentToolContext.runId = runId;
    AgentToolContext.depth = SubAgentTool.MAX_DEPTH;

    AgentToolResult result = new SubAgentTool()
      .run(
        new Map<String, Object>{
          'agentName' => CHILD_AGENT,
          'input' => 'Count accounts'
        }
      );

    System.assertEquals(false, result.success);
    System.assert(
      result.message.contains('depth limit'),
      'Expected depth limit error, got: ' + result.message
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM aao__Agent_Run__c
        WHERE Parent_Run__c = :runId
      ],
      'No child run should be created past the depth limit'
    );
  }

  @IsTest
  static void testArgumentValidation() {
    Id runId = ExecutionLogger.startRun(PARENT_AGENT, '{"task":"x"}', 'Apex');
    AgentToolContext.runId = runId;
    AgentToolContext.depth = 0;
    SubAgentTool tool = new SubAgentTool();

    AgentToolResult missingAgent = tool.run(
      new Map<String, Object>{ 'input' => 'x' }
    );
    System.assertEquals(false, missingAgent.success);
    System.assert(missingAgent.message.contains('agentName'));

    AgentToolResult missingInput = tool.run(
      new Map<String, Object>{ 'agentName' => CHILD_AGENT }
    );
    System.assertEquals(false, missingInput.success);
    System.assert(missingInput.message.contains('input'));

    AgentToolResult unknownAgent = tool.run(
      new Map<String, Object>{ 'agentName' => 'No_Such_Agent', 'input' => 'x' }
    );
    System.assertEquals(false, unknownAgent.success);
    System.assert(unknownAgent.message.contains('Agent not found'));
  }
}
