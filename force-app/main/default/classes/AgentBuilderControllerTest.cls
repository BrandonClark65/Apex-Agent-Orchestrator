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
    System.assert(
      String.isBlank(crud.requiredCustomPermission),
      'packaged demo agents ship unrestricted'
    );
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
    Id runId = AgentBuilderController.testRun('CRUD_Agent', '{"task":"smoke"}');
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
    new MemoryCaptureQueueable(
        runId,
        'CRUD_Agent',
        'Default_Memory',
        false,
        true
      )
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

  //
  // ───────────────────────────────────────────────────────────────
  // PROMPT VERSIONS
  // ───────────────────────────────────────────────────────────────
  //

  @IsTest
  static void testSavePromptVersionPublishesAndBecomesActive() {
    Test.startTest();
    Id versionId = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'New prompt body',
      'a goal',
      'tightened the JSON rules',
      true,
      null
    );
    Test.stopTest();

    Agent_Prompt_Version__c saved = [
      SELECT Status__c, Is_Active__c, Version_Number__c, Change_Note__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
    ];
    System.assertEquals('Published', saved.Status__c);
    System.assertEquals(true, saved.Is_Active__c);
    System.assertEquals(1, saved.Version_Number__c);
    System.assertEquals('tightened the JSON rules', saved.Change_Note__c);
  }

  @IsTest
  static void testSavePromptVersionAsDraftDoesNotGoLive() {
    Id versionId = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'Draft body',
      null,
      null,
      false,
      null
    );

    Agent_Prompt_Version__c saved = [
      SELECT Status__c, Is_Active__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
    ];
    System.assertEquals('Draft', saved.Status__c);
    System.assertEquals(
      false,
      saved.Is_Active__c,
      'A draft must not become the live prompt'
    );
  }

  @IsTest
  static void testGetAgentsShowsTheActiveVersionNotTheBaseline() {
    AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'VERSIONED_BODY',
      null,
      null,
      true,
      null
    );

    Test.startTest();
    List<AgentBuilderController.AgentConfig> agents = AgentBuilderController.getAgents();
    Test.stopTest();

    for (AgentBuilderController.AgentConfig config : agents) {
      if (config.developerName != 'CRUD_Agent') {
        continue;
      }
      System.assertEquals(
        'VERSIONED_BODY',
        config.systemPrompt,
        'The builder should show the prompt that actually runs'
      );
      System.assertEquals(1, config.activePromptVersionNumber);
      System.assertNotEquals(
        'VERSIONED_BODY',
        config.baselineSystemPrompt,
        'The packaged baseline should still be reported separately'
      );
      return;
    }
    System.assert(false, 'CRUD_Agent was not returned by getAgents');
  }

  @IsTest
  static void testActivateAndRestorePromptVersion() {
    Id v1 = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'first',
      null,
      null,
      true,
      null
    );
    AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'second',
      null,
      null,
      true,
      null
    );

    Test.startTest();
    // Roll back to v1, then branch a new draft off it.
    AgentBuilderController.activatePromptVersion(v1);
    Id draftId = AgentBuilderController.restorePromptVersionAsDraft(v1);
    Test.stopTest();

    System.assertEquals(
      true,
      [SELECT Is_Active__c FROM Agent_Prompt_Version__c WHERE Id = :v1]
      .Is_Active__c,
      'Rollback should reactivate v1'
    );
    System.assertEquals(
      'first',
      [SELECT System_Prompt__c FROM Agent_Prompt_Version__c WHERE Id = :draftId]
      .System_Prompt__c,
      'The restored draft should carry v1 body'
    );
  }

  @IsTest
  static void testPublishPromptVersionTakesADraftLive() {
    Id draftId = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'staged body',
      null,
      null,
      false,
      null
    );

    Test.startTest();
    AgentBuilderController.publishPromptVersion(draftId);
    Test.stopTest();

    Agent_Prompt_Version__c published = [
      SELECT Status__c, Is_Active__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :draftId
    ];
    System.assertEquals('Published', published.Status__c);
    System.assertEquals(true, published.Is_Active__c);
  }

  @IsTest
  static void testGetPromptVersionsReturnsNewestFirst() {
    AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'first',
      null,
      null,
      true,
      null
    );
    AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'second',
      null,
      null,
      true,
      null
    );

    List<AgentBuilderController.PromptVersionInfo> versions = AgentBuilderController.getPromptVersions(
      'CRUD_Agent'
    );

    System.assertEquals(2, versions.size());
    System.assertEquals(
      2,
      versions[0].versionNumber,
      'Newest version should sort first'
    );
    System.assertEquals(true, versions[0].isActive);
    System.assertEquals(false, versions[1].isActive);
  }

  @IsTest
  static void testSaveAgentDoesNotOverwriteBaselineForExistingAgent() {
    AgentDeployService.AgentSaveRequest request = new AgentDeployService.AgentSaveRequest();
    request.developerName = 'CRUD_Agent';
    request.label = 'CRUD Agent';
    request.systemPrompt = 'SHOULD_BE_DROPPED';
    request.llmProvider = 'OpenAI_GPT4';
    request.memoryConfig = 'Default_Memory';
    request.maxSteps = 10;
    request.isActive = true;

    Test.startTest();
    AgentBuilderController.saveAgent(JSON.serialize(request));
    Test.stopTest();

    Metadata.CustomMetadata definition = (Metadata.CustomMetadata) AgentDeployService.lastDeployedContainer.getMetadata()[0];
    for (Metadata.CustomMetadataValue value : definition.values) {
      System.assertNotEquals(
        'aao__SystemPrompt__c',
        value.field,
        'An existing agent\'s prompt is owned by its versions; the config deploy must ' +
        'leave the packaged baseline alone'
      );
    }
  }

  @IsTest
  static void testNewAgentSeedsBothTheBaselineAndVersionOne() {
    AgentDeployService.AgentSaveRequest request = new AgentDeployService.AgentSaveRequest();
    request.developerName = 'Brand_New_Agent';
    request.label = 'Brand New Agent';
    request.systemPrompt = 'AS_CREATED_BODY';
    request.goal = 'do a thing';
    request.llmProvider = 'OpenAI_GPT4';
    request.memoryConfig = 'Default_Memory';
    request.maxSteps = 10;
    request.isActive = true;

    Test.startTest();
    AgentBuilderController.saveAgent(JSON.serialize(request));
    Test.stopTest();

    // The CMDT baseline is seeded, so a fresh org has a working packaged prompt...
    Metadata.CustomMetadata definition = (Metadata.CustomMetadata) AgentDeployService.lastDeployedContainer.getMetadata()[0];
    Boolean baselineWritten = false;
    for (Metadata.CustomMetadataValue value : definition.values) {
      if (value.field == 'aao__SystemPrompt__c') {
        baselineWritten = true;
        System.assertEquals('AS_CREATED_BODY', value.value);
      }
    }
    System.assert(
      baselineWritten,
      'A new agent should seed the packaged CMDT baseline'
    );

    // ...and v1 captures the same text, so history starts at creation rather than at the
    // first edit (which would otherwise lose the as-created wording entirely).
    List<Agent_Prompt_Version__c> versions = [
      SELECT
        Version_Number__c,
        Status__c,
        Is_Active__c,
        System_Prompt__c,
        Goal__c
      FROM Agent_Prompt_Version__c
      WHERE Agent__c = 'Brand_New_Agent'
    ];
    System.assertEquals(
      1,
      versions.size(),
      'Creating an agent should create v1'
    );
    System.assertEquals(1, versions[0].Version_Number__c);
    System.assertEquals('Published', versions[0].Status__c);
    System.assertEquals(true, versions[0].Is_Active__c);
    System.assertEquals('AS_CREATED_BODY', versions[0].System_Prompt__c);
    System.assertEquals('do a thing', versions[0].Goal__c);
  }

  @IsTest
  static void testSavingAnExistingAgentCreatesNoExtraVersion() {
    AgentDeployService.AgentSaveRequest request = new AgentDeployService.AgentSaveRequest();
    request.developerName = 'CRUD_Agent';
    request.label = 'CRUD Agent';
    request.systemPrompt = 'SHOULD_BE_IGNORED';
    request.llmProvider = 'OpenAI_GPT4';
    request.memoryConfig = 'Default_Memory';
    request.maxSteps = 10;
    request.isActive = true;

    Test.startTest();
    AgentBuilderController.saveAgent(JSON.serialize(request));
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Agent_Prompt_Version__c
        WHERE Agent__c = 'CRUD_Agent'
      ],
      'A config save on an existing agent must not mint a prompt version'
    );
  }

  @IsTest
  static void testUpdatePromptVersionEditsTheDraftRatherThanAddingOne() {
    Id draftId = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'first pass',
      null,
      null,
      false,
      null
    );

    Test.startTest();
    AgentBuilderController.updatePromptVersion(
      draftId,
      'second pass',
      null,
      'refined it'
    );
    Test.stopTest();

    System.assertEquals(
      'second pass',
      [
        SELECT System_Prompt__c
        FROM Agent_Prompt_Version__c
        WHERE Id = :draftId
      ]
      .System_Prompt__c
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Agent_Prompt_Version__c
        WHERE Agent__c = 'CRUD_Agent'
      ],
      'Editing a draft from the builder must not create a second version'
    );
  }

  @IsTest
  static void testUpdatePromptVersionSurfacesAFriendlyErrorForPublished() {
    Id publishedId = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'frozen',
      null,
      null,
      true,
      null
    );

    Boolean threw = false;
    try {
      AgentBuilderController.updatePromptVersion(
        publishedId,
        'tampered',
        null,
        null
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assert(
      threw,
      'The builder should refuse to edit a published version'
    );
  }

  @IsTest
  static void testTestRunOnVersionStampsTheChosenVersion() {
    Id v1 = AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'first',
      null,
      null,
      true,
      null
    );
    AgentBuilderController.savePromptVersion(
      'CRUD_Agent',
      'second',
      null,
      null,
      true,
      null
    );
    PromptVersionService.clearCache();

    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"Done"}}');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    Id runId = AgentBuilderController.testRunOnVersion(
      'CRUD_Agent',
      '{"task":"x"}',
      v1
    );
    Test.stopTest();

    System.assertEquals(
      v1,
      [
        SELECT aao__Prompt_Version__c
        FROM aao__Agent_Run__c
        WHERE Id = :runId
      ]
      .aao__Prompt_Version__c,
      'The test bench should run against the version the user picked'
    );
  }
}
