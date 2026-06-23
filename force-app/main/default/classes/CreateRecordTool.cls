public with sharing class CreateRecordTool implements AgentTool {

    public String getName() {
        return 'CreateRecordTool';
    }

    public String getDescription() {
        return 'Creates a Salesforce record of any object type.';
    }

    public AgentToolResult run(Map<String, Object> args) {
        try {
            String objectType = (String)args.get('object');
            Map<String, Object> fields = (Map<String, Object>)args.get('fields');

            if (String.isBlank(objectType) || fields == null) {
                return AgentToolResult.error('Missing object or fields');
            }

            SObject record = (SObject)Type.forName('Schema.' + objectType).newInstance();

            for (String key : fields.keySet()) {
                record.put(key, fields.get(key));
            }

            insert record;

            Map<String, Object> data = new Map<String, Object>{
                'id' => record.Id
            };

            return AgentToolResult.success('Record created', data);

        } catch (Exception e) {
            return AgentToolResult.error(e.getMessage());
        }
    }
}
