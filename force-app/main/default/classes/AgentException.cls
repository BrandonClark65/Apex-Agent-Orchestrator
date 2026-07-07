/**
 * @description Generic checked-style exception thrown by engine and provider code
 * (e.g. `ToolRegistry`, `LLMClientFactory`, `OpenAIClient`) for configuration and
 * resolution failures — missing metadata records, unresolvable tool/provider classes, etc.
 * @group Agent Engine
 */
public class AgentException extends Exception {
}
