/**
 * @description Resolves which tools an agent may use and instantiates them, based on
 * `Agent_Tool_Mapping__mdt` (agent-to-tool grants) and `Agent_Tool_Definition__mdt`
 * (tool-to-Apex-class mapping plus the schema shown to the LLM). Adding a new tool requires
 * no changes here — only a new `Agent_Tool_Definition__mdt` record pointing at the new
 * `AgentTool` class and `Agent_Tool_Mapping__mdt` record(s) granting agents access.
 * @group Agent Tools
 */
public with sharing class ToolRegistry {
  /**
   * @description Instantiates a tool from its fully-qualified Apex class name via
   * `Type.forName`. The class must be public and have a no-argument constructor.
   * @param className Value of `Agent_Tool_Definition__mdt.Tool_Class__c`.
   * @return A new instance of the tool.
   * @throws AgentException if the class name cannot be resolved to an Apex type.
   */
  public static AgentTool getToolByClassName(String className) {
    Type t = Type.forName(className);
    if (t == null) {
      throw new AgentException('Tool class not found: ' + className);
    }
    return (AgentTool) t.newInstance();
  }
  /**
   * @description Returns instantiated `AgentTool` instances for every tool granted to the
   * given agent via `Agent_Tool_Mapping__mdt.IsAllowed__c`.
   * @param agentDeveloperName DeveloperName of the agent to resolve tools for.
   * @return List of instantiated tools; empty if no mappings exist.
   * @throws AgentException if a mapped tool has no matching Agent_Tool_Definition__mdt record.
   */
  public static List<AgentTool> getToolsForAgent(String agentDeveloperName) {
    List<AgentTool> tools = new List<AgentTool>();

    // Step 1: Query mappings by Agent DeveloperName (now a text field)
    List<aao__Agent_Tool_Mapping__mdt> mappings = [
      SELECT aao__Tool__c
      FROM aao__Agent_Tool_Mapping__mdt
      WHERE aao__Agent__c = :agentDeveloperName AND aao__IsAllowed__c = TRUE
    ];

    if (mappings.isEmpty()) {
      return tools;
    }

    // Step 2: Collect tool DeveloperNames
    Set<String> toolDeveloperNames = new Set<String>();
    for (aao__Agent_Tool_Mapping__mdt m : mappings) {
      toolDeveloperNames.add(m.aao__Tool__c);
    }

    // Step 3: Query Tool Definition CMDT by DeveloperName
    Map<String, aao__Agent_Tool_Definition__mdt> toolDefs = new Map<String, aao__Agent_Tool_Definition__mdt>(
      [
        SELECT DeveloperName, aao__Tool_Class__c
        FROM aao__Agent_Tool_Definition__mdt
        WHERE DeveloperName IN :toolDeveloperNames
      ]
    );

    // Step 4: Instantiate tool classes
    for (String devName : toolDeveloperNames) {
      aao__Agent_Tool_Definition__mdt def = toolDefs.get(devName);
      if (def == null) {
        throw new AgentException('Tool definition not found for: ' + devName);
      }
      tools.add(getToolByClassName(def.aao__Tool_Class__c));
    }

    return tools;
  }
  /**
   * @description Returns the `Agent_Tool_Definition__mdt` records (including description
   * and input/output schema) for every tool granted to the given agent, keyed by
   * DeveloperName. Used by `AgentEngine.buildToolManifest` to build the tool list shown to
   * the LLM — unlike `getToolsForAgent`, this does not instantiate any Apex classes.
   * @param agentDeveloperName DeveloperName of the agent to resolve tool definitions for.
   * @return Map of tool DeveloperName to its Agent_Tool_Definition__mdt record; empty if no mappings exist.
   */
  public static Map<String, aao__Agent_Tool_Definition__mdt> getToolDefinitionsForAgent(
    String agentDeveloperName
  ) {
    // Step 1: Query mappings
    List<aao__Agent_Tool_Mapping__mdt> mappings = [
      SELECT aao__Tool__c
      FROM aao__Agent_Tool_Mapping__mdt
      WHERE aao__Agent__c = :agentDeveloperName AND aao__IsAllowed__c = TRUE
    ];

    if (mappings.isEmpty()) {
      return new Map<String, aao__Agent_Tool_Definition__mdt>();
    }

    // Step 2: Collect DeveloperNames
    Set<String> toolDeveloperNames = new Set<String>();
    for (aao__Agent_Tool_Mapping__mdt m : mappings) {
      toolDeveloperNames.add(m.aao__Tool__c);
    }

    // Step 3: Query CMDT definitions
    List<aao__Agent_Tool_Definition__mdt> defs = [
      SELECT
        DeveloperName,
        aao__Tool_Class__c,
        aao__Description__c,
        aao__InputSchema__c,
        aao__OutputSchema__c,
        aao__PromptGuidance__c
      FROM aao__Agent_Tool_Definition__mdt
      WHERE DeveloperName IN :toolDeveloperNames
    ];

    // Step 4: Build map keyed by DeveloperName (NOT Id)
    Map<String, aao__Agent_Tool_Definition__mdt> result = new Map<String, aao__Agent_Tool_Definition__mdt>();

    for (aao__Agent_Tool_Definition__mdt def : defs) {
      result.put(def.DeveloperName, def);
    }

    return result;
  }
}
