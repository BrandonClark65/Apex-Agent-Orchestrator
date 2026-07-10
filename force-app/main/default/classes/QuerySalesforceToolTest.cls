/**
 * @description Tests `QuerySalesforceTool`: successful queries, missing/blank query arg,
 * trailing-brace-artifact stripping, and invalid SOQL.
 * @group Tests
 */
@IsTest
private class QuerySalesforceToolTest {
  @IsTest
  static void testGetNameAndDescription() {
    QuerySalesforceTool tool = new QuerySalesforceTool();
    System.assertEquals('QuerySalesforce', tool.getName());
    System.assertEquals(
      'Runs a SOQL query and returns the results as JSON.',
      tool.getDescription()
    );
  }

  @IsTest
  static void testQueryReturnsMatchingRecords() {
    insert new Account(Name = 'Query Tool Test Account');

    QuerySalesforceTool tool = new QuerySalesforceTool();
    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'query' => 'SELECT Id, Name FROM Account WHERE Name = \'Query Tool Test Account\''
      }
    );

    System.assert(result.success, result.message);
    System.assertEquals('Query executed successfully', result.message);
    List<SObject> records = (List<SObject>) result.data.get('records');
    System.assertEquals(1, records.size());
    System.assertEquals('Query Tool Test Account', records[0].get('Name'));
  }

  @IsTest
  static void testQueryWithNoMatchesReturnsEmptyList() {
    QuerySalesforceTool tool = new QuerySalesforceTool();
    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'query' => 'SELECT Id FROM Account WHERE Name = \'Does Not Exist\''
      }
    );

    System.assert(result.success, result.message);
    List<Object> records = (List<Object>) result.data.get('records');
    System.assertEquals(0, records.size());
  }

  @IsTest
  static void testMissingQueryArg() {
    QuerySalesforceTool tool = new QuerySalesforceTool();
    AgentToolResult result = tool.run(new Map<String, Object>());

    System.assertEquals(false, result.success);
    System.assertEquals('Missing SOQL query', result.message);
  }

  @IsTest
  static void testBlankQueryArg() {
    QuerySalesforceTool tool = new QuerySalesforceTool();
    AgentToolResult result = tool.run(
      new Map<String, Object>{ 'query' => '   ' }
    );

    System.assertEquals(false, result.success);
    System.assertEquals('Missing SOQL query', result.message);
  }

  @IsTest
  static void testStripsTrailingJsonArtifactBraces() {
    insert new Account(Name = 'Brace Strip Test Account');

    QuerySalesforceTool tool = new QuerySalesforceTool();
    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'query' => 'SELECT Id, Name FROM Account WHERE Name = \'Brace Strip Test Account\'}}'
      }
    );

    System.assert(result.success, result.message);
    List<Object> records = (List<Object>) result.data.get('records');
    System.assertEquals(1, records.size());
  }

  @IsTest
  static void testInvalidQueryReturnsError() {
    QuerySalesforceTool tool = new QuerySalesforceTool();
    AgentToolResult result = tool.run(
      new Map<String, Object>{
        'query' => 'SELECT NotARealField__xyz FROM Account'
      }
    );

    System.assertEquals(false, result.success);
    System.assertNotEquals(null, result.message);
  }
}
