public with sharing class DescribeObjectTool implements AgentTool {
    public String getName() {
        return 'DescribeObjectTool';
    }

    public String getDescription() {
        return 'Returns metadata about an sObject, including fields, types, and updateability.';
    }

    public AgentToolResult run(Map<String, Object> args) {
        try {
            String objectName = (String) args.get('object');
            Schema.SObjectType typeRef = Schema.getGlobalDescribe().get(objectName);

            if (typeRef == null) {
                return AgentToolResult.error('Object not found: ' + objectName);
            }

            Schema.DescribeSObjectResult describe = typeRef.getDescribe();
            Map<String, Schema.SObjectField> fields = describe.fields.getMap();

            Map<String, Object> fieldInfo = new Map<String, Object>();

            for (String apiName : fields.keySet()) {
                Schema.DescribeFieldResult f = fields.get(apiName).getDescribe();

                fieldInfo.put(apiName, new Map<String, Object>{
                    'label' => f.getLabel(),
                    'type' => f.getType().name(),
                    'updateable' => f.isUpdateable(),
                    'createable' => f.isCreateable(),
                    'nillable' => f.isNillable()
                });
            }

            return AgentToolResult.success(new Map<String, Object>{
                'object' => objectName,
                'fields' => fieldInfo
            });

        } catch (Exception e) {
            return AgentToolResult.error(e.getMessage());
        }
    }
}
