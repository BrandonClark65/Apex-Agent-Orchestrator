/**
 * @description Tests `ValidateFieldTool`: exact (case-insensitive) API name matches,
 * non-updateable fields, label-based fuzzy matching, and an unknown sObject.
 * @group Tests
 */
@IsTest
private class ValidateFieldToolTest {
  @IsTest
  static void testGetNameAndDescription() {
    ValidateFieldTool tool = new ValidateFieldTool();
    System.assertEquals('ValidateFieldTool', tool.getName());
    System.assertEquals(
      'Validates a field on an sObject and returns the correct API name, label, and updateability.',
      tool.getDescription()
    );
  }

  @IsTest
  static void testExactMatch() {
    ValidateFieldTool tool = new ValidateFieldTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'Account', 'field' => 'Name' }
    );

    System.assert(result.success, result.message);
    System.assertEquals(true, result.data.get('exists'));
    System.assertEquals('Name', result.data.get('apiName'));
    System.assertEquals('Account Name', result.data.get('label'));
    System.assertEquals(true, result.data.get('updateable'));
    System.assertEquals(null, result.data.get('fuzzyMatch'));
  }

  @IsTest
  static void testExactMatchIsCaseInsensitive() {
    ValidateFieldTool tool = new ValidateFieldTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'field' => 'phone' // lowercase of standard 'Phone' field
      }
    );

    System.assert(result.success, result.message);
    System.assertEquals(true, result.data.get('exists'));
    System.assertEquals('phone', result.data.get('apiName'));
  }

  @IsTest
  static void testNonUpdateableField() {
    ValidateFieldTool tool = new ValidateFieldTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'Account', 'field' => 'CreatedDate' }
    );

    System.assert(result.success, result.message);
    System.assertEquals(true, result.data.get('exists'));
    System.assertEquals(false, result.data.get('updateable'));
  }

  @IsTest
  static void testFuzzyMatchByLabel() {
    ValidateFieldTool tool = new ValidateFieldTool();

    // 'Account Name' is the label of Account.Name but not its API name,
    // so it falls through to fuzzy matching and matches via levenshtein score 0.
    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'Account',
        'field' => 'Account Name'
      }
    );

    System.assert(result.success, result.message);
    System.assertEquals(true, result.data.get('exists'));
    System.assertEquals(true, result.data.get('fuzzyMatch'));
    System.assertEquals('name', result.data.get('apiName'));
  }

  @IsTest
  static void testUnknownObject() {
    ValidateFieldTool tool = new ValidateFieldTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'object' => 'FakeObject__zzzz',
        'field' => 'Name'
      }
    );

    System.assertEquals(false, result.success);
    System.assert(result.message.contains('Object not found'));
  }
}
