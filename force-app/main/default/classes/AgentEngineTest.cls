@IsTest
private class AgentEngineTest {

    @IsTest
    static void testSimpleQueryThenFinal() {
        Test.startTest();

        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}');
        mock.addResponse('{"final":{"message":"Done"}}');

        LLMClientFactory.setMock(mock);

        Id runId = AgentEngine.runAgent('Test_Agent', '{"task":"Find accounts"}', 'Apex');

        Test.stopTest();

        aao__Agent_Run__c run = [
            SELECT aao__Status__c, aao__Final_Output__c
            FROM aao__Agent_Run__c
            WHERE Id = :runId
        ];

        System.assertEquals('Succeeded', run.aao__Status__c);
        System.assert(run.aao__Final_Output__c.contains('Done'));
    }

    @IsTest
    static void testToolChain() {
        Test.startTest();

        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}');
        mock.addResponse('{"tool":"DescribeObjectTool","args":{"object":"Account"}}');
        mock.addResponse('{"final":{"message":"All done"}}');

        LLMClientFactory.setMock(mock);

        Id runId = AgentEngine.runAgent('Test_Agent', '{"task":"Analyze accounts"}', 'Apex');

        Test.stopTest();

        aao__Agent_Run__c run = [
            SELECT aao__Status__c
            FROM aao__Agent_Run__c
            WHERE Id = :runId
        ];

        System.assertEquals('Succeeded', run.aao__Status__c);
    }

    @IsTest
    static void testRepeatedToolCallGuard() {
        Test.startTest();

        LLMClientMock mock = new LLMClientMock();
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}');
        mock.addResponse('{"tool":"QuerySalesforceTool","args":{"object":"Account"}}'); // repeat
        mock.addResponse('{"final":{"message":"Done"}}');

        LLMClientFactory.setMock(mock);

        Id runId = AgentEngine.runAgent('Test_Agent', '{"task":"Find accounts"}', 'Apex');

        Test.stopTest();

        aao__Agent_Run__c run = [
            SELECT aao__Status__c
            FROM aao__Agent_Run__c
            WHERE Id = :runId
        ];

        System.assertEquals('Succeeded', run.aao__Status__c);
    }
}
