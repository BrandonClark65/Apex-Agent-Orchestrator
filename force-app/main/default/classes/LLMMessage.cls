/**
 * @description One turn in an LLM conversation (`'system'`, `'user'`, or `'assistant'` role
 * plus content). `AgentEngine` accumulates a `List<LLMMessage>` as an agent run's history,
 * persists it to `Agent_Run__c.History_Json__c` between async steps, and passes it as
 * `LLMRequest.messages` on each LLM call.
 * @group LLM Integration
 */
public with sharing class LLMMessage {
  public String role;
  public String content;

  /**
   * @description No-argument constructor required for `JSON.deserialize` into `LLMMessage`.
   */
  public LLMMessage() {
  }

  /**
   * @description Constructs a message with the given role and content.
   * @param role 'system', 'user', or 'assistant'.
   * @param content Message text, typically a JSON string per the agent's response contract.
   */
  public LLMMessage(String role, String content) {
    this.role = role;
    this.content = content;
  }
}
