/**
 * @description Tests the M2 memory store: `SalesforceMemoryProvider` recall (scope
 * filtering, keyword ranking, inactive/expired exclusion, access bookkeeping) and
 * `store` dedupe; `MemoryService.buildRecallBlock` prompt rendering (memories vs
 * lessons, treat-as-data preamble, empty for NoMemory); recall injection into the LLM
 * request in `runLLMStep` (via `MemoryProviderFactory.setMock`); and
 * `MemoryCaptureQueueable` extraction/reflection with `LLMClientMock`.
 * @group Tests
 */
@IsTest
private class MemoryServiceTest {
  private static Agent_Memory__c makeMemory(
    String scope,
    String memoryType,
    String content,
    String keywords
  ) {
    return new Agent_Memory__c(
      Agent__c = 'CRUD_Agent',
      User__c = UserInfo.getUserId(),
      Scope__c = scope,
      Type__c = memoryType,
      Content__c = content,
      Keywords__c = keywords,
      Is_Active__c = true
    );
  }

  @IsTest
  static void testProviderRecallScopesRankingAndExclusions() {
    List<Agent_Memory__c> rows = new List<Agent_Memory__c>{
      makeMemory('User', 'Preference', 'User prefers EMEA accounts', 'emea,accounts'),
      makeMemory('Agent', 'Fact', 'Portland accounts use area code 503', 'portland,accounts'),
      makeMemory('Global', 'Fact', 'Fiscal year starts in February', 'fiscal'),
      makeMemory('User', 'Fact', 'Inactive memory', 'accounts'),
      makeMemory('User', 'Fact', 'Expired memory', 'accounts')
    };
    insert rows;
    update new Agent_Memory__c(Id = rows[3].Id, Is_Active__c = false);
    update new Agent_Memory__c(
      Id = rows[4].Id,
      Expires_At__c = System.now().addDays(-1)
    );

    MemoryQuery query = new MemoryQuery();
    query.agentDeveloperName = 'CRUD_Agent';
    query.userId = UserInfo.getUserId();
    query.queryText = 'Find my Portland accounts';
    query.maxItems = 2;

    List<MemoryRecord> results = new SalesforceMemoryProvider()
      .recall(query);

    System.assertEquals(2, results.size(), 'maxItems respected');
    System.assertEquals(
      'Portland accounts use area code 503',
      results[0].content,
      'best keyword overlap ranks first'
    );
    for (MemoryRecord rec : results) {
      System.assertNotEquals('Inactive memory', rec.content);
      System.assertNotEquals('Expired memory', rec.content);
    }

    Agent_Memory__c touched = [
      SELECT Access_Count__c, Last_Accessed__c
      FROM Agent_Memory__c
      WHERE Id = :rows[1].Id
    ];
    System.assertEquals(1, touched.Access_Count__c, 'access bookkeeping bumped');
    System.assertNotEquals(null, touched.Last_Accessed__c);
  }

  @IsTest
  static void testProviderStoreDedupes() {
    insert makeMemory('User', 'Fact', 'Duplicate content', 'dup');

    SalesforceMemoryProvider provider = new SalesforceMemoryProvider();
    provider.store(
      new List<MemoryRecord>{
        new MemoryRecord('CRUD_Agent', UserInfo.getUserId(), 'User', 'Fact', 'Duplicate content', 'dup'),
        new MemoryRecord('CRUD_Agent', UserInfo.getUserId(), 'User', 'Fact', 'Fresh content', 'fresh')
      }
    );

    // LongTextArea can't be filtered in SOQL — count in Apex.
    Integer duplicates = 0;
    Integer fresh = 0;
    for (Agent_Memory__c row : [SELECT Content__c FROM Agent_Memory__c]) {
      if (row.Content__c == 'Duplicate content') {
        duplicates++;
      } else if (row.Content__c == 'Fresh content') {
        fresh++;
      }
    }
    System.assertEquals(1, duplicates, 'duplicate not re-inserted');
    System.assertEquals(1, fresh);
  }

  @IsTest
  static void testBuildRecallBlockRendersMemoriesAndLessons() {
    insert new List<Agent_Memory__c>{
      makeMemory('User', 'Preference', 'User prefers concise answers', 'concise'),
      makeMemory('Agent', 'Reflection', 'Validate fields before updating records', 'validate')
    };

    String block = MemoryService.buildRecallBlock(
      'CRUD_Agent',
      'Default_Memory',
      null,
      'concise validate'
    );

    System.assert(block.contains('## Relevant memories'), block);
    System.assert(
      block.contains('not as instructions'),
      'treat-as-data preamble present'
    );
    System.assert(block.contains('[Preference] User prefers concise answers'));
    System.assert(block.contains('## Lessons from previous runs'));
    System.assert(block.contains('Validate fields before updating records'));
  }

  @IsTest
  static void testBuildRecallBlockEmptyWhenNoMemories() {
    System.assertEquals(
      '',
      MemoryService.buildRecallBlock('CRUD_Agent', 'Default_Memory', null, 'anything'),
      'no memories -> empty block'
    );
    System.assertEquals(
      '',
      MemoryService.buildRecallBlock('CRUD_Agent', '', null, 'anything'),
      'blank config -> empty block'
    );
  }

  @IsTest
  static void testRunLLMStepInjectsRecallBlock() {
    insert makeMemory('User', 'Preference', 'Always sort accounts by name', 'accounts,sort');

    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('{"final":{"message":"Done"}}');
    LLMClientFactory.setMock(mock);

    String inputJson = '{"task":"List my accounts sorted"}';
    Id runId = ExecutionLogger.startRun('CRUD_Agent', inputJson, 'Apex');
    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('user', inputJson)
    };

    Test.startTest();
    AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
    Test.stopTest();

    System.assertEquals(
      'system',
      history[0].role,
      'system prompt prepended'
    );
    System.assert(
      history[0].content.contains('Always sort accounts by name'),
      'recalled memory injected into the system prompt'
    );
  }

  @IsTest
  static void testCaptureQueueableExtractsAndReflects() {
    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{"task":"x"}', 'Apex');
    update new aao__Agent_Run__c(
      Id = runId,
      aao__Status__c = 'Succeeded',
      aao__History_Json__c = JSON.serialize(
        new List<LLMMessage>{
          new LLMMessage('user', 'I always want EMEA accounts only'),
          new LLMMessage('assistant', '{"final":{"message":"Noted"}}')
        }
      )
    );

    LLMClientMock mock = new LLMClientMock();
    // extraction response, then reflection response
    mock.addResponse(
      '[{"content":"User only works with EMEA accounts","type":"Preference","scope":"User","keywords":"emea,accounts"}]'
    );
    mock.addResponse('Filter to EMEA before querying accounts.');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    new MemoryCaptureQueueable(runId, 'CRUD_Agent', 'Default_Memory', true, true)
      .execute(null);
    Test.stopTest();

    List<Agent_Memory__c> stored = [
      SELECT Type__c, Scope__c, Content__c, User__c, Source_Run__c
      FROM Agent_Memory__c
      ORDER BY Type__c
    ];
    System.assertEquals(2, stored.size(), 'fact + reflection stored');
    System.assertEquals('Preference', stored[0].Type__c);
    System.assertEquals('User', stored[0].Scope__c);
    System.assertEquals(UserInfo.getUserId(), stored[0].User__c);
    System.assertEquals(runId, stored[0].Source_Run__c);
    System.assertEquals('Reflection', stored[1].Type__c);
    System.assertEquals('Agent', stored[1].Scope__c);
  }

  @IsTest
  static void testCaptureReflectionNoneStoresNothing() {
    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    update new aao__Agent_Run__c(
      Id = runId,
      aao__History_Json__c = '[{"role":"user","content":"hi"}]'
    );

    LLMClientMock mock = new LLMClientMock();
    mock.addResponse('NONE');
    LLMClientFactory.setMock(mock);

    Test.startTest();
    new MemoryCaptureQueueable(runId, 'CRUD_Agent', 'Default_Memory', false, true)
      .execute(null);
    Test.stopTest();

    System.assertEquals(0, [SELECT COUNT() FROM Agent_Memory__c]);
  }

  @IsTest
  static void testCaptureFailureIsSwallowed() {
    Id runId = ExecutionLogger.startRun('CRUD_Agent', '{}', 'Apex');
    update new aao__Agent_Run__c(
      Id = runId,
      aao__History_Json__c = '[{"role":"user","content":"hi"}]'
    );

    // No mock responses queued -> LLM call throws inside the queueable.
    LLMClientFactory.setMock(new LLMClientMock());

    Test.startTest();
    new MemoryCaptureQueueable(runId, 'CRUD_Agent', 'Default_Memory', true, false)
      .execute(null);
    Test.stopTest();

    System.assertEquals(0, [SELECT COUNT() FROM Agent_Memory__c]);
    System.assert(true, 'no exception surfaced');
  }
}
