/**
 * @description Decides which agents the running user is allowed to converse with.
 *
 * An agent is open to everyone by default. Setting
 * `Agent_Definition__mdt.Required_Custom_Permission__c` to the API name of a Custom Permission
 * narrows it: only users who hold that permission - through a permission set, a permission set
 * group, or a profile - can start or continue a run against that agent. That keeps the
 * membership question where Salesforce admins already answer it, so no group-membership
 * resolution happens here.
 *
 * The check is deliberately fail-closed. `FeatureManagement.checkPermission` returns false for
 * a custom permission that does not exist, so a typo in the field locks the agent rather than
 * opening it.
 *
 * Enforcement happens at the entry points that a user can reach directly - the chat picker in
 * `AgentChatController`, and `AgentEngine.runAgent` / `runAgentInSession`. Sub-agent
 * delegation (`SubAgentTool` -> `AgentEngine.startSubAgentRun`) is not gated: which agents may
 * delegate to which is admin-configured through `Agent_Tool_Mapping__mdt`, not user-chosen,
 * and the child run's tools still execute in user mode under the running user's own CRUD/FLS.
 * @group Security
 */
public with sharing class AgentAccess {
  // Permission checks are pure metadata lookups, but an agent picker asks the same question
  // repeatedly within one transaction, so memoise per custom permission API name.
  private static final Map<String, Boolean> PERMISSION_CACHE = new Map<String, Boolean>();

  // Cached agent -> required permission, so a chat turn does not re-query the CMDT.
  private static Map<String, String> requirementByAgent;

  /**
   * @description Whether the running user may converse with an agent.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` to test.
   * @return True when the agent has no required custom permission, or the user holds it.
   */
  public static Boolean hasAccess(String agentDeveloperName) {
    if (String.isBlank(agentDeveloperName)) {
      return false;
    }
    return holdsPermission(requirements().get(agentDeveloperName));
  }

  /**
   * @description Throws unless the running user may converse with the agent. The message is
   * deliberately the same whether the agent is restricted or does not exist, so the gate
   * cannot be used to enumerate agent names.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` to test.
   * @exception AuraHandledException When the user does not hold the agent's required permission.
   */
  public static void assertAccess(String agentDeveloperName) {
    if (!hasAccess(agentDeveloperName)) {
      // AuraHandledException to match the other user-facing rejections in
      // AgentEngine.runAgentInSession; AgentChatApi surfaces getMessage() for REST callers.
      throw new AuraHandledException(
        'You do not have access to this agent: ' + agentDeveloperName
      );
    }
  }

  /**
   * @description Filters a list of agent DeveloperNames down to the ones the running user may
   * converse with, preserving order. One CMDT read for the whole list.
   * @param agentDeveloperNames Agent DeveloperNames to filter.
   * @return The subset the running user is allowed to reach.
   */
  public static List<String> filterAccessible(
    List<String> agentDeveloperNames
  ) {
    List<String> allowed = new List<String>();
    Map<String, String> required = requirements();
    for (String name : agentDeveloperNames) {
      if (holdsPermission(required.get(name))) {
        allowed.add(name);
      }
    }
    return allowed;
  }

  /**
   * @description The custom permission each agent requires, for admin UIs that need to show
   * the restriction rather than enforce it.
   * @return Agent DeveloperName -> required custom permission API name, blank entries omitted.
   */
  public static Map<String, String> restrictions() {
    Map<String, String> restricted = new Map<String, String>();
    Map<String, String> required = requirements();
    for (String agentName : required.keySet()) {
      String permission = required.get(agentName);
      if (String.isNotBlank(permission)) {
        restricted.put(agentName, permission.trim());
      }
    }
    return restricted;
  }

  // Blank requirement (including an agent absent from the map) means unrestricted.
  private static Boolean holdsPermission(String customPermission) {
    if (String.isBlank(customPermission)) {
      return true;
    }
    String apiName = customPermission.trim();
    if (!PERMISSION_CACHE.containsKey(apiName)) {
      PERMISSION_CACHE.put(apiName, checkPermission(apiName));
    }
    return PERMISSION_CACHE.get(apiName);
  }

  // FeatureManagement.checkPermission cannot be mocked, and a test cannot create a Custom
  // Permission to hold, so the "user has the permission" branch is only reachable through
  // this seam. Gated on Test.isRunningTest() so the override can never apply in production.
  private static Boolean checkPermission(String apiName) {
    if (Test.isRunningTest() && heldPermissions != null) {
      return heldPermissions.contains(apiName);
    }
    return FeatureManagement.checkPermission(apiName);
  }

  private static Map<String, String> requirements() {
    if (requirementByAgent == null) {
      requirementByAgent = new Map<String, String>();
      for (aao__Agent_Definition__mdt def : [
        SELECT DeveloperName, aao__Required_Custom_Permission__c
        FROM aao__Agent_Definition__mdt
      ]) {
        requirementByAgent.put(
          def.DeveloperName,
          def.aao__Required_Custom_Permission__c
        );
      }
    }
    return requirementByAgent;
  }

  //
  // ───────────────────────────────────────────────────────────────
  // Test hooks
  // ───────────────────────────────────────────────────────────────
  //

  // The custom permissions the running user is treated as holding. Null (the default) means
  // fall through to the real FeatureManagement check.
  @TestVisible
  private static Set<String> heldPermissions;

  /**
   * @description Test hook: seeds the agent -> required permission map so tests can restrict an
   * agent without deploying Custom Metadata, which Apex cannot DML.
   * @param requiredByAgent Agent DeveloperName -> required custom permission API name.
   */
  @TestVisible
  private static void setRequirements(Map<String, String> requiredByAgent) {
    requirementByAgent = requiredByAgent;
    PERMISSION_CACHE.clear();
  }
}
