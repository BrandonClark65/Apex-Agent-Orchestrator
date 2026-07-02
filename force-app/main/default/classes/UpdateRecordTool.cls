/**
 * @description Bulk-updates records by Id from LLM-supplied field maps. Expects `args` shaped
 * as `{"object": "Account", "records": [{"id": "...", "fields": {...}}, ...]}`. Validates each
 * record's fields against the object's describe (existence + updateability) before attempting
 * DML; per-record results (including DML errors) are returned individually so a partial
 * failure in one record doesn't fail the whole batch.
 * @group Agent Tools
 */
public with sharing class UpdateRecordTool implements AgentTool {
  public String getName() {
    return 'UpdateRecordTool';
  }

  public String getDescription() {
    return 'Bulk-updates Salesforce records by Id.';
  }

  /**
   * @description Validates and bulk-updates the requested records.
   * @param args Must contain `object` (sObject API name) and `records` (list of `{"id": "...", "fields": {...}}` maps).
   * @return Success result containing a results list with per-record id/success/message.
   */
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

      // Build records + validation
      for (Object o : recordsInput) {
        Map<String, Object> rec = (Map<String, Object>) o;

        String recordId = (String) rec.get('id');
        Map<String, Object> fields = (Map<String, Object>) rec.get('fields');

        if (String.isBlank(recordId) || fields == null) {
          results.add(
            new Map<String, Object>{
              'id' => recordId,
              'success' => false,
              'message' => 'Missing id or fields'
            }
          );
          continue;
        }

        Boolean valid = true;

        // Validate fields
        for (String key : fields.keySet()) {
          if (!fieldMap.containsKey(key)) {
            results.add(
              new Map<String, Object>{
                'id' => recordId,
                'success' => false,
                'message' => 'Invalid field: ' + key
              }
            );
            valid = false;
            break;
          }

          Schema.DescribeFieldResult f = fieldMap.get(key).getDescribe();
          if (!f.isUpdateable()) {
            results.add(
              new Map<String, Object>{
                'id' => recordId,
                'success' => false,
                'message' => 'Field not updateable: ' + key
              }
            );
            valid = false;
            break;
          }
        }

        if (!valid)
          continue;

        // Build SObject
        SObject sobj = typeRef.newSObject(recordId);
        for (String key : fields.keySet()) {
          sobj.put(key, fields.get(key));
        }
        toUpdate.add(sobj);

        // Placeholder result — overwritten below once DML outcome is known
        results.add(
          new Map<String, Object>{
            'id' => recordId,
            'success' => true,
            'message' => 'Pending update'
          }
        );
      }

      // Perform DML
      if (!toUpdate.isEmpty()) {
        try {
          update toUpdate;

          // Confirm success on every record that was actually submitted for DML
          for (Map<String, Object> r : results) {
            if (r.get('message') == 'Pending update') {
              r.put('message', 'Updated successfully');
            }
          }
        } catch (DmlException d) {
          // Align DML errors to only the "Pending update" entries
          Integer updateIndex = 0;

          for (Integer i = 0; i < results.size(); i++) {
            Map<String, Object> r = results[i];

            if (
              (Boolean) r.get('success') == true &&
              r.get('message') == 'Pending update'
            ) {
              r.put('success', false);
              r.put('message', d.getDmlMessage(updateIndex));
              updateIndex++;
            }
          }
        }
      }

      return AgentToolResult.success(
        'Records updated',
        new Map<String, Object>{ 'results' => results }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
