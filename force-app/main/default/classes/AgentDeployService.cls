/**
 * @description Deploys agent configuration changes from the builder UI. Agents and tool
 * grants are Custom Metadata, which Apex cannot DML — but `Metadata.Operations`
 * CAN deploy CMDT *records*, so this service builds `Metadata.CustomMetadata` for the
 * `Agent_Definition` record plus one `Agent_Tool_Mapping` record per tool grant and
 * enqueues them as a single deployment. `AgentDeployCallback` reports completion by
 * publishing an `Agent_UI_Event__e` (`Event_Type__c = 'DeployFinished'`, keyed by the
 * deployment job id) that `aaoAgentBuilder` subscribes to.
 *
 * Metadata deployments cannot execute inside Apex tests — `enqueue` is bypassed there
 * (`@TestVisible lastDeployedContainer` captures what would have shipped).
 * @group UI
 */
public with sharing class AgentDeployService {
  @TestVisible
  private static Metadata.DeployContainer lastDeployedContainer;

  /** @description One tool grant row in a save request. */
  public class ToolGrant {
    public String toolDeveloperName;
    public Boolean allowed;
  }

  /** @description Everything the builder edit form submits. */
  public class AgentSaveRequest {
    public String developerName;
    public String label;
    public String goal;
    public String systemPrompt;
    public String llmProvider;
    public Integer maxSteps;
    public String memoryConfig;
    public Boolean isActive;
    public List<ToolGrant> tools;
  }

  /**
   * @description Builds and enqueues the metadata deployment for one agent (definition +
   * tool mappings). Creates the records when they don't exist and updates them when they
   * do — CMDT deploys are upserts by fullName.
   * @param request Parsed save request from the builder.
   * @return The deployment job Id (matches the `Run_Id__c` on the completion event), or null in tests.
   */
  public static Id deployAgent(AgentSaveRequest request) {
    validate(request);

    Metadata.DeployContainer container = new Metadata.DeployContainer();
    container.addMetadata(buildAgentDefinition(request));
    for (ToolGrant grant : request.tools == null
      ? new List<ToolGrant>()
      : request.tools) {
      container.addMetadata(buildToolMapping(request.developerName, grant));
    }

    lastDeployedContainer = container;
    if (Test.isRunningTest()) {
      return null; // Metadata deployments cannot run inside tests
    }
    return Metadata.Operations.enqueueDeployment(
      container,
      new AgentDeployCallback()
    );
  }

  private static void validate(AgentSaveRequest request) {
    if (
      request == null ||
      String.isBlank(request.developerName) ||
      String.isBlank(request.label)
    ) {
      throw new AuraHandledException(
        'developerName and label are required to deploy an agent.'
      );
    }
    if (!Pattern.matches('[a-zA-Z][a-zA-Z0-9_]*', request.developerName)) {
      throw new AuraHandledException(
        'developerName must be a valid API name (letters, numbers, underscores).'
      );
    }
  }

  private static Metadata.CustomMetadata buildAgentDefinition(
    AgentSaveRequest request
  ) {
    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'Agent_Definition.' + request.developerName;
    record.label = request.label;
    record.values.add(value('Goal__c', request.goal));
    record.values.add(value('SystemPrompt__c', request.systemPrompt));
    record.values.add(value('LLMProvider__c', request.llmProvider));
    record.values.add(
      value(
        'MaxSteps__c',
        request.maxSteps == null ? 10 : (Object) request.maxSteps
      )
    );
    record.values.add(value('MemoryConfig__c', request.memoryConfig));
    record.values.add(value('IsActive__c', request.isActive == true));
    return record;
  }

  private static Metadata.CustomMetadata buildToolMapping(
    String agentDeveloperName,
    ToolGrant grant
  ) {
    String mappingName =
      agentDeveloperName +
      '_' +
      grant.toolDeveloperName;
    // CMDT DeveloperNames cap at 40 chars; keep deterministic by truncation.
    if (mappingName.length() > 40) {
      mappingName = mappingName.substring(0, 40);
    }

    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'Agent_Tool_Mapping.' + mappingName;
    record.label = mappingName.replace('_', ' ');
    record.values.add(value('Agent__c', agentDeveloperName));
    record.values.add(value('Tool__c', grant.toolDeveloperName));
    record.values.add(value('IsAllowed__c', grant.allowed == true));
    return record;
  }

  private static Metadata.CustomMetadataValue value(
    String field,
    Object fieldValue
  ) {
    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = field;
    v.value = fieldValue;
    return v;
  }
}
