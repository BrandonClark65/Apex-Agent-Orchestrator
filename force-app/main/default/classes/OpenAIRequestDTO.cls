public with sharing class OpenAIRequestDTO {
    public String model;
    public List<LLMMessage> messages;
    public Integer max_tokens;
    public Decimal temperature;
}
