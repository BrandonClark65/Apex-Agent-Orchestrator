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

        // Step 1: Query mappings by Agent DeveloperName (now a text field)
        List<aao__Agent_Tool_Mapping__mdt> mappings = [
            SELECT aao__Tool__c
            FROM aao__Agent_Tool_Mapping__mdt
            WHERE aao__Agent__c = :agentDeveloperName
              AND aao__IsAllowed__c = true
        ];

        if (mappings.isEmpty()) {
            return tools;
        }

        // Step 2: Collect tool DeveloperNames
        Set<String> toolDeveloperNames = new Set<String>();
        for (aao__Agent_Tool_Mapping__mdt m : mappings) {
            toolDeveloperNames.add(m.aao__Tool__c);
        }

        // Step 3: Query Tool Definition CMDT by DeveloperName
        Map<String, aao__Agent_Tool_Definition__mdt> toolDefs = new Map<String, aao__Agent_Tool_Definition__mdt>([
            SELECT DeveloperName, aao__Tool_Class__c
            FROM aao__Agent_Tool_Definition__mdt
            WHERE DeveloperName IN :toolDeveloperNames
        ]);

        // Step 4: Instantiate tool classes
        for (String devName : toolDeveloperNames) {
            aao__Agent_Tool_Definition__mdt def = toolDefs.get(devName);
            if (def == null) {
                throw new AuraHandledException('Tool definition not found for: ' + devName);
            }
            tools.add(getToolByClassName(def.aao__Tool_Class__c));
        }

        return tools;
    }
}

