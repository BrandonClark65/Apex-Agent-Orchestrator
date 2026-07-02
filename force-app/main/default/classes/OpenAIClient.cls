public with sharing class OpenAIClient implements LLMClient {

    private aao__LLM_Provider__mdt provider;

    public OpenAIClient(aao__LLM_Provider__mdt provider) {
        this.provider = provider;
    }

    public LLMResponse complete(LLMRequest request) {
        
        Http http = new Http();
        HttpRequest req = new HttpRequest();

        req.setEndpoint('callout:' + provider.aao__Named_Credential__c + provider.aao__API_Endpoint__c);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');

        if (request.maxTokens == null) {
            request.maxTokens = provider.aao__MaxTokens__c != null
                ? Integer.valueOf(provider.aao__MaxTokens__c)
                : 2048; // safe fallback
        }
        if (request.temperature == null) {
            request.temperature = provider.aao__Temperature__c != null
                ? provider.aao__Temperature__c
                : 0.0; // safe default for agents
        }



        OpenAIRequestDTO dto = new OpenAIRequestDTO();
        if (provider.aao__Model_Name__c != null) {
            dto.model = provider.aao__Model_Name__c;
        }
        dto.messages = request.messages;
        dto.max_tokens = request.maxTokens;
        dto.temperature = request.temperature;
        dto.response_format = new Map<String, String>{ 'type' => 'json_object' };

        req.setBody(JSON.serialize(dto));
        req.setTimeout(120000); // 120s — large parallel contexts can be slow

        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new AgentException('OpenAI API error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        // Use deserializeUntyped so large `content` strings are never truncated or
        // silently nulled by the typed deserializer.
        Map<String, Object> rawBody = (Map<String, Object>)JSON.deserializeUntyped(res.getBody());

        List<Object> choiceList = (List<Object>)rawBody.get('choices');
        if (choiceList == null || choiceList.isEmpty()) {
            throw new AgentException('OpenAI returned no choices in response: ' + res.getBody());
        }
        Map<String, Object> choice = (Map<String, Object>)choiceList[0];

        String finishReason = (String)choice.get('finish_reason');
        if ('length'.equals(finishReason)) {
            Map<String, Object> rawUsage = (Map<String, Object>)rawBody.get('usage');
            Integer used = rawUsage != null ? Integer.valueOf(rawUsage.get('total_tokens')) : -1;
            throw new AgentException(
                'LLM response was truncated (finish_reason=length). ' +
                'Total tokens used: ' + used + '. ' +
                'Increase MaxTokens__c in the LLM_Provider__mdt record or reduce context size.'
            );
        }

        Map<String, Object> message = (Map<String, Object>)choice.get('message');
        String text = message != null ? (String)message.get('content') : null;

        LLMResponse response = new LLMResponse(text, res.getBody());

        Map<String, Object> rawUsage = (Map<String, Object>)rawBody.get('usage');
        if (rawUsage != null) {
            response.promptTokens = Integer.valueOf(rawUsage.get('prompt_tokens'));
            response.completionTokens = Integer.valueOf(rawUsage.get('completion_tokens'));
            response.totalTokens = Integer.valueOf(rawUsage.get('total_tokens'));
        }

        return response;
    }
}