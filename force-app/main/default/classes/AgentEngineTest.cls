@IsTest
private class AgentEngineTest {

    // AgentEngine's steps hop through a Queueable -> Platform Event -> Trigger -> Queueable
    // chain so each callout/DML stays in its own transaction. Apex tests only auto-flush the
    // first Queueable hop (Test.stopTest doesn't redeliver platform events published during
    // that flush), so these tests drive runLLMStep/runToolStep directly in the same sequence
    // the trigger would, rather than relying on the event bus inside a test context.

    private static Id startRun(String inputJson, List<LLMMessage> history) {
        Id runId = ExecutionLogger.startRun('CRUD_Agent', inputJson, 'Apex');
        history.add(new LLMMessage('user', inputJson));
        return runId;
    }

    private static aao__Agent_Run__c getRun(Id runId) {
        return [
            SELECT aao__Status__c, aao__Final_Output__c, aao__Error_Message__c
            FROM aao__Agent_Run__c
            WHERE Id = :runId
        ];
    }

    private static List<aao__Agent_Step__c> getSteps(Id runId) {
        return [
            SELECT aao__Step_Type__c, aao__Status__c, aao__Tool__c
            FROM aao__Agent_Step__c
            WHERE aao__Agent_Run__c = :runId
            ORDER BY aao__Step_Number__c ASC
        ];
    }

    @IsTest
    static void testSimpleQueryThenFinal() {
        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}');
        mock.addResponse('{"final":{"message":"Done"}}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Find accounts"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, history, 'QuerySalesforceTool',
            new Map<String, Object>{ 'object' => 'Account' });
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        Test.stopTest();

        aao__Agent_Run__c run = getRun(runId);
        System.assertEquals('Succeeded', run.aao__Status__c);
        System.assert(run.aao__Final_Output__c.contains('Done'));
    }

    @IsTest
    static void testToolChain() {
        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}');
        mock.addResponse('{"tool":"DescribeObjectTool","args":{"object":"Account"}}');
        mock.addResponse('{"final":{"message":"All done"}}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Analyze accounts"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, history, 'QuerySalesforceTool',
            new Map<String, Object>{ 'object' => 'Account' });
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, history, 'DescribeObjectTool',
            new Map<String, Object>{ 'object' => 'Account' });
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        Test.stopTest();

        System.assertEquals('Succeeded', getRun(runId).aao__Status__c);
    }

    @IsTest
    static void testRecoversFromInvalidLLMResponse() {
        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"notARecognizedKey":true}'); // neither "tool" nor "final" -> retryable error
        mock.addResponse('{"final":{"message":"Recovered"}}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Find accounts"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history); // fails, retries
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history); // recovers
        Test.stopTest();

        aao__Agent_Run__c run = getRun(runId);
        System.assertEquals('Succeeded', run.aao__Status__c);
        System.assert(run.aao__Final_Output__c.contains('Recovered'));

        List<aao__Agent_Step__c> steps = getSteps(runId);
        System.assertEquals(2, steps.size());
        System.assertEquals('Failed', steps[0].aao__Status__c);
        System.assertEquals('Completed', steps[1].aao__Status__c);
    }

    @IsTest
    static void testHardFailsAfterMaxConsecutiveErrors() {
        LLMClientMock mock = new LLMClientMock();
        // AgentEngine caps consecutive failures at 3; never give it a valid response.
        mock.addResponse('{"notARecognizedKey":true}');
        mock.addResponse('{"notARecognizedKey":true}');
        mock.addResponse('{"notARecognizedKey":true}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Find accounts"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history); // 1st failure, retries
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history); // 2nd failure, retries
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history); // 3rd failure, hard-fails
        Test.stopTest();

        aao__Agent_Run__c run = getRun(runId);
        System.assertEquals('Failed', run.aao__Status__c);

        List<aao__Agent_Step__c> steps = getSteps(runId);
        System.assertEquals(3, steps.size());
        for (aao__Agent_Step__c step : steps) {
            System.assertEquals('Failed', step.aao__Status__c);
        }
    }

    @IsTest
    static void testRepeatedToolCallGuard() {
        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}');
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}'); // repeat
        mock.addResponse('{"final":{"message":"Done"}}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Find accounts"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, history, 'QuerySalesforceTool',
            new Map<String, Object>{ 'object' => 'Account' });
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history); // detects repeat, forces final next
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);
        Test.stopTest();

        System.assertEquals('Succeeded', getRun(runId).aao__Status__c);
    }

    @IsTest
    static void testParallelToolExecution() {
        LLMClientMock mock = new LLMClientMock();
        // LLM returns two tools to run in parallel
        mock.addResponse('{"tools":[{"tool":"QuerySalesforceTool","args":{"object":"Account"}},{"tool":"DescribeObjectTool","args":{"object":"Account"}}]}');
        mock.addResponse('{"final":{"message":"Done with parallel"}}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Analyze accounts in parallel"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        // LLM responds with parallel tool calls — sets PendingToolCount__c = 2 on the run
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);

        // Both tools execute. In real execution these run concurrently via separate Queueables.
        // Pass an empty history list — parallel mode reads/writes History_Json__c directly.
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, new List<LLMMessage>(), 'QuerySalesforceTool',
            new Map<String, Object>{ 'object' => 'Account' });
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, new List<LLMMessage>(), 'DescribeObjectTool',
            new Map<String, Object>{ 'object' => 'Account' });

        // The second tool was the last (PendingToolCount__c reached 0), so it published the
        // next LLM event. Read the merged history from the run record and simulate that hop.
        aao__Agent_Run__c runRecord = [SELECT History_Json__c FROM aao__Agent_Run__c WHERE Id = :runId];
        List<LLMMessage> mergedHistory = (List<LLMMessage>)JSON.deserialize(
            runRecord.History_Json__c, List<LLMMessage>.class
        );
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, mergedHistory);
        Test.stopTest();

        aao__Agent_Run__c run = getRun(runId);
        System.assertEquals('Succeeded', run.aao__Status__c);
        System.assert(run.aao__Final_Output__c.contains('Done with parallel'), 'Expected final output');

        List<aao__Agent_Step__c> steps = getSteps(runId);
        // 1 LLM (parallel request) + 2 tool calls + 1 LLM (final)
        System.assertEquals(4, steps.size());
        System.assertEquals('LLMCall', steps[0].aao__Step_Type__c);
        System.assertEquals('ToolCall', steps[1].aao__Step_Type__c);
        System.assertEquals('ToolCall', steps[2].aao__Step_Type__c);
        System.assertEquals('LLMCall', steps[3].aao__Step_Type__c);

        // PendingToolCount__c resets to 0 after the batch
        aao__Agent_Run__c finalRun = [SELECT PendingToolCount__c FROM aao__Agent_Run__c WHERE Id = :runId];
        System.assertEquals(0, Integer.valueOf(finalRun.PendingToolCount__c));
    }

    @IsTest
    static void testParallelToolOneFailsLLMStillFinalizes() {
        LLMClientMock mock = new LLMClientMock();
        // LLM requests a valid tool and an invalid one in parallel
        mock.addResponse('{"tools":[{"tool":"QuerySalesforceTool","args":{"object":"Account"}},{"tool":"QuerySalesforceTool","args":{"object":"BadObject__INVALID"}}]}');
        mock.addResponse('{"final":{"message":"Handled partial failure"}}');
        LLMClientFactory.setMock(mock);

        String inputJson = '{"task":"Query two objects in parallel"}';
        List<LLMMessage> history = new List<LLMMessage>();
        Id runId = startRun(inputJson, history);

        Test.startTest();
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, history);

        // Both tools run regardless of individual success/failure
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, new List<LLMMessage>(), 'QuerySalesforceTool',
            new Map<String, Object>{ 'object' => 'Account' });
        AgentEngine.runToolStep('CRUD_Agent', 'Apex', runId, new List<LLMMessage>(), 'QuerySalesforceTool',
            new Map<String, Object>{ 'object' => 'BadObject__INVALID' });

        aao__Agent_Run__c runRecord = [SELECT History_Json__c FROM aao__Agent_Run__c WHERE Id = :runId];
        List<LLMMessage> mergedHistory = (List<LLMMessage>)JSON.deserialize(
            runRecord.History_Json__c, List<LLMMessage>.class
        );
        AgentEngine.runLLMStep('CRUD_Agent', inputJson, 'Apex', runId, mergedHistory);
        Test.stopTest();

        // LLM saw both outputs (one success, one SOQL error) and chose to finalize
        System.assertEquals('Succeeded', getRun(runId).aao__Status__c);
        System.assertEquals(0, Integer.valueOf(
            [SELECT PendingToolCount__c FROM aao__Agent_Run__c WHERE Id = :runId].PendingToolCount__c
        ));
    }
}
