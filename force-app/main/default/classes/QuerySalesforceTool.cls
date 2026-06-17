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
                return new AgentToolResult(false, 'Missing SOQL query', null);
            }

            List<SObject> results = Database.query(soql);

            Map<String, Object> data = new Map<String, Object>{
                'records' => results
            };

            return new AgentToolResult(true, 'Query executed successfully', data);

        } catch (Exception e) {
            return new AgentToolResult(false, e.getMessage(), null);
        }
    }
}
