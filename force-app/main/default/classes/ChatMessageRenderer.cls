/**
 * @description Renders engine conversation history (`List<LLMMessage>`) into displayable chat
 * entries, shared by every surface that shows a conversation: the `aaoAgentChat` LWC (via
 * `AgentChatController`) and the external REST API (`AgentChatApi`). Keeping the projection in
 * one place is what lets an outside-Salesforce chatbot render byte-identically to the in-org UI.
 *
 * History shapes handled: user messages are either real user text or engine `{"instruction":...}`
 * steering prompts (skipped); assistant messages are the model contract (`final` -> answer
 * bubble, `tool`/`tools` -> "calling tool" chips) or the engine's tool-output wrapper
 * (`{"tool":...,"output":...}` -> tool-result chip).
 * @group UI
 */
public with sharing class ChatMessageRenderer {
  /** @description One rendered chat entry: `role` is `user`, `assistant`, or `tool` (activity chip). */
  public class View {
    public String role;
    public String text;
    public String toolName;
    // Structured payload that rode alongside the agent's final answer: every key of the `final`
    // object other than `message` (which becomes `text`). Null unless the final answer carried
    // extra keys. Lets a client render cards/links/buttons without the prose showing raw JSON.
    public Map<String, Object> data;
  }

  /**
   * @description Projects engine history into displayable chat entries with tool activity
   * shown (the in-org default), dropping system and engine-injected instruction messages.
   * @param history Conversation history as stored on the run/session.
   * @return Ordered chat entries ready for display or JSON serialization.
   */
  public static List<View> render(List<LLMMessage> history) {
    return render(history, true);
  }

  /**
   * @description Projects engine history into displayable chat entries.
   * @param history Conversation history as stored on the run/session.
   * @param includeToolActivity When true, tool calls/outputs render as `tool` activity chips
   * (in-org monitoring view). When false, only the human's messages and the agent's final
   * answers are kept — the tool orchestration and intermediate "thinking" are hidden, for a
   * customer-facing surface that shouldn't expose how the answer was produced.
   * @return Ordered chat entries ready for display or JSON serialization.
   */
  public static List<View> render(
    List<LLMMessage> history,
    Boolean includeToolActivity
  ) {
    List<View> messages = new List<View>();
    if (history == null) {
      return messages;
    }

    for (LLMMessage msg : history) {
      if (msg.role == 'system' || String.isBlank(msg.content)) {
        continue;
      }

      Map<String, Object> parsed = tryParseObject(msg.content);

      if (msg.role == 'user') {
        if (parsed != null && parsed.containsKey('instruction')) {
          continue; // engine-injected steering prompt, not the human
        }
        messages.add(entry('user', msg.content, null));
        continue;
      }

      // The agent's final answer is the only assistant content a customer sees.
      if (parsed != null && parsed.containsKey('final')) {
        Map<String, Object> finalResult = (Map<String, Object>) parsed.get('final');
        View answer = entry('assistant', extractFinalText(finalResult), null);
        answer.data = structuredPayload(finalResult);
        messages.add(answer);
        continue;
      }

      // Everything else on the assistant side is tool orchestration / intermediate
      // "thinking". Customer-facing surfaces drop it; the in-org view shows tool chips.
      if (!includeToolActivity) {
        continue;
      }

      if (parsed == null) {
        messages.add(entry('assistant', msg.content, null));
      } else if (parsed.containsKey('output')) {
        messages.add(entry('tool', null, String.valueOf(parsed.get('tool'))));
      } else if (parsed.containsKey('tool')) {
        messages.add(entry('tool', null, String.valueOf(parsed.get('tool'))));
      } else if (parsed.containsKey('tools')) {
        for (Object callObj : (List<Object>) parsed.get('tools')) {
          Map<String, Object> call = (Map<String, Object>) callObj;
          messages.add(entry('tool', null, String.valueOf(call.get('tool'))));
        }
      } else {
        messages.add(entry('assistant', msg.content, null));
      }
    }
    return messages;
  }

  // Soft contract with demo agent prompts: `final.message` carries the human-readable answer;
  // anything else falls back to the serialized final object.
  private static String extractFinalText(Map<String, Object> finalResult) {
    if (finalResult.containsKey('message')) {
      return String.valueOf(finalResult.get('message'));
    }
    return JSON.serializePretty(finalResult);
  }

  // The structured half of the final answer: every key except `message` (already the bubble
  // text). Returned so a client can act on the data without the prose becoming raw JSON.
  // Null when the final answer is message-only, or has no `message` at all (in which case the
  // whole object is already shown as the bubble text via extractFinalText).
  private static Map<String, Object> structuredPayload(Map<String, Object> finalResult) {
    if (!finalResult.containsKey('message')) {
      return null;
    }
    Map<String, Object> rest = new Map<String, Object>(finalResult);
    rest.remove('message');
    return rest.isEmpty() ? null : rest;
  }

  private static Map<String, Object> tryParseObject(String content) {
    try {
      Object raw = JSON.deserializeUntyped(content);
      return raw instanceof Map<String, Object>
        ? (Map<String, Object>) raw
        : null;
    } catch (Exception e) {
      return null;
    }
  }

  private static View entry(String role, String text, String toolName) {
    View v = new View();
    v.role = role;
    v.text = text;
    v.toolName = toolName;
    return v;
  }
}
