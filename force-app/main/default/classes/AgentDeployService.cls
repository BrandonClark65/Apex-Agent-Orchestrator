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
  /** CMDT DeveloperName and MasterLabel both cap at 40 characters. */
  private static final Integer MAX_NAME_LENGTH = 40;
  private static final Integer HASH_LENGTH = 8;

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

    // The builder submits every tool in the catalog, granted or not. A revoked tool
    // still has to ship as IsAllowed__c = false so an existing grant gets flipped —
    // `Metadata.Operations` upserts and can never delete. But a tool that was never
    // granted has no record to flip, and to `ToolRegistry` "absent" and "false" mean
    // the same thing, so writing one would just litter Setup with dead rows.
    Set<String> alreadyMapped = mappedToolNames(request.developerName);
    // A container may not carry the same fullName twice — drop repeats in case the
    // builder submits the same tool more than once.
    Set<String> seenNames = new Set<String>();
    for (
      ToolGrant grant : request.tools == null
        ? new List<ToolGrant>()
        : request.tools
    ) {
      if (
        grant.allowed != true &&
        !alreadyMapped.contains(grant.toolDeveloperName)
      ) {
        continue;
      }
      Metadata.CustomMetadata mapping = buildToolMapping(
        request.developerName,
        grant
      );
      if (seenNames.add(mapping.fullName)) {
        container.addMetadata(mapping);
      }
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

  /**
   * @description Tool DeveloperNames that already have an `Agent_Tool_Mapping` record for
   * this agent, whatever their IsAllowed__c value — these are the grants a save can still
   * need to flip to false. Empty for an agent being created.
   */
  private static Set<String> mappedToolNames(String agentDeveloperName) {
    Set<String> toolNames = new Set<String>();
    for (aao__Agent_Tool_Mapping__mdt mapping : [
      SELECT aao__Tool__c
      FROM aao__Agent_Tool_Mapping__mdt
      WHERE aao__Agent__c = :agentDeveloperName
    ]) {
      toolNames.add(mapping.aao__Tool__c);
    }
    return toolNames;
  }

  private static Metadata.CustomMetadata buildAgentDefinition(
    AgentSaveRequest request
  ) {
    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'aao__Agent_Definition.' + request.developerName;
    record.label = request.label;
    record.values.add(value('aao__Goal__c', request.goal));
    record.values.add(value('aao__SystemPrompt__c', request.systemPrompt));
    record.values.add(value('aao__LLMProvider__c', request.llmProvider));
    record.values.add(
      value(
        'aao__MaxSteps__c',
        request.maxSteps == null ? 10 : (Object) request.maxSteps
      )
    );
    record.values.add(value('aao__MemoryConfig__c', request.memoryConfig));
    record.values.add(value('aao__IsActive__c', request.isActive == true));
    return record;
  }

  private static Metadata.CustomMetadata buildToolMapping(
    String agentDeveloperName,
    ToolGrant grant
  ) {
    String rawName = agentDeveloperName + '_' + grant.toolDeveloperName;

    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'aao__Agent_Tool_Mapping.' + mappingName(rawName);
    record.label = truncate(rawName.replace('_', ' '), MAX_NAME_LENGTH);
    record.values.add(value('aao__Agent__c', agentDeveloperName));
    record.values.add(value('aao__Tool__c', grant.toolDeveloperName));
    record.values.add(value('aao__IsAllowed__c', grant.allowed == true));
    return record;
  }

  /**
   * @description Fits an `agent_tool` pair into the 40-char CMDT DeveloperName limit.
   * Plain truncation is not safe here: a long agent name leaves so few characters for
   * the tool that every tool sharing that prefix collapses onto one fullName, and the
   * builder submits a mapping for every tool in the catalog — so the deployment fails
   * with "duplicate fullName". Over-long names therefore keep a truncated prefix plus a
   * hash of the full pair, which stays deterministic per agent/tool and unique across them.
   */
  @TestVisible
  private static String mappingName(String rawName) {
    if (rawName.length() <= MAX_NAME_LENGTH) {
      return rawName;
    }
    Blob digest = Crypto.generateDigest('MD5', Blob.valueOf(rawName));
    String suffix = EncodingUtil.convertToHex(digest).substring(0, HASH_LENGTH);
    String prefix = rawName.substring(0, MAX_NAME_LENGTH - HASH_LENGTH - 1);
    // DeveloperNames may not contain consecutive underscores or end in one.
    while (prefix.endsWith('_')) {
      prefix = prefix.substring(0, prefix.length() - 1);
    }
    return prefix + '_' + suffix;
  }

  private static String truncate(String input, Integer maxLength) {
    return input != null &&
      input.length() > maxLength
      ? input.substring(0, maxLength)
      : input;
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
