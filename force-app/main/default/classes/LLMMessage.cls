public with sharing class LLMMessage {
    public String role;
    public String content;

    public LLMMessage() {
    }

    public LLMMessage(String role, String content) {
        this.role = role;
        this.content = content;
    }
}