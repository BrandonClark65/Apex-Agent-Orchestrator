/**
 * @description Tests `UpdateRecordTool`: single/multi record updates, missing `object`/`records`
 * args, unknown sObject, missing id/fields, invalid/non-updateable fields, partial-success
 * batches, and DML failures (e.g. updating a deleted record).
 * @group Tests
 */
@IsTest
private class UpdateRecordToolTest {
  @IsTest
  static void testGetNameAndDescription() {
    UpdateRecordTool tool = new UpdateRecordTool();
    System.assertEquals('UpdateRecordTool', tool.getName());
    System.assertEquals(
      'Bulk-updates Salesforce records by Id.',
      tool.getDescription()
    );
  }

  @IsTest
  static void testUpdateSingleRecord() {
    Account acc = new Account(Name = 'Before');
    insert acc;

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'id' => acc.Id,
            'fields' => new Map<String, Object>{ 'Name' => 'After' }
          }
        }
      }
    );

    System.assert(result.success, result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    System.assertEquals(1, results.size());
    Map<String, Object> r = (Map<String, Object>) results[0];
    System.assertEquals(true, r.get('success'));
    System.assertEquals(acc.Id, r.get('id'));
    System.assertEquals('Updated successfully', r.get('message'));
    System.assertEquals(
      'After',
      [SELECT Name FROM Account WHERE Id = :acc.Id].Name
    );
  }

  @IsTest
  static void testUpdateMultipleRecords() {
    Account a1 = new Account(Name = 'Alpha Old');
    Account a2 = new Account(Name = 'Beta Old');
    insert new List<Account>{ a1, a2 };

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'id' => a1.Id,
            'fields' => new Map<String, Object>{ 'Name' => 'Alpha New' }
          },
          new Map<String, Object>{
            'id' => a2.Id,
            'fields' => new Map<String, Object>{ 'Name' => 'Beta New' }
          }
        }
      }
    );

    System.assert(result.success, result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    System.assertEquals(2, results.size());
    for (Object o : results) {
      Map<String, Object> r = (Map<String, Object>) o;
      System.assertEquals(true, r.get('success'));
    }
    System.assertEquals(
      'Alpha New',
      [SELECT Name FROM Account WHERE Id = :a1.Id].Name
    );
    System.assertEquals(
      'Beta New',
      [SELECT Name FROM Account WHERE Id = :a2.Id].Name
    );
  }

  @IsTest
  static void testMissingObjectArg() {
    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'records' => new List<Object>{} }
    );

    System.assertEquals(false, result.success);
    System.assertEquals('Missing object or records list', result.message);
  }

  @IsTest
  static void testMissingRecordsArg() {
    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'Account' }
    );

    System.assertEquals(false, result.success);
    System.assertEquals('Missing object or records list', result.message);
  }

  @IsTest
  static void testUnknownObject() {
    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'FakeObject__zzzz',
        'records' => new List<Object>{}
      }
    );

    System.assertEquals(false, result.success);
    System.assert(result.message.contains('Object not found'));
  }

  @IsTest
  static void testMissingIdOrFields() {
    Account acc = new Account(Name = 'Test');
    insert acc;

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'fields' => new Map<String, Object>{ 'Name' => 'X' }
          }, // no id
          new Map<String, Object>{ 'id' => acc.Id } // no fields
        }
      }
    );

    // Nothing was updated, so the envelope must fail — but still carry the breakdown.
    System.assertEquals(false, result.success);
    System.assertEquals('No records updated', result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    System.assertEquals(2, results.size());
    for (Object o : results) {
      Map<String, Object> r = (Map<String, Object>) o;
      System.assertEquals(false, r.get('success'));
      System.assertEquals('Missing id or fields', r.get('message'));
    }
  }

  @IsTest
  static void testInvalidFieldName() {
    Account acc = new Account(Name = 'Test');
    insert acc;

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'id' => acc.Id,
            'fields' => new Map<String, Object>{
              'NotARealField__xyz' => 'value'
            }
          }
        }
      }
    );

    System.assertEquals(false, result.success);
    System.assertEquals('No records updated', result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    Map<String, Object> r = (Map<String, Object>) results[0];
    System.assertEquals(false, r.get('success'));
    System.assert(((String) r.get('message')).startsWith('Invalid field'));
  }

  @IsTest
  static void testNonUpdateableField() {
    Account acc = new Account(Name = 'Test');
    insert acc;

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'id' => acc.Id,
            'fields' => new Map<String, Object>{ 'CreatedDate' => '2024-01-01' }
          }
        }
      }
    );

    System.assertEquals(false, result.success);
    System.assertEquals('No records updated', result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    Map<String, Object> r = (Map<String, Object>) results[0];
    System.assertEquals(false, r.get('success'));
    System.assert(((String) r.get('message')).contains('not updateable'));
  }

  @IsTest
  static void testPartialSuccess() {
    Account a1 = new Account(Name = 'Old Name');
    insert a1;

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'id' => a1.Id,
            'fields' => new Map<String, Object>{ 'Name' => 'New Name' }
          },
          new Map<String, Object>{
            'id' => a1.Id,
            'fields' => new Map<String, Object>{
              'NotARealField__xyz' => 'value'
            }
          }
        }
      }
    );

    System.assert(result.success, result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    System.assertEquals(2, results.size());

    Map<String, Object> good = (Map<String, Object>) results[0];
    System.assertEquals(true, good.get('success'));

    Map<String, Object> bad = (Map<String, Object>) results[1];
    System.assertEquals(false, bad.get('success'));

    System.assertEquals(
      'New Name',
      [SELECT Name FROM Account WHERE Id = :a1.Id].Name
    );
  }

  @IsTest
  static void testDmlFailure() {
    Account acc = new Account(Name = 'To Delete');
    insert acc;
    delete acc; // updating a deleted record throws DmlException

    UpdateRecordTool tool = new UpdateRecordTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'records' => new List<Object>{
          new Map<String, Object>{
            'id' => acc.Id,
            'fields' => new Map<String, Object>{ 'Name' => 'Updated' }
          }
        }
      }
    );

    // The AR-0037 shape: DML rejected every record. The envelope has to fail so the step
    // logs as 'Failed' and the engine's consecutive-error guard can count it.
    System.assertEquals(false, result.success);
    System.assertEquals('No records updated', result.message);
    List<Object> results = (List<Object>) result.data.get('results');
    Map<String, Object> r = (Map<String, Object>) results[0];
    System.assertEquals(false, r.get('success'));
    System.assertNotEquals(null, r.get('message'));
  }
}
