/**
 * @description Lets one agent delegate a task to another agent. Starts a child `Agent_Run__c`
 * for the requested `Agent_Definition__mdt` and returns a *pending* result — the parent run
 * suspends (its ToolCall step is logged with status `'Pending'` and no next step is scheduled)
 * until the child run finishes, at which point `ExecutionLogger.finishRun` resumes the parent
 * via `AgentEngine.resumeParentRun` with the child's final output as the tool result. Reads the
 * parent run's Id/depth from `AgentToolContext`; nesting is capped at `MAX_DEPTH` levels of
 * sub-agents to prevent runaway recursion (an agent may delegate to itself within that cap).
 * @group Agent Tools
 */
public with sharing class SubAgentTool implements AgentTool {
  // Maximum sub-agent nesting depth below a top-level run (depth 0).
  @TestVisible
  private static final Integer MAX_DEPTH = 3;

  public String getName() {
    return 'SubAgentTool';
  }

  public String getDescription() {
    return 'Delegates a task to another agent and returns that agent\'s final answer as the tool output.';
  }

  /**
   * @description Validates the requested agent and starts its run as a child of the current
   * run. Does not wait for the child — returns `AgentToolResult.pending`, which tells
   * `AgentEngine.runToolStep` to suspend the parent run until the child finishes.
   * @param args Must contain `agentName` (DeveloperName of the child `Agent_Definition__mdt`) and `input` (the task for the child agent, as a string or JSON object).
   * @return Pending result whose data contains `agentName` and `childRunId`, or an error result if validation fails.
   */
  public AgentToolResult run(Map<String, Object> args) {
    try {
      String agentName = (String) args.get('agentName');
      if (String.isBlank(agentName)) {
        return AgentToolResult.error('Missing required argument: agentName');
      }

      Object input = args.get('input');
      if (input == null) {
        return AgentToolResult.error('Missing required argument: input');
      }

      if (AgentToolContext.runId == null) {
        return AgentToolResult.error(
          'SubAgentTool can only be invoked from within an agent run'
        );
      }

      Integer depth = AgentToolContext.depth != null
        ? AgentToolContext.depth
        : 0;
      if (depth >= MAX_DEPTH) {
        return AgentToolResult.error(
          'Sub-agent nesting depth limit (' +
            MAX_DEPTH +
            ') reached. Complete the task with your own tools and return a final answer.'
        );
      }

      List<aao__Agent_Definition__mdt> defs = [
        SELECT DeveloperName, aao__IsActive__c
        FROM aao__Agent_Definition__mdt
        WHERE DeveloperName = :agentName
        LIMIT 1
      ];
      if (defs.isEmpty()) {
        return AgentToolResult.error('Agent not found: ' + agentName);
      }
      if (defs[0].aao__IsActive__c == false) {
        return AgentToolResult.error('Agent is not active: ' + agentName);
      }

      String inputJson = input instanceof String
        ? (String) input
        : JSON.serialize(input);

      Id childRunId = AgentEngine.startSubAgentRun(
        agentName,
        inputJson,
        AgentToolContext.runId,
        depth + 1
      );

      return AgentToolResult.pending(
        'Sub-agent run started. This run will resume automatically with the sub-agent\'s final output when it finishes.',
        new Map<String, Object>{
          'agentName' => agentName,
          'childRunId' => childRunId
        }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
