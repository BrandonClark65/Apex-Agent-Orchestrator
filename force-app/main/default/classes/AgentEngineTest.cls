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
}
