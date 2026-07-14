/**
 * @description Resolves an `LLM_Provider__mdt` record to the concrete `LLMClient`
 * implementation for its `Provider_Type__c`: `'OpenAI'` → `OpenAIClient`, `'Anthropic'` →
 * `AnthropicClient`, `'Azure'` → `AzureOpenAIClient` (chat completions), `'Responses'` →
 * `OpenAIResponsesClient` (Responses API, OpenAI or Azure).
 * Adding a new provider means adding a branch here plus a new `LLMClient` implementation.
 * During tests, `setMock` swaps in an `LLMClientMock` so tests never hit a real LLM.
 * @group LLM Integration
 */
public with sharing class LLMClientFactory {
  // Holds a mock instance for tests
  @TestVisible
  private static LLMClient mockClient;

  /**
   * @description Registers a mock `LLMClient` for `forProvider` to return while
   * `Test.isRunningTest()` is true. Call this before invoking agent code under test, then
   * queue canned responses with `LLMClientMock.addResponse`.
   * @param mock The mock client to use for the remainder of the test.
   */
  @TestVisible
  public static void setMock(LLMClient mock) {
    mockClient = mock;
  }

  /**
   * @description Loads the `LLM_Provider__mdt` record for `providerDeveloperName` and
   * returns the matching `LLMClient` implementation. Returns the registered mock instead
   * when running in a test context that has called `setMock`.
   * @param providerDeveloperName DeveloperName of the `LLM_Provider__mdt` record, typically `Agent_Definition__mdt.LLMProvider__c`.
   * @return A ready-to-use LLMClient for the resolved provider.
   * @throws AgentException if the provider's Provider_Type__c has no matching implementation.
   */
  public static LLMClient forProvider(String providerDeveloperName) {
    // If a mock is set, return it
    if (Test.isRunningTest() && mockClient != null) {
      return mockClient;
    }

    aao__LLM_Provider__mdt provider = [
      SELECT
        aao__Provider_Type__c,
        aao__Model_Name__c,
        aao__Named_Credential__c,
        aao__API_Endpoint__c,
        aao__MaxTokens__c,
        aao__Temperature__c
      FROM aao__LLM_Provider__mdt
      WHERE DeveloperName = :providerDeveloperName
      LIMIT 1
    ];

    if (provider.aao__Provider_Type__c == 'OpenAI') {
      return new OpenAIClient(provider);
    }
    if (provider.aao__Provider_Type__c == 'Anthropic') {
      return new AnthropicClient(provider);
    }
    if (provider.aao__Provider_Type__c == 'Azure') {
      return new AzureOpenAIClient(provider);
    }
    if (provider.aao__Provider_Type__c == 'Responses') {
      return new OpenAIResponsesClient(provider);
    }

    throw new AgentException(
      'Unsupported LLM provider: ' + provider.aao__Provider_Type__c
    );
  }
}
