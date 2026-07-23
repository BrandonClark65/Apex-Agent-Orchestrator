/**
 * @description Static, per-transaction context describing the agent run a tool is executing
 * inside. `AgentEngine.runToolStep` populates it immediately before calling `AgentTool.run`,
 * so tools that need run-level information (currently `SubAgentTool`, which links child runs
 * to the parent run and enforces the nesting-depth guard) can read it without changing the
 * `AgentTool` interface. Values are only meaningful during a tool step's transaction.
 * @group Agent Tools
 */
public with sharing class AgentToolContext {
  /** @description Id of the `Agent_Run__c` the current tool step belongs to. */
  public static Id runId;

  /** @description DeveloperName of the `Agent_Definition__mdt` being run. */
  public static String agentDeveloperName;

  /** @description Trigger label the run was started with (e.g. `'LWC'`, `'SubAgent'`). */
  public static String triggerType;

  /** @description Sub-agent nesting depth of the current run (0 for top-level runs). */
  public static Integer depth = 0;

  /**
   * @description The authenticated customer number the current session is scoped to, copied
   * from `Agent_Session__c.Customer_Number__c`. It is bound server-side at session creation
   * from a trusted caller — never from the chat message or the LLM — so record-scoped tools
   * (e.g. `GetMyCasesTool`) can filter to only this customer's records without ever accepting
   * a customer identifier as a tool argument the model could spoof. Null when the session has
   * no bound customer (in-org Lightning sessions, or external sessions started without an
   * identity); scoped tools must fail closed in that case rather than returning unscoped data.
   */
  public static String customerNumber;
}
