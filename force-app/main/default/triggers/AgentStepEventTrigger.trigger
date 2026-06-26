trigger AgentStepEventTrigger on Agent_Step_Event__e (after insert) {

    for (Agent_Step_Event__e evt : Trigger.new) {
        try {
            Agent_Run__c run = [
                SELECT History_Json__c
                FROM Agent_Run__c
                WHERE Id = :evt.Run_Id__c
                LIMIT 1
            ];

            List<LLMMessage> history = (List<LLMMessage>) JSON.deserialize(
                run.History_Json__c, List<LLMMessage>.class
            );

            if (evt.Step_Type__c == 'LLM') {
                System.enqueueJob(
                    new AgentRunQueueable(
                        evt.Agent_Developer_Name__c,
                        null,
                        evt.Trigger_Type__c,
                        evt.Run_Id__c,
                        history
                    )
                );
            } else {
                Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(
                    evt.Tool_Args_Json__c
                );

                System.enqueueJob(
                    new AgentToolQueueable(
                        evt.Agent_Developer_Name__c,
                        evt.Trigger_Type__c,
                        evt.Run_Id__c,
                        history,
                        evt.Tool_Name__c,
                        args
                    )
                );
            }
        } catch (Exception e) {
            ExecutionLogger.finishRun(evt.Run_Id__c, null, 'Failed', e.getMessage());
        }
    }
}
