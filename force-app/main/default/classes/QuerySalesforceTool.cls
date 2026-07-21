/**
 * @description Runs an arbitrary SOQL query supplied by the LLM and returns the matching
 * records as JSON. The query executes in user mode (`AccessLevel.USER_MODE`), so results are
 * filtered by the running user's full permission model — record sharing, object read (CRUD),
 * and field-level security (FLS). A query touching an object or field the user cannot read
 * throws, and is returned to the model as an error rather than leaking inaccessible data.
 * @group Agent Tools
 */
public with sharing class QuerySalesforceTool implements AgentTool {
  public String getName() {
    return 'QuerySalesforce';
  }

  public String getDescription() {
    return 'Runs a SOQL query and returns the results as JSON.';
  }

  /**
   * @description Executes the supplied SOQL query. Strips any trailing `}` characters the
   * LLM occasionally leaks from the surrounding tool-call JSON into the query string, since
   * SOQL never legitimately ends with `}`.
   * @param args Must contain `query` (a SOQL string).
   * @return Success result containing a records list of the query's matching sObjects.
   */
  public AgentToolResult run(Map<String, Object> args) {
    try {
      String soql = (String) args.get('query');
      if (String.isBlank(soql)) {
        return AgentToolResult.error('Missing SOQL query');
      }

      // Strip trailing JSON artifact braces — the LLM occasionally includes
      // the JSON structure's closing '}' inside the query string value.
      // SOQL never legitimately ends with '}', so this is always safe to trim.
      soql = soql.trim();
      while (soql.endsWith('}')) {
        soql = soql.removeEnd('}').trim();
      }

      List<SObject> results = Database.query(soql, AccessLevel.USER_MODE);

      Map<String, Object> data = new Map<String, Object>{
        'records' => results
      };

      return AgentToolResult.success('Query executed successfully', data);
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
