@IsTest
public class LLMClientMock implements LLMClient {

    private List<String> responses = new List<String>();
    private Integer index = 0;

    public void addResponse(String json) {
        responses.add(json);
    }

    public LLMResponse complete(LLMRequest request) {
        if (index >= responses.size()) {
            throw new AgentException('No more mock responses available.');
        }

        String text = responses[index++];
        return new LLMResponse(text, text);
    }
}
