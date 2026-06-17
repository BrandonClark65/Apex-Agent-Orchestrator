public with sharing class ExecutionLogger {

    public static Id startRun(String agentName, String inputContextJson) {
        aao__Agent_Run__c run = new aao__Agent_Run__c(
            aao__Agent__c = agentName,
            aao__Status__c = 'Running',
            aao__Input_Context__c = inputContextJson,
            aao__Started_At__c = System.now()
        );
        insert run;
        return run.Id;
    }

    public static void logStep(Id runId, AgentStepLog log) {
        aao__Agent_Step__c step = new aao__Agent_Step__c(
            aao__Agent_Run__c = runId,
            aao__Step_Number__c = log.stepNumber,
            aao__Step_Type__c = log.stepType,
            aao__LLM_Request__c = log.llmRequest,
            aao__LLM_Response__c = log.llmResponse,
            aao__Tool_Input__c = log.toolInput,
            aao__Tool_Output__c = log.toolOutput,
            aao__Status__c = log.status
        );
        insert step;
    }

    public static void finishRun(Id runId, String finalOutput, String status, String errorMessage) {
        aao__Agent_Run__c run = new aao__Agent_Run__c(
            Id = runId,
            aao__Status__c = status,
            aao__Final_Output__c = finalOutput,
            aao__Error_Message__c = errorMessage,
            aao__Finished_At__c = System.now()
        );
        update run;
    }
}
