/**
 * @description `@AuraEnabled` backend for the builder LWCs (`aaoAgentBuilder`,
 * `aaoToolCatalog`, `aaoTestBench`). Read-only over configuration — agents and tools
 * are Custom Metadata, which Apex cannot DML, so authoring stays in Setup/deploys.
 * The test bench persists sample inputs in `Test_Case__c` (ordinary records) and
 * starts real runs via `AgentEngine.runAgent` with trigger type `TestBench`.
 * @group UI
 */
public with sharing class AgentBuilderController {
  /**
   * @description All agent definitions (active and inactive) with their granted tools,
   * for the builder's agent list + detail pane.
   * @return One AgentConfig per Agent_Definition__mdt.
   */
  @AuraEnabled(cacheable=true)
  public static List<AgentConfig> getAgents() {
    List<AgentConfig> configs = new List<AgentConfig>();
    for (aao__Agent_Definition__mdt def : [
      SELECT
        DeveloperName,
        MasterLabel,
        aao__Goal__c,
        aao__SystemPrompt__c,
        aao__LLMProvider__c,
        aao__MaxSteps__c,
        aao__MemoryConfig__c,
        aao__IsActive__c
      FROM aao__Agent_Definition__mdt
      ORDER BY MasterLabel
    ]) {
      AgentConfig config = new AgentConfig();
      config.developerName = def.DeveloperName;
      config.label = def.MasterLabel;
      config.goal = def.aao__Goal__c;
      config.systemPrompt = def.aao__SystemPrompt__c;
      config.llmProvider = def.aao__LLMProvider__c;
      config.maxSteps = def.aao__MaxSteps__c == null
        ? null
        : Integer.valueOf(def.aao__MaxSteps__c);
      config.memoryConfig = def.aao__MemoryConfig__c;
      config.isActive = def.aao__IsActive__c == true;
      config.tools = new List<ToolInfo>();
      for (
        aao__Agent_Tool_Definition__mdt toolDef : ToolRegistry.getToolDefinitionsForAgent(
            def.DeveloperName
          )
          .values()
      ) {
        config.tools.add(toToolInfo(toolDef));
      }
      configs.add(config);
    }
    return configs;
  }

  /**
   * @description Every registered tool with its schemas and which agents may use it.
   * @return One ToolInfo per Agent_Tool_Definition__mdt.
   */
  @AuraEnabled(cacheable=true)
  public static List<ToolInfo> getToolCatalog() {
    Map<String, List<String>> grantsByTool = new Map<String, List<String>>();
    for (aao__Agent_Tool_Mapping__mdt mapping : [
      SELECT aao__Agent__c, aao__Tool__c
      FROM aao__Agent_Tool_Mapping__mdt
      WHERE aao__IsAllowed__c = TRUE
    ]) {
      if (!grantsByTool.containsKey(mapping.aao__Tool__c)) {
        grantsByTool.put(mapping.aao__Tool__c, new List<String>());
      }
      grantsByTool.get(mapping.aao__Tool__c).add(mapping.aao__Agent__c);
    }

    List<ToolInfo> catalog = new List<ToolInfo>();
    for (aao__Agent_Tool_Definition__mdt def : [
      SELECT
        DeveloperName,
        MasterLabel,
        aao__Tool_Class__c,
        aao__Description__c,
        aao__InputSchema__c,
        aao__OutputSchema__c,
        aao__PromptGuidance__c
      FROM aao__Agent_Tool_Definition__mdt
      ORDER BY MasterLabel
    ]) {
      ToolInfo info = toToolInfo(def);
      info.grantedAgents = grantsByTool.containsKey(def.DeveloperName)
        ? String.join(grantsByTool.get(def.DeveloperName), ', ')
        : '';
      catalog.add(info);
    }
    return catalog;
  }

  /**
   * @description Renders exactly what the LLM sees for an agent: the tool manifest
   * built by the engine itself (`AgentEngine.buildToolManifest`).
   * @param agentDeveloperName Agent to preview.
   * @return The manifest string included in the agent's system prompt.
   */
  @AuraEnabled
  public static String getManifestPreview(String agentDeveloperName) {
    return AgentEngine.buildToolManifest(
      ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName)
    );
  }

  /**
   * @description Saved sample inputs for one agent, for the test bench dropdown.
   * @param agentDeveloperName Agent to list test cases for.
   * @return TestCaseInfo rows, newest first.
   */
  @AuraEnabled
  public static List<TestCaseInfo> getTestCases(String agentDeveloperName) {
    List<TestCaseInfo> cases = new List<TestCaseInfo>();
    for (Test_Case__c tc : [
      SELECT Id, Name, Input_Json__c
      FROM Test_Case__c
      WHERE Agent__c = :agentDeveloperName
      ORDER BY CreatedDate DESC
      LIMIT 50
    ]) {
      TestCaseInfo info = new TestCaseInfo();
      info.testCaseId = tc.Id;
      info.name = tc.Name;
      info.inputJson = tc.Input_Json__c;
      cases.add(info);
    }
    return cases;
  }

  /**
   * @description Saves a sample input for reuse.
   * @param agentDeveloperName Agent the sample targets.
   * @param name Display name.
   * @param inputJson The input context JSON.
   * @return Id of the new Test_Case__c.
   */
  @AuraEnabled
  public static Id saveTestCase(
    String agentDeveloperName,
    String name,
    String inputJson
  ) {
    Test_Case__c tc = new Test_Case__c(
      Name = name,
      Agent__c = agentDeveloperName,
      Input_Json__c = inputJson
    );
    insert tc;
    return tc.Id;
  }

  /**
   * @description Starts a real run from the test bench.
   * @param agentDeveloperName Agent to run.
   * @param inputJson Input context JSON.
   * @return Id of the new Agent_Run__c.
   */
  @AuraEnabled
  public static Id testRun(String agentDeveloperName, String inputJson) {
    return AgentEngine.runAgent(agentDeveloperName, inputJson, 'TestBench');
  }

  private static ToolInfo toToolInfo(aao__Agent_Tool_Definition__mdt def) {
    ToolInfo info = new ToolInfo();
    info.developerName = def.DeveloperName;
    info.label = def.MasterLabel;
    info.toolClass = def.aao__Tool_Class__c;
    info.description = def.aao__Description__c;
    info.inputSchema = def.aao__InputSchema__c;
    info.outputSchema = def.aao__OutputSchema__c;
    info.promptGuidance = def.aao__PromptGuidance__c;
    return info;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // DTOs
  // ───────────────────────────────────────────────────────────────
  //

  /** @description One agent definition with granted tools. */
  public class AgentConfig {
    @AuraEnabled
    public String developerName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String goal;
    @AuraEnabled
    public String systemPrompt;
    @AuraEnabled
    public String llmProvider;
    @AuraEnabled
    public Integer maxSteps;
    @AuraEnabled
    public String memoryConfig;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public List<ToolInfo> tools;
  }

  /** @description One tool definition (catalog card / agent tool row). */
  public class ToolInfo {
    @AuraEnabled
    public String developerName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String toolClass;
    @AuraEnabled
    public String description;
    @AuraEnabled
    public String inputSchema;
    @AuraEnabled
    public String outputSchema;
    @AuraEnabled
    public String promptGuidance;
    @AuraEnabled
    public String grantedAgents;
  }

  /** @description One saved test-bench input. */
  public class TestCaseInfo {
    @AuraEnabled
    public Id testCaseId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String inputJson;
  }
}
