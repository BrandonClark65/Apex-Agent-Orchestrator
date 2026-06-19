// Check the LLM client
LLMClient client = LLMClientFactory.forProvider('OpenAI_GPT4');

LLMRequest req = new LLMRequest();
req.messages.add(new LLMMessage('user', 'Say hello from Salesforce'));

LLMResponse res = client.complete(req);

System.debug(res.text);


//Check the raw API call
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:OpenAI_NC/v1/chat/completions');
req.setMethod('POST');
req.setHeader('Content-Type', 'application/json');
req.setBody('{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}');

Http http = new Http();
HttpResponse res = http.send(req);

System.debug(res.getBody());

// Run a test agent
Id runId = AgentEngine.runAgent(
    'Test_Agent', 
    '{"task": "Find all Accounts in Portland"}',
    'Apex'
);

System.debug('Agent Run Id: ' + runId);

