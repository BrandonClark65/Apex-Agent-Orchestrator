/**
 * @description SOQL-backed `MemoryProvider`: recalls active, unexpired `Agent_Memory__c`
 * rows in the requested scopes and ranks them by keyword overlap with the query text,
 * breaking ties by access count then recency. Callout-free, so it is safe in every
 * engine context. Recalled rows get `Access_Count__c`/`Last_Accessed__c` bumped
 * best-effort for future ranking and pruning — deferred rather than written inline (see
 * `flushAccessBookkeeping`), since `recall` runs from `AgentEngine.runLLMStep` before its
 * own LLM callout, and Salesforce forbids callouts once a transaction has uncommitted DML.
 * @group Memory
 */
public with sharing class SalesforceMemoryProvider implements MemoryProvider {
  // How many candidates to load before ranking client-side.
  private static final Integer CANDIDATE_LIMIT = 200;

  // Transaction-scoped queue of access-count bumps from `recall` calls so far, flushed by
  // `flushAccessBookkeeping` only once every callout for the transaction is done.
  @TestVisible
  private static List<Agent_Memory__c> pendingAccessBookkeeping = new List<Agent_Memory__c>();

  /**
   * @description See `MemoryProvider.recall`.
   * @param query Who is asking and what about.
   * @return Ranked memories, at most `query.maxItems`.
   */
  public List<MemoryRecord> recall(MemoryQuery query) {
    // Semi-joins aren't allowed inside nested WHERE clauses, so resolve the session's
    // run Ids up front for Session-scoped recall.
    Set<Id> sessionRunIds = new Set<Id>();
    if (query.sessionId != null && query.scopes.contains('Session')) {
      for (aao__Agent_Run__c run : [
        SELECT Id
        FROM aao__Agent_Run__c
        WHERE Session__c = :query.sessionId
      ]) {
        sessionRunIds.add(run.Id);
      }
    }

    List<Agent_Memory__c> candidates = [
      SELECT
        Id,
        Agent__c,
        User__c,
        Scope__c,
        Type__c,
        Content__c,
        Keywords__c,
        Source_Run__c,
        Access_Count__c,
        Last_Accessed__c
      FROM Agent_Memory__c
      WHERE
        Is_Active__c = TRUE
        AND (Expires_At__c = NULL
        OR Expires_At__c > :System.now())
        AND Scope__c IN :query.scopes
        AND (Scope__c = 'Global'
        OR (Scope__c = 'Agent'
        AND Agent__c = :query.agentDeveloperName)
        OR (Scope__c = 'User'
        AND User__c = :query.userId)
        OR (Scope__c = 'Session'
        AND Source_Run__c IN :sessionRunIds))
      ORDER BY Last_Accessed__c DESC NULLS LAST
      LIMIT :CANDIDATE_LIMIT
    ];

    Set<String> queryTokens = tokenize(query.queryText);
    List<Ranked> ranked = new List<Ranked>();
    for (Agent_Memory__c row : candidates) {
      Ranked r = new Ranked();
      r.row = row;
      r.score = overlapScore(queryTokens, row);
      ranked.add(r);
    }
    ranked.sort();

    Integer maxItems = query.maxItems == null ? 10 : query.maxItems;
    List<MemoryRecord> results = new List<MemoryRecord>();
    List<Agent_Memory__c> touched = new List<Agent_Memory__c>();
    for (Ranked r : ranked) {
      if (results.size() >= maxItems) {
        break;
      }
      results.add(MemoryRecord.fromSObject(r.row));
      touched.add(
        new Agent_Memory__c(
          Id = r.row.Id,
          Access_Count__c = (r.row.Access_Count__c == null
            ? 0
            : r.row.Access_Count__c) + 1,
          Last_Accessed__c = System.now()
        )
      );
    }

    pendingAccessBookkeeping.addAll(touched);
    return results;
  }

  /**
   * @description Writes the access-count/last-accessed bumps queued by `recall` calls so
   * far in this transaction. Safe to call only once every callout for the current
   * transaction has already completed — it performs DML, and Salesforce forbids callouts
   * afterward. No-ops when nothing is pending.
   */
  public static void flushAccessBookkeeping() {
    if (pendingAccessBookkeeping.isEmpty()) {
      return;
    }
    List<Agent_Memory__c> toUpdate = pendingAccessBookkeeping;
    pendingAccessBookkeeping = new List<Agent_Memory__c>();
    try {
      update toUpdate;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'Memory access bookkeeping failed: ' + e.getMessage()
      );
    }
  }

  /**
   * @description See `MemoryProvider.store`. Skips near-duplicates: an existing active
   * memory with the same scope/agent/user and identical content wins.
   * @param records Memories to store.
   */
  public void store(List<MemoryRecord> records) {
    if (records == null || records.isEmpty()) {
      return;
    }

    // LongTextArea can't be filtered in SOQL — load recent active rows for the same
    // agents and dedupe by content in Apex.
    Set<String> agents = new Set<String>();
    for (MemoryRecord rec : records) {
      agents.add(rec.agentDeveloperName);
    }
    Set<String> existing = new Set<String>();
    for (Agent_Memory__c row : [
      SELECT Content__c
      FROM Agent_Memory__c
      WHERE Is_Active__c = TRUE AND (Agent__c IN :agents OR Agent__c = NULL)
      ORDER BY CreatedDate DESC
      LIMIT 500
    ]) {
      existing.add(row.Content__c);
    }

    List<Agent_Memory__c> toInsert = new List<Agent_Memory__c>();
    for (MemoryRecord rec : records) {
      if (!existing.contains(rec.content)) {
        toInsert.add(rec.toSObject());
        existing.add(rec.content);
      }
    }
    insert toInsert;
  }

  private static Set<String> tokenize(String text) {
    Set<String> tokens = new Set<String>();
    if (String.isBlank(text)) {
      return tokens;
    }
    for (String token : text.toLowerCase().split('[^a-z0-9]+')) {
      if (token.length() > 2) {
        tokens.add(token);
      }
    }
    return tokens;
  }

  private static Integer overlapScore(
    Set<String> queryTokens,
    Agent_Memory__c row
  ) {
    Integer score = 0;
    Set<String> memoryTokens = tokenize(
      (row.Keywords__c == null ? '' : row.Keywords__c) +
        ' ' +
        (row.Content__c == null ? '' : row.Content__c)
    );
    for (String token : queryTokens) {
      if (memoryTokens.contains(token)) {
        score++;
      }
    }
    return score;
  }

  /** Sorts high score first; ties broken by access count. */
  private class Ranked implements Comparable {
    public Agent_Memory__c row;
    public Integer score;

    public Integer compareTo(Object other) {
      Ranked that = (Ranked) other;
      if (this.score != that.score) {
        return that.score - this.score;
      }
      Decimal mine = this.row.Access_Count__c == null
        ? 0
        : this.row.Access_Count__c;
      Decimal theirs = that.row.Access_Count__c == null
        ? 0
        : that.row.Access_Count__c;
      return theirs > mine ? 1 : (theirs < mine ? -1 : 0);
    }
  }
}
