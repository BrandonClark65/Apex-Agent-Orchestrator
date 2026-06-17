public interface AgentTool {
    AgentToolResult run(Map<String, Object> args);
    String getName();
    String getDescription();
}