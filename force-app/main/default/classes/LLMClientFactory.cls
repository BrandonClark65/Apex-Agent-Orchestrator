public with sharing class LLMClientFactory {

    // Holds a mock instance for tests
    @TestVisible
    private static LLMClient mockClient;

    // Allow tests to inject a mock
    @TestVisible
    public static void setMock(LLMClient mock) {
        mockClient = mock;
    }

    public static LLMClient forProvider(String providerDeveloperName) {

        // If a mock is set, return it
        if (Test.isRunningTest() && mockClient != null) {
            return mockClient;
        }

        aao__LLM_Provider__mdt provider = [
            SELECT aao__Provider_Type__c, aao__Model_Name__c, 
                   aao__Named_Credential__c, aao__API_Endpoint__c,
                   aao__MaxTokens__c, aao__Temperature__c
            FROM aao__LLM_Provider__mdt
            WHERE DeveloperName = :providerDeveloperName
            LIMIT 1
        ];

        if (provider.aao__Provider_Type__c == 'OpenAI') {
            return new OpenAIClient(provider);
        }

        throw new AgentException('Unsupported LLM provider: ' + provider.aao__Provider_Type__c);
    }
}