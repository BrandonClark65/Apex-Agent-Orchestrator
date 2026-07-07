/**
 * @description Tests `DescribeObjectTool`: describing a known sObject, the shape of returned
 * field metadata, system fields correctly reporting as non-createable, an unknown sObject, and
 * a missing `object` arg.
 * @group Tests
 */
@IsTest
private class DescribeObjectToolTest {
  @IsTest
  static void testGetNameAndDescription() {
    DescribeObjectTool tool = new DescribeObjectTool();
    System.assertEquals('DescribeObjectTool', tool.getName());
    System.assertEquals(
      'Returns metadata about an sObject, including fields, types, and updateability.',
      tool.getDescription()
    );
  }

  @IsTest
  static void testDescribeAccount() {
    DescribeObjectTool tool = new DescribeObjectTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'Account' }
    );

    System.assert(result.success, result.message);
    System.assertEquals('Account', result.data.get('object'));

    Map<String, Object> fields = (Map<String, Object>) result.data.get(
      'fields'
    );
    System.assertNotEquals(null, fields);
    System.assert(fields.size() > 0);
    System.assert(
      fields.containsKey('name'),
      'Expected standard field "name" in describe result'
    );
  }

  @IsTest
  static void testFieldMetadataShape() {
    DescribeObjectTool tool = new DescribeObjectTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'Account' }
    );

    System.assert(result.success, result.message);
    Map<String, Object> fields = (Map<String, Object>) result.data.get(
      'fields'
    );
    Map<String, Object> nameField = (Map<String, Object>) fields.get('name');

    System.assertNotEquals(null, nameField, 'Expected "name" field metadata');
    System.assertEquals('Account Name', nameField.get('label'));
    System.assertEquals('STRING', nameField.get('type'));
    System.assertEquals(true, nameField.get('updateable'));
    System.assertEquals(true, nameField.get('createable'));
    System.assertEquals(false, nameField.get('nillable'));
  }

  @IsTest
  static void testSystemFieldIsNonCreateable() {
    DescribeObjectTool tool = new DescribeObjectTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'Account' }
    );

    System.assert(result.success, result.message);
    Map<String, Object> fields = (Map<String, Object>) result.data.get(
      'fields'
    );
    Map<String, Object> createdDate = (Map<String, Object>) fields.get(
      'createddate'
    );

    System.assertNotEquals(
      null,
      createdDate,
      'Expected "createddate" in describe result'
    );
    System.assertEquals(false, createdDate.get('createable'));
    System.assertEquals(false, createdDate.get('updateable'));
  }

  @IsTest
  static void testUnknownObject() {
    DescribeObjectTool tool = new DescribeObjectTool();

    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'object' => 'FakeObject__zzzz' }
    );

    System.assertEquals(false, result.success);
    System.assert(result.message.contains('Object not found'));
  }

  @IsTest
  static void testNullObject() {
    DescribeObjectTool tool = new DescribeObjectTool();

    AgentToolResult result = tool.run(new Map<String, Object>());

    System.assertEquals(false, result.success);
    System.assert(result.message.contains('Object not found'));
  }
}
