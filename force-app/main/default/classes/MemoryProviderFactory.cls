/**
 * @description Resolves the `MemoryProvider` for a memory config (mirrors
 * `LLMClientFactory`): reads `Memory_Config__mdt.Memory_Type__c` and returns the
 * matching implementation. `SalesforceOnly` (and, until vector support ships, `Hybrid`
 * and `VectorDB`) resolve to `SalesforceMemoryProvider`. Tests swap in a mock via
 * `setMock`.
 * @group Memory
 */
public with sharing class MemoryProviderFactory {
  @TestVisible
  private static MemoryProvider mockProvider;

  /**
   * @description Returns the provider configured for the given memory config.
   * @param memoryConfigDeveloperName DeveloperName of the Memory_Config__mdt record.
   * @return MemoryProvider implementation.
   */
  public static MemoryProvider forConfig(String memoryConfigDeveloperName) {
    if (Test.isRunningTest() && mockProvider != null) {
      return mockProvider;
    }
    // Hybrid/VectorDB fall back to Salesforce recall until the vector provider ships;
    // the seam exists so that lands without engine changes.
    return new SalesforceMemoryProvider();
  }

  /**
   * @description Registers a mock provider returned by every `forConfig` call while a
   * test is running.
   * @param mock The mock MemoryProvider.
   */
  @TestVisible
  private static void setMock(MemoryProvider mock) {
    mockProvider = mock;
  }
}
