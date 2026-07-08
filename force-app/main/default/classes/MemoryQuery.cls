/**
 * @description Parameters for one recall: which agent/user/session is asking, the query
 * text to rank against, how many memories to return, and which scopes to search.
 * @group Memory
 */
public with sharing class MemoryQuery {
  public String agentDeveloperName;
  public Id userId;
  public Id sessionId;
  public String queryText;
  public Integer maxItems = 10;
  public List<String> scopes = new List<String>{ 'User', 'Agent', 'Global' };
}
