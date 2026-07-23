/**
 * @description Tests `GetMyCasesTool`: it returns only the bound customer's open cases, never
 * another customer's or closed ones, and fails closed when no customer is bound.
 * @group Tests
 */
@IsTest
private class GetMyCasesToolTest {
  @IsTest
  static void testGetNameAndDescription() {
    GetMyCasesTool tool = new GetMyCasesTool();
    System.assertEquals('GetMyCases', tool.getName());
    System.assertNotEquals(null, tool.getDescription());
  }

  @IsTest
  static void testReturnsOnlyBoundCustomersOpenCases() {
    // Two customers, each with cases; only CUST-001 is bound to the session.
    Account mine = new Account(Name = 'Mine', AccountNumber = 'CUST-001');
    Account other = new Account(Name = 'Other', AccountNumber = 'CUST-002');
    insert new List<Account>{ mine, other };

    insert new List<Case>{
      new Case(AccountId = mine.Id, Subject = 'My open case', Status = 'New'),
      new Case(AccountId = mine.Id, Subject = 'My closed case', Status = 'Closed'),
      new Case(AccountId = other.Id, Subject = 'Other open case', Status = 'New')
    };

    AgentToolContext.customerNumber = 'CUST-001';

    Test.startTest();
    AgentToolResult result = new GetMyCasesTool().run(new Map<String, Object>());
    Test.stopTest();

    System.assert(result.success, result.message);
    List<Case> records = (List<Case>) result.data.get('records');
    // Exactly the one OPEN case belonging to the bound customer — not the closed one,
    // not the other customer's case.
    System.assertEquals(1, records.size(), 'Should return only the bound customer\'s open case');
    System.assertEquals('My open case', records[0].Subject);
  }

  @IsTest
  static void testIgnoresAnyCustomerArgument() {
    // Even if the model tries to supply another customer number as an argument, it is ignored:
    // scope comes only from AgentToolContext.
    Account mine = new Account(Name = 'Mine', AccountNumber = 'CUST-001');
    Account other = new Account(Name = 'Other', AccountNumber = 'CUST-002');
    insert new List<Account>{ mine, other };
    insert new List<Case>{
      new Case(AccountId = mine.Id, Subject = 'Mine', Status = 'New'),
      new Case(AccountId = other.Id, Subject = 'Theirs', Status = 'New')
    };

    AgentToolContext.customerNumber = 'CUST-001';

    AgentToolResult result = new GetMyCasesTool()
      .run(
        new Map<String, Object>{
          'customerNumber' => 'CUST-002',
          'accountNumber' => 'CUST-002'
        }
      );

    System.assert(result.success, result.message);
    List<Case> records = (List<Case>) result.data.get('records');
    System.assertEquals(1, records.size());
    System.assertEquals('Mine', records[0].Subject, 'Argument must not override the bound customer');
  }

  @IsTest
  static void testFailsClosedWhenNoCustomerBound() {
    AgentToolContext.customerNumber = null;

    AgentToolResult result = new GetMyCasesTool().run(new Map<String, Object>());

    System.assertEquals(false, result.success, 'Must fail closed with no customer bound');
    System.assertEquals(null, result.data);
  }

  @IsTest
  static void testFailsClosedWhenCustomerBlank() {
    AgentToolContext.customerNumber = '   ';

    AgentToolResult result = new GetMyCasesTool().run(new Map<String, Object>());

    System.assertEquals(false, result.success);
  }
}
