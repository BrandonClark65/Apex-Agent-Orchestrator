/**
 * @description Record-scoped tool for a customer-facing external chat: returns the active cases
 * belonging to the one customer the current session is bound to, and nothing else.
 *
 * Security model — the customer identity is bound server-side, not by the model. The tool takes
 * NO customer identifier as an argument (its input schema is empty), so there is nothing for the
 * LLM (or a customer typing into chat) to spoof. It reads the authenticated customer number from
 * `AgentToolContext.customerNumber` — stamped onto `Agent_Session__c.Customer_Number__c` at
 * session creation from a trusted caller — and hard-filters on it with a bind variable, so the
 * `WHERE` clause cannot be widened by anything the model produces. If no customer is bound, the
 * tool fails closed (returns an error) rather than returning unscoped data.
 *
 * The query also runs `WITH USER_MODE`, so the integration user's CRUD/FLS/sharing still applies
 * as defense in depth. Grant that user the least access these customer-facing tools need.
 *
 * This maps "customer number" to the standard `Account.AccountNumber`; adapt the field to your
 * own customer-identifier schema (a custom field, an external Id, etc.) if it differs.
 * @group Agent Tools
 */
public with sharing class GetMyCasesTool implements AgentTool {
  public String getName() {
    return 'GetMyCases';
  }

  public String getDescription() {
    return 'Returns the current customer\'s active (open) cases. Takes no arguments; ' +
      'the customer is determined from the authenticated session.';
  }

  /**
   * @description Returns the bound customer's open cases. Ignores any arguments — the customer
   * is never supplied by the caller or the model.
   * @param args Unused. The customer is resolved from `AgentToolContext.customerNumber`.
   * @return Success with a `records` list of open cases, or an error if no customer is bound.
   */
  public AgentToolResult run(Map<String, Object> args) {
    String customerNumber = AgentToolContext.customerNumber;
    if (String.isBlank(customerNumber)) {
      // Fail closed: without a bound customer we must not return any records.
      return AgentToolResult.error(
        'This chat is not linked to a customer account, so cases cannot be retrieved.'
      );
    }

    try {
      List<Case> cases = [
        SELECT CaseNumber, Subject, Status, Priority, CreatedDate
        FROM Case
        WHERE Account.AccountNumber = :customerNumber AND IsClosed = FALSE
        WITH USER_MODE
        ORDER BY CreatedDate DESC
        LIMIT 200
      ];

      return AgentToolResult.success(
        'Found ' + cases.size() + ' open case(s).',
        new Map<String, Object>{ 'records' => cases }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
