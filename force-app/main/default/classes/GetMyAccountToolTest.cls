/**
 * @description Tests `GetMyAccountTool`: it returns only the bound customer's own account and
 * fails closed when no customer is bound.
 * @group Tests
 */
@IsTest
private class GetMyAccountToolTest {
  @IsTest
  static void testGetNameAndDescription() {
    GetMyAccountTool tool = new GetMyAccountTool();
    System.assertEquals('GetMyAccount', tool.getName());
    System.assertNotEquals(null, tool.getDescription());
  }

  @IsTest
  static void testReturnsOnlyBoundCustomersAccount() {
    insert new List<Account>{
      new Account(Name = 'Mine', AccountNumber = 'CUST-001'),
      new Account(Name = 'Other', AccountNumber = 'CUST-002')
    };

    AgentToolContext.customerNumber = 'CUST-001';

    AgentToolResult result = new GetMyAccountTool().run(new Map<String, Object>());

    System.assert(result.success, result.message);
    List<Account> records = (List<Account>) result.data.get('records');
    System.assertEquals(1, records.size());
    System.assertEquals('Mine', records[0].Name);
    System.assertEquals('CUST-001', records[0].AccountNumber);
  }

  @IsTest
  static void testReturnsEmptyWhenNoMatchingAccount() {
    AgentToolContext.customerNumber = 'CUST-DOES-NOT-EXIST';

    AgentToolResult result = new GetMyAccountTool().run(new Map<String, Object>());

    System.assert(result.success, result.message);
    List<Account> records = (List<Account>) result.data.get('records');
    System.assertEquals(0, records.size());
  }

  @IsTest
  static void testFailsClosedWhenNoCustomerBound() {
    AgentToolContext.customerNumber = null;

    AgentToolResult result = new GetMyAccountTool().run(new Map<String, Object>());

    System.assertEquals(false, result.success, 'Must fail closed with no customer bound');
    System.assertEquals(null, result.data);
  }
}
