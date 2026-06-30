@IsTest
private class CreateRecordToolTest {

    @IsTest
    static void testGetNameAndDescription() {
        CreateRecordTool tool = new CreateRecordTool();
        System.assertEquals('CreateRecordTool', tool.getName());
        System.assertEquals('Bulk-creates Salesforce records of any object type.', tool.getDescription());
    }

    @IsTest
    static void testCreateSingleRecord() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account',
            'records' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'Name' => 'Test Account' }
                }
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        System.assertEquals(1, results.size());
        Map<String, Object> r = (Map<String, Object>) results[0];
        System.assertEquals(true, r.get('success'));
        System.assertNotEquals(null, r.get('id'));
        System.assertEquals('Created successfully', r.get('message'));
    }

    @IsTest
    static void testCreateMultipleRecords() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account',
            'records' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'Name' => 'Account Alpha' }
                },
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'Name' => 'Account Beta' }
                }
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        System.assertEquals(2, results.size());
        for (Object o : results) {
            Map<String, Object> r = (Map<String, Object>) o;
            System.assertEquals(true, r.get('success'));
            System.assertNotEquals(null, r.get('id'));
        }

        System.assertEquals(2, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void testMissingObjectArg() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'records' => new List<Object>{}
        });

        System.assertEquals(false, result.success);
        System.assertEquals('Missing object or records list', result.message);
    }

    @IsTest
    static void testMissingRecordsArg() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account'
        });

        System.assertEquals(false, result.success);
        System.assertEquals('Missing object or records list', result.message);
    }

    @IsTest
    static void testUnknownObject() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'FakeObject__zzzz',
            'records' => new List<Object>{}
        });

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('Object not found'));
    }

    @IsTest
    static void testMissingFields() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account',
            'records' => new List<Object>{
                new Map<String, Object>() // no 'fields' key
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        Map<String, Object> r = (Map<String, Object>) results[0];
        System.assertEquals(false, r.get('success'));
        System.assertEquals('Missing fields', r.get('message'));
        System.assertEquals(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void testInvalidFieldName() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account',
            'records' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'NotARealField__xyz' => 'value' }
                }
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        Map<String, Object> r = (Map<String, Object>) results[0];
        System.assertEquals(false, r.get('success'));
        System.assert(((String) r.get('message')).startsWith('Invalid field'));
    }

    @IsTest
    static void testNonCreateableField() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account',
            'records' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'CreatedDate' => '2024-01-01' }
                }
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        Map<String, Object> r = (Map<String, Object>) results[0];
        System.assertEquals(false, r.get('success'));
        System.assert(((String) r.get('message')).contains('not createable'));
    }

    @IsTest
    static void testPartialSuccess() {
        CreateRecordTool tool = new CreateRecordTool();

        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Account',
            'records' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'Name' => 'Valid Account' }
                },
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'NotARealField__xyz' => 'value' }
                }
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        System.assertEquals(2, results.size());

        Map<String, Object> good = (Map<String, Object>) results[0];
        System.assertEquals(true, good.get('success'));
        System.assertNotEquals(null, good.get('id'));

        Map<String, Object> bad = (Map<String, Object>) results[1];
        System.assertEquals(false, bad.get('success'));
        System.assertEquals(null, bad.get('id'));

        System.assertEquals(1, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void testDmlFailure() {
        CreateRecordTool tool = new CreateRecordTool();

        // Contact.LastName is required; omitting it triggers a DML error
        AgentToolResult result = tool.run(new Map<String, Object>{
            'object' => 'Contact',
            'records' => new List<Object>{
                new Map<String, Object>{
                    'fields' => new Map<String, Object>{ 'FirstName' => 'NeedsLastName' }
                }
            }
        });

        System.assert(result.success, result.message);
        List<Object> results = (List<Object>) result.data.get('results');
        Map<String, Object> r = (Map<String, Object>) results[0];
        System.assertEquals(false, r.get('success'));
        System.assertNotEquals(null, r.get('message'));
        System.assertEquals(0, [SELECT COUNT() FROM Contact]);
    }
}
