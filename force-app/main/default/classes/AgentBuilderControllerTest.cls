/**
 * @description Tests `AgentBuilderController` (agent configs with tool joins, tool
 * catalog with grant rollups, manifest preview, test-case save/load, test bench run),
 * `MemoryJanitorSchedulable` (expired + stale deactivation), and the reflection
 * consolidation pass in `MemoryCaptureQueueable`.
 * @group Tests
 */
@IsTest
private class AgentBuilderControllerTest {
  @IsTest
  static void testGetAgentsJoinsTools() {
    List<AgentBuilderController.AgentConfig> agents = AgentBuilderController.getAgents();
    System.assert(!agents.isEmpty());

    AgentBuilderController.AgentConfig crud = null;
    for (AgentBuilderController.AgentConfig config : agents) {
      if (config.developerName == 'CRUD_Agent') {
        crud = config;
      }
    }
    System.assertNotEquals(null, crud, 'CRUD_Agent present');
    System.assert(!crud.tools.isEmpty(), 'granted tools joined');
    System.assertEquals('Default_Memory', crud.memoryConfig);
  }

  @IsTest
  static void testGetToolCatalogRollsUpGrants() {
    List<AgentBuilderController.ToolInfo> catalog = AgentBuilderController.getToolCatalog();
    System.assert(!catalog.isEmpty());

    Boolean foundGrantedTool = false;
    for (AgentBuilderController.ToolInfo tool : catalog) {
      if (
        String.isNotBlank(tool.grantedAgents) &&
        tool.grantedAgents.contains('CRUD_Agent')
      ) {
        foundGrantedTool = true;
      }
    }
    System.assert(foundGrantedTool, 'at least one tool grants CRUD_Agent');
  }

  @IsTest
  static void testManifestPreviewMatchesEngine() {
    String manifest = AgentBuilderController.getManifestPreview('CRUD_Agent');
    System.assert(String.isNotBlank(manifest));
    System.assert(
      manifest.contains('QuerySalesforceTool') ||
        manifest.contains('CreateRecordTool'),
      'manifest lists granted tools'
    );
  }

  @IsTest
  static void testTestCaseSaveAndLoad() {
    Id caseId = AgentBuilderController.saveTestCase(
      'CRUD_Agent',
      'Portland accounts',
      '{"task":"Find Portland accounts"}'
    );
    System.assertNotEquals(null, caseId);

    List<AgentBuilderController.TestCaseInfo> cases = AgentBuilderController.getTestCases(
      'CRUD_Agent'
    );
    System.assertEquals(1, cases.size());
    System.assertEquals('Portland accounts', cases[0].name);
    System.assert(cases[0].inputJson.contains('Portland'));

    System.assertEquals(
      0,
      AgentBuilderController.getTestCases('Orchestrator_Agent').size()
    );
  }

  @IsTest
  static void testTestRunStartsRun() {
    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"ok"}}');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    Id runId = AgentBuilderController.testRun(
      'CRUD_Agent',
      '{"task":"smoke"}'
    );
    Test.stopTest();

    aao__Agent_Run__c run = [
      SELECT aao__Trigger_Type__c, aao__Status__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
    ];
    System.assertEquals('TestBench', run.aao__Trigger_Type__c);
    System.assertEquals('Succeeded', run.aao__Status__c);
  }

  @IsTest
  static void testMemoryJanitorDeactivatesExpiredAndStale() {
    List<Agent_Memory__c> rows = new List<Agent_Memory__c>{
      new Agent_Memory__c(
        Agent__c = 'CRUD_Agent',
        Scope__c = 'Agent',
        Type__c = 'Fact',
        Content__c = 'Expired',
        Is_Active__c = true,
        Expires_At__c = System.now().addDays(-1)
      ),
      new Agent_Memory__c(
        Agent__c = 'CRUD_Agent',
        Scope__c = 'Agent',
        Type__c = 'Fact',
        Content__c = 'Fresh and used',
        Is_Active__c = true,
        Access_Count__c = 5,
        Last_Accessed__c = System.now()
      )
    };
    insert rows;

    Test.startTest();
    new MemoryJanitorSchedulable().execute(null);
    Test.stopTest();

    Map<Id, Agent_Memory__c> after = new Map<Id, Agent_Memory__c>(
      [SELECT Id, Is_Active__c FROM Agent_Memory__c]
    );
    System.assertEquals(
      false,
      after.get(rows[0].Id).Is_Active__c,
      'expired memory deactivated'
    );
    System.assertEquals(
      true,
      after.get(rows[1].Id).Is_Active__c,
      'used memory untouched'
    );
  }

  @IsTest
  static void testReflectionConsolidationAtCap() {
    // Fill the agent to the reflection cap.
    List<Agent_Memory__c> lessons = new List<Agent_Memory__c>();
    for (Integer i = 0; i < 20; i++) {
      lessons.add(
        new Agent_Memory__c(
          Agent__c = 'CRUD_Agent',
          Scope__c = 'Agent',
          Type__c = 'Reflection',
          Content__c = 'Lesson number ' + i,
          Is_Active__c = true
        )
      );
    }
    insert lessons;

    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    update new aao__Agent_Run__c(
      Id = runId,
      aao__History_Json__c = '[{"role":"user","content":"hi"}]'
    );

    LLMClientMock mock = new LLMClientMock();
    // consolidation response (merged lessons), then the new reflection
    mock.addResponse('["Merged lesson A","Merged lesson B"]');
    mock.addResponse('Brand new lesson.');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    new MemoryCaptureQueueable(runId, 'CRUD_Agent', 'Default_Memory', false, true)
      .execute(null);
    Test.stopTest();

    Integer activeReflections = [
      SELECT COUNT()
      FROM Agent_Memory__c
      WHERE
        Agent__c = 'CRUD_Agent'
        AND Type__c = 'Reflection'
        AND Is_Active__c = TRUE
    ];
    System.assertEquals(
      3,
      activeReflections,
      '20 originals consolidated to 2 merged + 1 new lesson'
    );
  }
}
