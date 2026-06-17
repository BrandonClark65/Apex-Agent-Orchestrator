public with sharing class ToolRegistry {

    public static AgentTool getToolByClassName(String className) {
        Type t = Type.forName(className);
        if (t == null) {
            throw new AuraHandledException('Tool class not found: ' + className);
        }
        return (AgentTool)t.newInstance();
    }

    public static List<AgentTool> getToolsForAgent(String agentDeveloperName) {
        List<AgentTool> tools = new List<AgentTool>();

        for (aao__Agent_Tool_Mapping__mdt mapping : [
            SELECT aao__Tool__r.aao__Tool_Class__c
            FROM aao__Agent_Tool_Mapping__mdt
            WHERE aao__Agent__c = :agentDeveloperName
              AND aao__IsAllowed__c = true
        ]) {
            tools.add(getToolByClassName(mapping.aao__Tool__r.aao__Tool_Class__c));
        }

        return tools;
    }
}
