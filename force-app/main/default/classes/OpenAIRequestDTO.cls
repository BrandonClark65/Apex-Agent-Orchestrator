/**
 * @description Wire shape for OpenAI's chat completions request body. Field names are
 * snake_case to match the API's JSON keys directly on serialization via `JSON.serialize`.
 * Built and populated by `OpenAIClient.complete` from an `LLMRequest`.
 * @group LLM Integration
 */
public with sharing class OpenAIRequestDTO {
  public String model;
  public List<LLMMessage> messages;
  public Integer max_tokens;
  public Decimal temperature;
  public Map<String, String> response_format;
}
