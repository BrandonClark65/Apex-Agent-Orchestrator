public with sharing class LLMResponse {
    public String text;
    public String rawResponse;
    public Integer promptTokens;
    public Integer completionTokens;
    public Integer totalTokens;

    public LLMResponse(String text, String rawResponse) {
        this.text = text;
        this.rawResponse = rawResponse;
    }
}