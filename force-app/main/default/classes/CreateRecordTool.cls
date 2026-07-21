/**
 * @description Bulk-creates records of any sObject type from LLM-supplied field maps.
 * Expects `args` shaped as `{"object": "Account", "records": [{"fields": {...}}, ...]}`.
 * Validates each record's fields against the object's describe (existence + createability)
 * before attempting DML; per-record results (including DML errors) are returned individually
 * so a partial failure in one record doesn't fail the whole batch. The envelope only reports
 * failure when no record succeeded at all.
 *
 * Access is enforced against the running user's permissions: object-level create (CRUD) is
 * checked up front, field-level create (FLS) is checked per field, and the DML itself runs in
 * user mode (`AccessLevel.USER_MODE`) so record sharing, CRUD, and FLS are all enforced at the
 * database layer as a backstop.
 * @group Agent Tools
 */
public with sharing class CreateRecordTool implements AgentTool {
  public String getName() {
    return 'CreateRecordTool';
  }

  public String getDescription() {
    return 'Bulk-creates Salesforce records of any object type.';
  }

  /**
   * @description Validates and bulk-inserts the requested records.
   * @param args Must contain `object` (sObject API name) and `records` (list of `{"fields": {...}}` maps).
   * @return Success result containing a results list with per-record id/success/message.
   */
  public AgentToolResult run(Map<String, Object> args) {
    try {
      String objectType = (String) args.get('object');
      List<Object> recordsInput = (List<Object>) args.get('records');

      if (String.isBlank(objectType) || recordsInput == null) {
        return AgentToolResult.error('Missing object or records list');
      }

      Schema.SObjectType typeRef = Schema.getGlobalDescribe().get(objectType);
      if (typeRef == null) {
        return AgentToolResult.error('Object not found: ' + objectType);
      }

      Schema.DescribeSObjectResult describe = typeRef.getDescribe();

      // Object-level CRUD: reject the whole request if the running user can't create this
      // object at all, rather than relying solely on the DML backstop below.
      if (!describe.isCreateable()) {
        return AgentToolResult.error(
          'Insufficient access to create ' + objectType
        );
      }

      Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();

      List<SObject> toInsert = new List<SObject>();
      List<Map<String, Object>> results = new List<Map<String, Object>>();

      for (Object o : recordsInput) {
        Map<String, Object> rec = (Map<String, Object>) o;
        Map<String, Object> fields = (Map<String, Object>) rec.get('fields');

        if (fields == null) {
          results.add(
            new Map<String, Object>{
              'id' => null,
              'success' => false,
              'message' => 'Missing fields'
            }
          );
          continue;
        }

        Boolean valid = true;

        for (String key : fields.keySet()) {
          if (!fieldMap.containsKey(key)) {
            results.add(
              new Map<String, Object>{
                'id' => null,
                'success' => false,
                'message' => 'Invalid field: ' + key
              }
            );
            valid = false;
            break;
          }

          Schema.DescribeFieldResult f = fieldMap.get(key).getDescribe();
          if (!f.isCreateable()) {
            results.add(
              new Map<String, Object>{
                'id' => null,
                'success' => false,
                'message' => 'Field not createable: ' + key
              }
            );
            valid = false;
            break;
          }
        }

        if (!valid)
          continue;

        SObject sobj = typeRef.newSObject();
        for (String key : fields.keySet()) {
          sobj.put(key, fields.get(key));
        }
        toInsert.add(sobj);

        results.add(
          new Map<String, Object>{
            'id' => null,
            'success' => true,
            'message' => 'Pending insert'
          }
        );
      }

      if (!toInsert.isEmpty()) {
        try {
          Database.insert(toInsert, AccessLevel.USER_MODE);

          Integer insertIdx = 0;
          for (Map<String, Object> r : results) {
            if (
              (Boolean) r.get('success') == true &&
              r.get('message') == 'Pending insert'
            ) {
              r.put('id', toInsert[insertIdx].Id);
              r.put('message', 'Created successfully');
              insertIdx++;
            }
          }
        } catch (DmlException d) {
          Integer insertIdx = 0;
          for (Map<String, Object> r : results) {
            if (
              (Boolean) r.get('success') == true &&
              r.get('message') == 'Pending insert'
            ) {
              r.put('success', false);
              r.put('message', d.getDmlMessage(insertIdx));
              insertIdx++;
            }
          }
        }
      }

      // Mirrors UpdateRecordTool: a partial failure keeps envelope success so the model
      // doesn't retry records that already committed, but a batch where nothing was
      // created must fail the envelope so the step logs as 'Failed' and the engine's
      // consecutive-error guard can see it.
      Boolean anySucceeded = false;
      for (Map<String, Object> r : results) {
        if ((Boolean) r.get('success') == true) {
          anySucceeded = true;
          break;
        }
      }

      return anySucceeded
        ? AgentToolResult.success(
            'Records created',
            new Map<String, Object>{ 'results' => results }
          )
        : AgentToolResult.failure(
            'No records created',
            new Map<String, Object>{ 'results' => results }
          );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
