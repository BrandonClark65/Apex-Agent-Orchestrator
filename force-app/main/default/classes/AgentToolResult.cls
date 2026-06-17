public class AgentToolResult {
    public Boolean success;
    public String message;
    public Map<String, Object> data;

    public AgentToolResult(Boolean success, String message, Map<String, Object> data) {
        this.success = success;
        this.message = message;
        this.data = data;
    }
}