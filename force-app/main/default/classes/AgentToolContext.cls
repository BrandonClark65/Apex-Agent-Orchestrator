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
}
