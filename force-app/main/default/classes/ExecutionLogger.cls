public with sharing class ExecutionLogger {
    //
    // ───────────────────────────────────────────────────────────────
    // START RUN
    // ───────────────────────────────────────────────────────────────
    //
    public static Id startRun(String agentName, String inputContextJson, String triggerType) {
        aao__Agent_Run__c run = new aao__Agent_Run__c(
            aao__Agent__c = agentName,
            aao__Status__c = 'Running',
            aao__Input_Context__c = inputContextJson,
            aao__Started_At__c = System.now(),
            aao__Trigger_Type__c = String.isBlank(triggerType) ? 'Unknown' : triggerType
        );
        insert run;
        return run.Id;
    }
    //
    // ───────────────────────────────────────────────────────────────
    // STEP NUMBER HELPERS
    // ───────────────────────────────────────────────────────────────
    //

    // Returns the next step number (COUNT + 1)
    public static Integer nextStepNumber(Id runId) {
        Integer countSteps = [
            SELECT COUNT()
            FROM aao__Agent_Step__c
            WHERE aao__Agent_Run__c = :runId
        ];
        return countSteps + 1;
    }

    // Returns the current step count (COUNT)
    public static Integer getCurrentStep(Id runId) {
        return [
            SELECT COUNT()
            FROM aao__Agent_Step__c
            WHERE aao__Agent_Run__c = :runId
        ];
    }
    //
    // ───────────────────────────────────────────────────────────────
    // Check for identical tool call (to avoid duplicates)
    // ───────────────────────────────────────────────────────────────
    // 
    public static Boolean hasIdenticalToolCall(Id runId, String toolName, Map<String, Object> args) {
        List<aao__Agent_Step__c> steps = [
            SELECT aao__Step_Type__c, aao__Tool_Input__c, aao__Tool__c
            FROM aao__Agent_Step__c
            WHERE aao__Agent_Run__c = :runId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (steps.isEmpty()) return false;

        aao__Agent_Step__c last = steps[0];

        if (last.aao__Step_Type__c != 'ToolCall') return false;
        if (last.aao__Tool__c != toolName) return false;

        // Normalize both sides
        String lastNormalized = normalize(JSON.deserializeUntyped(last.aao__Tool_Input__c));
        String currentNormalized = normalize(args);

        return lastNormalized == currentNormalized;
    }
    private static String normalize(Object value) {
        // Serialize → Deserialize → Serialize again
        // This produces stable, canonical JSON ordering
        return JSON.serialize(
            JSON.deserializeUntyped(
                JSON.serialize(value)
            )
        );
    }


    //
    // ───────────────────────────────────────────────────────────────
    // LOG STEP
    // ───────────────────────────────────────────────────────────────
    //   
    public static void logStep(Id runId, AgentStepLog log) {
        aao__Agent_Step__c step = new aao__Agent_Step__c(
            aao__Agent_Run__c = runId,
            aao__Step_Number__c = log.stepNumber,
            aao__Step_Type__c = log.stepType,
            aao__LLM_Request__c = log.llmRequest,
            aao__LLM_Response__c = log.llmResponse,
            aao__Tool_Input__c = log.toolInput,
            aao__Tool_Output__c = log.toolOutput,
            aao__Status__c = log.status,
            aao__Tool__c = log.toolName
        );
        insert step;
    }
    //
    // ───────────────────────────────────────────────────────────────
    // FINISH RUN
    // ───────────────────────────────────────────────────────────────
    //
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
