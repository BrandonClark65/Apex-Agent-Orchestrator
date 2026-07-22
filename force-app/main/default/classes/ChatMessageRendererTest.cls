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

  @IsTest
  static void testFinalStructuredDataExposedAlongsideMessage() {
    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('user', 'Where is my order?'),
      new LLMMessage(
        'assistant',
        '{"final":{"message":"It ships Thursday.","orderId":"801xx","status":"shipped"}}'
      )
    };

    List<ChatMessageRenderer.View> views = ChatMessageRenderer.render(history, false);

    System.assertEquals(2, views.size());
    ChatMessageRenderer.View answer = views[1];
    System.assertEquals('assistant', answer.role);
    // Prose stays as the bubble text...
    System.assertEquals('It ships Thursday.', answer.text);
    // ...and the remaining keys ride alongside as structured data.
    System.assertNotEquals(null, answer.data, 'structured payload should be exposed');
    System.assertEquals('801xx', answer.data.get('orderId'));
    System.assertEquals('shipped', answer.data.get('status'));
    System.assert(
      !answer.data.containsKey('message'),
      'message stays in text, not duplicated into data'
    );
  }

  @IsTest
  static void testFinalMessageOnlyHasNoData() {
    List<LLMMessage> history = new List<LLMMessage>{
      new LLMMessage('assistant', '{"final":{"message":"Done."}}')
    };

    List<ChatMessageRenderer.View> views = ChatMessageRenderer.render(history, false);

    System.assertEquals(1, views.size());
    System.assertEquals('Done.', views[0].text);
    System.assertEquals(
      null,
      views[0].data,
      'a message-only final answer exposes no structured payload'
    );
  }
}
