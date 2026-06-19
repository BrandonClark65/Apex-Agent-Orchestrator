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

        OpenAIRequestDTO dto = new OpenAIRequestDTO();
        dto.model = provider.aao__Model_Name__c;
        dto.messages = request.messages;
        dto.max_tokens = request.maxTokens;
        dto.temperature = request.temperature;

        req.setBody(JSON.serialize(dto));

        HttpResponse res = http.send(req);

        OpenAIResponseDTO parsed = (OpenAIResponseDTO)JSON.deserialize(res.getBody(), OpenAIResponseDTO.class);

        String text = parsed.choices != null && parsed.choices.size() > 0
            ? parsed.choices[0].message.content
            : null;

        LLMResponse response = new LLMResponse(text, res.getBody());

        if (parsed.usage != null) {
            response.promptTokens = parsed.usage.prompt_tokens;
            response.completionTokens = parsed.usage.completion_tokens;
            response.totalTokens = parsed.usage.total_tokens;
        }

        return response;
    }
}