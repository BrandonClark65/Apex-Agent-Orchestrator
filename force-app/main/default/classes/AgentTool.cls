/**
 * @description Interface every agent tool implements. Tool classes are resolved dynamically
 * by `ToolRegistry.getToolByClassName` via `Type.forName`, so implementations must be public
 * and constructible with a no-argument constructor. Which tools an agent may use is driven
 * entirely by `Agent_Tool_Mapping__mdt`/`Agent_Tool_Definition__mdt` custom metadata, not code.
 * @group Agent Tools
 */
public interface AgentTool {
  /**
   * @description Executes the tool with arguments parsed from the LLM's tool-call JSON.
   * Runs outside a `Database.AllowsCallouts` context — implementations may query/describe/DML
   * Salesforce data but must not make HTTP callouts.
   * @param args Tool arguments as parsed from the LLM's response JSON.
   * @return Result of the tool call; build with AgentToolResult.success/AgentToolResult.error.
   */
  AgentToolResult run(Map<String, Object> args);

  /**
   * @description DeveloperName the LLM uses to invoke this tool; should match the
   * corresponding `Agent_Tool_Definition__mdt.DeveloperName`.
   * @return Tool name as shown in the tool manifest.
   */
  String getName();

  /**
   * @description Human-readable description surfaced to the LLM in the tool manifest.
   * @return Tool description.
   */
  String getDescription();
}
