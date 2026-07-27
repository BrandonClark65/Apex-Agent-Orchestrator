/**
 * @description `@AuraEnabled` backend for the builder LWCs (`aaoAgentBuilder`,
 * `aaoToolCatalog`, `aaoTestBench`). Agent and tool *configuration* is Custom Metadata, which
 * Apex cannot DML, so saving it goes through an async `AgentDeployService` metadata deploy.
 * System *prompts* are the exception: they live in `Agent_Prompt_Version__c` records, so
 * `savePromptVersion` and `activatePromptVersion` commit instantly with ordinary DML.
 * The test bench persists sample inputs in `Test_Case__c` and starts real runs via
 * `AgentEngine.runAgent` with trigger type `TestBench`.
 * @group UI
 */
public with sharing class AgentBuilderController {
  /**
   * @description All agent definitions (active and inactive) with their granted tools,
   * for the builder's agent list + detail pane. `systemPrompt` reflects the agent's active
   * `Agent_Prompt_Version__c` where one exists, falling back to the packaged
   * `Agent_Definition__mdt.SystemPrompt__c` baseline — so the builder always shows the prompt
   * that runs, not the shipped default.
   * @return One AgentConfig per Agent_Definition__mdt.
   */
  // Not cacheable: the builder re-fetches right after a metadata deploy lands.
  @AuraEnabled
  public static List<AgentConfig> getAgents() {
    // One query for every agent's active version rather than one per agent.
    Map<String, Agent_Prompt_Version__c> activeByAgent = new Map<String, Agent_Prompt_Version__c>();
    for (Agent_Prompt_Version__c version : [
      SELECT Id, Agent__c, Version_Number__c, System_Prompt__c
      FROM Agent_Prompt_Version__c
      WHERE Is_Active__c = TRUE
    ]) {
      activeByAgent.put(version.Agent__c, version);
    }

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
      Agent_Prompt_Version__c active = activeByAgent.get(def.DeveloperName);
      config.systemPrompt = active == null
        ? def.aao__SystemPrompt__c
        : active.System_Prompt__c;
      config.baselineSystemPrompt = def.aao__SystemPrompt__c;
      config.activePromptVersionId = active == null ? null : active.Id;
      config.activePromptVersionNumber = active == null ||
        active.Version_Number__c == null
        ? null
        : Integer.valueOf(active.Version_Number__c);
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
   * @description Deploys agent configuration changes (definition + tool grants) via the
   * Metadata API. Returns the deployment job id; completion arrives as an
   * `Agent_UI_Event__e` with `Event_Type__c = 'DeployFinished'` and that id in
   * `Run_Id__c`.
   * @param requestJson Serialized AgentDeployService.AgentSaveRequest from the edit form.
   * @return Deployment job Id as a string (null inside tests).
   */
  @AuraEnabled
  public static String saveAgent(String requestJson) {
    AgentDeployService.AgentSaveRequest request = (AgentDeployService.AgentSaveRequest) JSON.deserialize(
      requestJson,
      AgentDeployService.AgentSaveRequest.class
    );

    // Prompts are versioned records, not metadata. Only seed SystemPrompt__c into the CMDT
    // when the agent is brand new — that gives a fresh org a working packaged baseline. After
    // that the baseline is frozen and prompt edits go through savePromptVersion instead, so a
    // wording tweak doesn't cost a 90-second metadata deploy.
    Boolean isNew = isNewAgent(request.developerName);
    if (!isNew) {
      request.systemPrompt = null;
    }

    // Runs after deployAgent so a request that fails validation throws before we write
    // anything — an invalid agent should not leave a version record behind.
    Id jobId = AgentDeployService.deployAgent(request);

    if (isNew && String.isNotBlank(request.systemPrompt)) {
      seedFirstVersion(
        request.developerName,
        request.systemPrompt,
        request.goal
      );
    }

    return jobId == null ? null : String.valueOf(jobId);
  }

  /**
   * @description Captures a brand-new agent's starting prompt as v1 so its history begins at
   * creation. Without this the as-created wording would live only in the CMDT baseline: the
   * first edit would become v1 carrying the *new* text, leaving the original impossible to
   * diff against or roll back to.
   *
   * The config snapshot comes out null here, and that is honest — the agent's CMDT record and
   * tool grants are still mid-deploy, so there is no configuration to photograph yet.
   */
  private static void seedFirstVersion(
    String developerName,
    String systemPrompt,
    String goal
  ) {
    try {
      Agent_Prompt_Version__c first = PromptVersionService.createDraft(
        developerName,
        systemPrompt,
        goal,
        'Initial prompt, captured when the agent was created.',
        null
      );
      PromptVersionService.publish(first.Id);
    } catch (Exception e) {
      // The agent itself deployed fine; losing its v1 must not fail the save. The engine
      // falls back to the CMDT baseline, and the next prompt edit will create v1 instead.
      System.debug(
        LoggingLevel.ERROR,
        'Could not seed the first prompt version for ' +
          developerName +
          ': ' +
          e.getMessage()
      );
    }
  }

  private static Boolean isNewAgent(String developerName) {
    return [
        SELECT COUNT()
        FROM aao__Agent_Definition__mdt
        WHERE DeveloperName = :developerName
      ] == 0;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // PROMPT VERSIONS
  // ───────────────────────────────────────────────────────────────
  //

  /**
   * @description Version history for one agent, newest first, for the builder's versions panel.
   * @param agentDeveloperName Agent whose history to load.
   * @return Up to 50 versions ordered by version number descending.
   */
  @AuraEnabled
  public static List<PromptVersionInfo> getPromptVersions(
    String agentDeveloperName
  ) {
    List<PromptVersionInfo> results = new List<PromptVersionInfo>();
    for (Agent_Prompt_Version__c version : [
      SELECT
        Id,
        Name,
        Version_Number__c,
        Status__c,
        Is_Active__c,
        Change_Note__c,
        System_Prompt__c,
        Goal__c,
        Config_Snapshot_Json__c,
        Published_At__c,
        Source_Version__c,
        CreatedDate,
        CreatedBy.Name
      FROM Agent_Prompt_Version__c
      WHERE Agent__c = :agentDeveloperName
      ORDER BY Version_Number__c DESC
      LIMIT 50
    ]) {
      PromptVersionInfo info = new PromptVersionInfo();
      info.versionId = version.Id;
      info.name = version.Name;
      info.versionNumber = version.Version_Number__c == null
        ? null
        : Integer.valueOf(version.Version_Number__c);
      info.status = version.Status__c;
      info.isActive = version.Is_Active__c == true;
      info.changeNote = version.Change_Note__c;
      info.systemPrompt = version.System_Prompt__c;
      info.goal = version.Goal__c;
      info.configSnapshotJson = version.Config_Snapshot_Json__c;
      info.publishedAt = version.Published_At__c;
      info.sourceVersionId = version.Source_Version__c;
      info.createdDate = version.CreatedDate;
      info.createdByName = version.CreatedBy == null
        ? null
        : version.CreatedBy.Name;
      results.add(info);
    }
    return results;
  }

  /**
   * @description Saves the edited prompt as a new version. Publishing also makes it the
   * version new runs use — instantly, with no metadata deploy.
   * @param agentDeveloperName Agent this version belongs to.
   * @param systemPrompt The prompt body.
   * @param goal Snapshot of the agent's goal.
   * @param changeNote Short explanation of what changed and why.
   * @param publishNow True to freeze and activate immediately; false to leave it as an editable draft.
   * @param sourceVersionId Version this was based on, or null.
   * @return Id of the new Agent_Prompt_Version__c.
   */
  @AuraEnabled
  public static Id savePromptVersion(
    String agentDeveloperName,
    String systemPrompt,
    String goal,
    String changeNote,
    Boolean publishNow,
    Id sourceVersionId
  ) {
    try {
      Agent_Prompt_Version__c version = PromptVersionService.createDraft(
        agentDeveloperName,
        systemPrompt,
        goal,
        changeNote,
        sourceVersionId
      );
      if (publishNow == true) {
        PromptVersionService.publish(version.Id);
      }
      return version.Id;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * @description Freezes an existing draft and makes it the live version. Without this a draft
   * saved for later would have no way to go live — `activatePromptVersion` rejects drafts.
   * @param versionId Draft to publish.
   */
  @AuraEnabled
  public static void publishPromptVersion(Id versionId) {
    try {
      PromptVersionService.publish(versionId);
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * @description Makes an existing published version the active one — the rollback action.
   * @param versionId Version to activate.
   */
  @AuraEnabled
  public static void activatePromptVersion(Id versionId) {
    try {
      PromptVersionService.activate(versionId);
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * @description Copies an earlier version into a new editable draft.
   * @param versionId Version to copy.
   * @return Id of the new draft.
   */
  @AuraEnabled
  public static Id restorePromptVersionAsDraft(Id versionId) {
    try {
      return PromptVersionService.restoreAsDraft(versionId).Id;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * @description LLM provider options for the edit form.
   * @return DeveloperNames of all LLM_Provider__mdt records.
   */
  @AuraEnabled(cacheable=true)
  public static List<String> getProviderOptions() {
    List<String> names = new List<String>();
    for (aao__LLM_Provider__mdt provider : [
      SELECT DeveloperName
      FROM aao__LLM_Provider__mdt
      ORDER BY DeveloperName
    ]) {
      names.add(provider.DeveloperName);
    }
    return names;
  }

  /**
   * @description Memory config options for the edit form.
   * @return DeveloperNames of all Memory_Config__mdt records.
   */
  @AuraEnabled(cacheable=true)
  public static List<String> getMemoryConfigOptions() {
    List<String> names = new List<String>();
    for (aao__Memory_Config__mdt config : [
      SELECT DeveloperName
      FROM aao__Memory_Config__mdt
      ORDER BY DeveloperName
    ]) {
      names.add(config.DeveloperName);
    }
    return names;
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

  /**
   * @description Starts a test-bench run against a specific prompt version rather than the
   * active one, so the same saved input can be replayed across two versions and compared.
   * A separate method name rather than an overload of `testRun` — Salesforce rejects two
   * `@AuraEnabled` methods sharing a name.
   * @param agentDeveloperName Agent to run.
   * @param inputJson Input context JSON.
   * @param promptVersionId Version to run against; null falls back to the active version.
   * @return Id of the new Agent_Run__c.
   */
  @AuraEnabled
  public static Id testRunOnVersion(
    String agentDeveloperName,
    String inputJson,
    Id promptVersionId
  ) {
    return AgentEngine.runAgent(
      agentDeveloperName,
      inputJson,
      'TestBench',
      promptVersionId
    );
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
    /** @description The packaged CMDT baseline, shown when it differs from the active version. */
    @AuraEnabled
    public String baselineSystemPrompt;
    @AuraEnabled
    public Id activePromptVersionId;
    @AuraEnabled
    public Integer activePromptVersionNumber;
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

  /** @description One revision of an agent's system prompt. */
  public class PromptVersionInfo {
    @AuraEnabled
    public Id versionId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Integer versionNumber;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public String changeNote;
    @AuraEnabled
    public String systemPrompt;
    @AuraEnabled
    public String goal;
    @AuraEnabled
    public String configSnapshotJson;
    @AuraEnabled
    public Datetime publishedAt;
    @AuraEnabled
    public Id sourceVersionId;
    @AuraEnabled
    public Datetime createdDate;
    @AuraEnabled
    public String createdByName;
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
