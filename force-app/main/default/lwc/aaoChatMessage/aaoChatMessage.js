import { LightningElement, api } from 'lwc';

/**
 * Renders one chat entry. `message` is an AgentChatController.ChatMessage DTO:
 * role 'user' | 'assistant' | 'tool' (tool = collapsed activity chip).
 */
export default class AaoChatMessage extends LightningElement {
    @api message;

    get isUser() {
        return this.message?.role === 'user';
    }

    get isAssistant() {
        return this.message?.role === 'assistant';
    }

    get isTool() {
        return this.message?.role === 'tool';
    }

    get toolLabel() {
        return `Used ${this.message?.toolName}`;
    }

    get bubbleClass() {
        return this.isUser
            ? 'slds-chat-message__text slds-chat-message__text_outbound bubble'
            : 'slds-chat-message__text slds-chat-message__text_inbound bubble';
    }

    get listItemClass() {
        return this.isUser
            ? 'slds-chat-listitem slds-chat-listitem_outbound'
            : 'slds-chat-listitem slds-chat-listitem_inbound';
    }
}
