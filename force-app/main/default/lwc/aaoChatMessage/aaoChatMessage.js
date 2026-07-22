import { LightningElement, api } from "lwc";

/**
 * Renders one chat entry. `message` is an AgentChatController.ChatMessage DTO:
 * role 'user' | 'assistant' | 'tool' (tool = collapsed activity chip).
 */
export default class AaoChatMessage extends LightningElement {
  @api message;

  get isUser() {
    return this.message?.role === "user";
  }

  get isAssistant() {
    return this.message?.role === "assistant";
  }

  get isTool() {
    return this.message?.role === "tool";
  }

  get toolLabel() {
    return `Used ${this.message?.toolName}`;
  }

  // The agent's final answer can carry structured data next to the prose (every `final` key
  // except `message`). Present it as a labelled key/value list beneath the answer bubble.
  get hasData() {
    const data = this.message?.data;
    return this.isAssistant && !!data && Object.keys(data).length > 0;
  }

  get dataEntries() {
    const data = this.message?.data || {};
    return Object.keys(data).map((key) => {
      const raw = data[key];
      return {
        key,
        value:
          raw !== null && typeof raw === "object"
            ? JSON.stringify(raw)
            : String(raw)
      };
    });
  }

  get bubbleClass() {
    return this.isUser
      ? "slds-chat-message__text slds-chat-message__text_outbound bubble"
      : "slds-chat-message__text slds-chat-message__text_inbound bubble";
  }

  get listItemClass() {
    return this.isUser
      ? "slds-chat-listitem slds-chat-listitem_outbound"
      : "slds-chat-listitem slds-chat-listitem_inbound";
  }
}
