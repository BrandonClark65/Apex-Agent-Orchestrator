/**
 * @description Typed shape mirroring OpenAI's chat completions response body. Not currently
 * used by `OpenAIClient`, which parses responses with `JSON.deserializeUntyped` instead to
 * avoid truncation issues with the typed deserializer; kept here as a reference shape for the
 * response schema.
 * @group LLM Integration
 */
public class OpenAIResponseDTO {
  public List<Choice> choices;
  public Usage usage;

  public class Choice {
    public Integer index;
    public Message message;
    public String finish_reason;
  }

  public class Message {
    public String role;
    public String content;
  }

  public class Usage {
    public Integer prompt_tokens;
    public Integer completion_tokens;
    public Integer total_tokens;
  }
}
