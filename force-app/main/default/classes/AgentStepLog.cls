public class AgentStepLog {
    public Integer stepNumber;
    public String stepType;
    public String llmRequest;
    public String llmResponse;
    public String toolInput;
    public String toolOutput;
    public String status;

    public AgentStepLog(
        Integer stepNumber,
        String stepType,
        String llmRequest,
        String llmResponse,
        String toolInput,
        String toolOutput,
        String status
    ) {
        this.stepNumber = stepNumber;
        this.stepType = stepType;
        this.llmRequest = llmRequest;
        this.llmResponse = llmResponse;
        this.toolInput = toolInput;
        this.toolOutput = toolOutput;
        this.status = status;
    }
}
