public with sharing class UpdateRecordTool implements AgentTool {

    public String getName() {
        return 'UpdateRecordTool';
    }

    public String getDescription() {
        return 'Bulk-updates Salesforce records by Id.';
    }

    public AgentToolResult run(Map<String, Object> args) {
        try {
            String objectType = (String) args.get('object');
            List<Object> recordsInput = (List<Object>) args.get('records');

            if (String.isBlank(objectType) || recordsInput == null) {
                return AgentToolResult.error('Missing object or records list');
            }

            // Validate object exists
            Schema.SObjectType typeRef = Schema.getGlobalDescribe().get(objectType);
            if (typeRef == null) {
                return AgentToolResult.error('Object not found: ' + objectType);
            }

            Schema.DescribeSObjectResult describe = typeRef.getDescribe();
            Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();

            List<SObject> toUpdate = new List<SObject>();
            List<Map<String, Object>> results = new List<Map<String, Object>>();

            for (Object o : recordsInput) {
                Map<String, Object> rec = (Map<String, Object>) o;

                String recordId = (String) rec.get('id');
                Map<String, Object> fields = (Map<String, Object>) rec.get('fields');

                if (String.isBlank(recordId) || fields == null) {
                    results.add(new Map<String, Object>{
                        'id' => recordId,
                        'success' => false,
                        'message' => 'Missing id or fields'
                    });
                    continue;
                }

                // Validate fields
                Boolean valid = true;
                for (String key : fields.keySet()) {
                    if (!fieldMap.containsKey(key)) {
                        results.add(new Map<String, Object>{
                            'id' => recordId,
                            'success' => false,
                            'message' => 'Invalid field: ' + key
                        });
                        valid = false;
                        break;
                    }

                    Schema.DescribeFieldResult f = fieldMap.get(key).getDescribe();
                    if (!f.isUpdateable()) {
                        results.add(new Map<String, Object>{
                            'id' => recordId,
                            'success' => false,
                            'message' => 'Field not updateable: ' + key
                        });
                        valid = false;
                        break;
                    }
                }

                if (!valid) continue;

                // Build SObject
                SObject sobj = typeRef.newSObject(recordId);
                for (String key : fields.keySet()) {
                    sobj.put(key, fields.get(key));
                }
                toUpdate.add(sobj);

                results.add(new Map<String, Object>{
                    'id' => recordId,
                    'success' => true,
                    'message' => 'Pending update'
                });
            }

            if (!toUpdate.isEmpty()) {
                try {
                    update toUpdate;
                } catch (DmlException d) {
                    // Attach DML errors to results
                    for (Integer i = 0; i < toUpdate.sizeUp(); i++) {
                        results[i].put('success', false);
                        results[i].put('message', d.getDmlMessage(i));
                    }
                }
            }

            return AgentToolResult.success(new Map<String, Object>{
                'results' => results
            });

        } catch (Exception e) {
            return AgentToolResult.error(e.getMessage());
        }
    }
}

