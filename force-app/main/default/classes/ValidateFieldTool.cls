public with sharing class ValidateFieldTool implements AgentTool {

    public String getName() {
        return 'ValidateFieldTool';
    }

    public String getDescription() {
        return 'Validates a field on an sObject and returns the correct API name, label, and updateability.';
    }

    public AgentToolResult run(Map<String, Object> args) {
        try {
            String objectName = (String) args.get('object');
            String userField = (String) args.get('field');

            Schema.SObjectType typeRef = Schema.getGlobalDescribe().get(objectName);
            if (typeRef == null) {
                return AgentToolResult.error('Object not found: ' + objectName);
            }

            Map<String, Schema.SObjectField> fields = typeRef.getDescribe().fields.getMap();

            // Exact match
            if (fields.containsKey(userField)) {
                Schema.DescribeFieldResult f = fields.get(userField).getDescribe();
                return AgentToolResult.success('Field found', new Map<String, Object>{
                    'exists' => true,
                    'apiName' => userField,
                    'label' => f.getLabel(),
                    'updateable' => f.isUpdateable()
                });
            }

            // Fuzzy match (label or close API name)
            String bestMatch;
            Integer bestScore = 999;

            for (String apiName : fields.keySet()) {
                Schema.DescribeFieldResult f = fields.get(apiName).getDescribe();
                Integer score = levenshtein(userField.toLowerCase(), f.getLabel().toLowerCase());

                if (score < bestScore) {
                    bestScore = score;
                    bestMatch = apiName;
                }
            }

            if (bestMatch != null) {
                Schema.DescribeFieldResult f = fields.get(bestMatch).getDescribe();
                return AgentToolResult.success('Fuzzy match found', new Map<String, Object>{
                    'exists' => true,
                    'apiName' => bestMatch,
                    'label' => f.getLabel(),
                    'updateable' => f.isUpdateable(),
                    'fuzzyMatch' => true
                });
            }

            return AgentToolResult.error('No matching field found');

        } catch (Exception e) {
            return AgentToolResult.error(e.getMessage());
        }
    }

    // Simple Levenshtein implementation
    private Integer levenshtein(String a, String b) {
        Integer lenA = a.length();
        Integer lenB = b.length();

        // Initialize 2D list
        List<List<Integer>> dp = new List<List<Integer>>();
        for (Integer i = 0; i <= lenA; i++) {
            List<Integer> row = new List<Integer>();
            for (Integer j = 0; j <= lenB; j++) {
                row.add(0);
            }
            dp.add(row);
        }

        // Initialize first row/column
        for (Integer i = 0; i <= lenA; i++) dp[i][0] = i;
        for (Integer j = 0; j <= lenB; j++) dp[0][j] = j;

        // Fill matrix
        for (Integer i = 1; i <= lenA; i++) {
            for (Integer j = 1; j <= lenB; j++) {
                Integer cost = (a.substring(i - 1, i) == b.substring(j - 1, j)) ? 0 : 1;

                dp[i][j] = Math.min(
                    Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
                    dp[i - 1][j - 1] + cost
                );
            }
        }

        return dp[lenA][lenB];
    }

}
