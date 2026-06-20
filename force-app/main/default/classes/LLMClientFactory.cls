public with sharing class LLMClientFactory {

    public static LLMClient forProvider(String providerDeveloperName) {
        aao__LLM_Provider__mdt provider = [
            SELECT aao__Provider_Type__c, aao__Model_Name__c, 
                   aao__Named_Credential__c, aao__API_Endpoint__c, aao__MaxTokens__c, aao__Temperature__c
            FROM aao__LLM_Provider__mdt
            WHERE DeveloperName = :providerDeveloperName
            LIMIT 1
        ];

        if (provider.aao__Provider_Type__c == 'OpenAI') {
            return new OpenAIClient(provider);
        }

        throw new AuraHandledException('Unsupported LLM provider: ' + provider.aao__Provider_Type__c);
    }
}