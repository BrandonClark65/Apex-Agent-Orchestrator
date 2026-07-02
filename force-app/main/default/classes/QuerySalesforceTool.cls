public with sharing class QuerySalesforceTool implements AgentTool {

    public String getName() {
        return 'QuerySalesforce';
    }

    public String getDescription() {
        return 'Runs a SOQL query and returns the results as JSON.';
    }

    public AgentToolResult run(Map<String, Object> args) {
        try {
            String soql = (String)args.get('query');
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

            List<SObject> results = Database.query(soql);

            Map<String, Object> data = new Map<String, Object>{
                'records' => results
            };

            return AgentToolResult.success('Query executed successfully', data);

        } catch (Exception e) {
            return AgentToolResult.error(e.getMessage());
        }
    }
}
