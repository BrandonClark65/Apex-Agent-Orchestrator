public class AgentStepLog {
    public Integer stepNumber;
    public String stepType;
    public String llmRequest;
    public String llmResponse;
    public String toolInput;
    public String toolOutput;
    public String status;
    public String toolName;

    public AgentStepLog(
        Integer stepNumber,
        String stepType,
        Object llmRequest,
        Object llmResponse,
        Object toolInput,
        Object toolOutput,
        String status,
        String toolName
    ) {
        this.stepNumber = stepNumber;
        this.stepType = stepType;
        this.llmRequest = llmRequest == null ? null : JSON.serialize(llmRequest);
        this.llmResponse = llmResponse == null ? null : JSON.serialize(llmResponse);
        this.toolInput = toolInput == null ? null : JSON.serialize(toolInput);
        this.toolOutput = toolOutput == null ? null : JSON.serialize(toolOutput);
        this.status = status;
        this.toolName = toolName;
    }
}

