public with sharing class LLMRequest {
    public List<LLMMessage> messages = new List<LLMMessage>();
    public Integer maxTokens;
    public Decimal temperature;

    public LLMRequest() {}

    public LLM Request(String userPrompt){
        messages.add(new LLMMessage('user', userPrompt));
    }
}