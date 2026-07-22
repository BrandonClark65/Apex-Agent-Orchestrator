/**
 * @description Tests `ChatMessageRenderer`, focusing on the customer-facing vs in-org projection:
 * the same history renders tool-activity chips for the monitoring view but only the human's
 * messages and the agent's final answer for an external customer.
 * @group Tests
 */
@IsTest
private class ChatMessageRendererTest {
  // A representative one-turn history: user asks, agent calls a tool, tool returns, agent answers.
  private static List<LLMMessage> sampleHistory() {
    return new List<LLMMessage>{
      new LLMMessage('system', 'you are an agent'),
      new LLMMessage('user', 'How many open opportunities are there?'),
      new LLMMessage(
        'assistant',
        '{"tool":"QuerySalesforceTool","args":{"query":"SELECT COUNT() FROM Opportunity"}}'
      ),
      new LLMMessage(
        'assistant',
        '{"tool":"QuerySalesforceTool","output":{"success":true,"message":"5 rows"}}'
      ),
      new LLMMessage('user', '{"instruction":"decide next step"}'),
      new LLMMessage('assistant', '{"final":{"message":"You have 5 open opportunities."}}')
    };
  }

  @IsTest
  static void testInOrgRenderShowsToolChips() {
    List<ChatMessageRenderer.View> views = ChatMessageRenderer.render(
      sampleHistory()
    );

    // user, tool chip, tool chip, final answer — instruction dropped, system dropped.
    System.assertEquals(4, views.size());
    System.assertEquals('user', views[0].role);
    System.assertEquals('tool', views[1].role);
    System.assertEquals('QuerySalesforceTool', views[1].toolName);
    System.assertEquals('tool', views[2].role);
    System.assertEquals('assistant', views[3].role);
    System.assertEquals('You have 5 open opportunities.', views[3].text);
  }

  @IsTest
  static void testCustomerRenderHidesToolsAndThinking() {
    List<ChatMessageRenderer.View> views = ChatMessageRenderer.render(
      sampleHistory(),
      false
    );

    // Only the human's message and the agent's final answer survive.
    System.assertEquals(2, views.size());
    System.assertEquals('user', views[0].role);
    System.assertEquals(
      'How many open opportunities are there?',
      views[0].text
    );
    System.assertEquals('assistant', views[1].role);
    System.assertEquals('You have 5 open opportunities.', views[1].text);
    for (ChatMessageRenderer.View v : views) {
      System.assertNotEquals('tool', v.role, 'No tool activity should be exposed to customers');
    }
  }
}
