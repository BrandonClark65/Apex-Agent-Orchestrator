public with sharing class UpdateRecordTool implements AgentTool {

    public String getName() {
        return 'UpdateRecordTool';
    }

    public String getDescription() {
        return 'Updates a Salesforce record by Id.';
    }

    public AgentToolResult run(Map<String, Object> args) {
        try {
            String objectType = (String)args.get('object');
            String recordId = (String)args.get('id');
            Map<String, Object> fields = (Map<String, Object>)args.get('fields');

            if (String.isBlank(objectType) || String.isBlank(recordId) || fields == null) {
                return new AgentToolResult(false, 'Missing object, id, or fields', null);
            }

            SObject record = (SObject)Type.forName('Schema.' + objectType).newInstance();
            record.put('Id', recordId);

            for (String key : fields.keySet()) {
                record.put(key, fields.get(key));
            }

            update record;

            return new AgentToolResult(true, 'Record updated', null);

        } catch (Exception e) {
            return new AgentToolResult(false, e.getMessage(), null);
        }
    }
}
