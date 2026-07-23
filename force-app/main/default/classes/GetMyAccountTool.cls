/**
 * @description Record-scoped tool for a customer-facing external chat: returns summary details of
 * the one customer account the current session is bound to. Companion to `GetMyCasesTool` showing
 * the same pattern for a second record type ("cases / other records").
 *
 * Same security model as `GetMyCasesTool`: takes NO customer identifier as an argument, reads the
 * authenticated customer number from `AgentToolContext.customerNumber` (bound server-side at
 * session creation, never from the model), hard-filters on it with a bind variable, runs
 * `WITH USER_MODE`, and fails closed when no customer is bound.
 * @group Agent Tools
 */
public with sharing class GetMyAccountTool implements AgentTool {
  public String getName() {
    return 'GetMyAccount';
  }

  public String getDescription() {
    return 'Returns summary details of the current customer\'s own account. Takes no ' +
      'arguments; the customer is determined from the authenticated session.';
  }

  /**
   * @description Returns the bound customer's account record. Ignores any arguments.
   * @param args Unused. The customer is resolved from `AgentToolContext.customerNumber`.
   * @return Success with a `records` list holding the customer's account, or an error if no
   * customer is bound.
   */
  public AgentToolResult run(Map<String, Object> args) {
    String customerNumber = AgentToolContext.customerNumber;
    if (String.isBlank(customerNumber)) {
      return AgentToolResult.error(
        'This chat is not linked to a customer account, so account details cannot be retrieved.'
      );
    }

    try {
      List<Account> accounts = [
        SELECT Name, AccountNumber, Type, Phone, Industry
        FROM Account
        WHERE AccountNumber = :customerNumber
        WITH USER_MODE
        LIMIT 1
      ];

      if (accounts.isEmpty()) {
        return AgentToolResult.success(
          'No account found for this customer.',
          new Map<String, Object>{ 'records' => accounts }
        );
      }

      return AgentToolResult.success(
        'Account details retrieved.',
        new Map<String, Object>{ 'records' => accounts }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
