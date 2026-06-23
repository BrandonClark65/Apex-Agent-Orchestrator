public class AgentToolResult {
    public Boolean success;
    public String message;
    public Map<String, Object> data;

    public AgentToolResult(Boolean success, String message, Map<String, Object> data) {
        this.success = success;
        this.message = message;
        this.data = data;
    }

    // SUCCESS helper
    public static AgentToolResult success(String message, Map<String, Object> data) {
        return new AgentToolResult(true, message, data);
    }

    // ERROR helper
    public static AgentToolResult error(String message) {
        return new AgentToolResult(false, message, null);
    }
}