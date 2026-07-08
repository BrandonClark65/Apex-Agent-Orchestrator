/**
 * @description Post-run memory capture: loads the terminated run's transcript and asks
 * the LLM to (a) extract durable facts/preferences worth remembering (`extractFacts`)
 * and/or (b) write one short lesson the agent should apply next time (`reflect`, M3).
 * Runs as its own `AllowsCallouts` queueable because `finishRun` — the enqueue point —
 * can execute in the non-callout tool step. Uses the memory config's
 * `Maintenance_Provider__c` (cheap model) with fallback to the agent's provider.
 * Every failure is swallowed: capture must never affect the run that spawned it.
 * @group Memory
 */
public with sharing class MemoryCaptureQueueable implements Queueable, Database.AllowsCallouts {
  @TestVisible
  private static final Integer MAX_ACTIVE_REFLECTIONS = 20;

  private final Id runId;
  private final String agentDeveloperName;
  private final String memoryConfigDeveloperName;
  private final Boolean extractFacts;
  private final Boolean reflect;

  /**
   * @description See class description.
   * @param runId Terminated run to learn from.
   * @param agentDeveloperName Agent that ran.
   * @param memoryConfigDeveloperName The agent's memory config.
   * @param extractFacts Run the fact/preference extraction pass.
   * @param reflect Run the reflection (lesson) pass.
   */
  public MemoryCaptureQueueable(
    Id runId,
    String agentDeveloperName,
    String memoryConfigDeveloperName,
    Boolean extractFacts,
    Boolean reflect
  ) {
    this.runId = runId;
    this.agentDeveloperName = agentDeveloperName;
    this.memoryConfigDeveloperName = memoryConfigDeveloperName;
    this.extractFacts = extractFacts;
    this.reflect = reflect;
  }

  /**
   * @description Queueable entry point.
   * @param context Queueable context (unused).
   */
  public void execute(QueueableContext context) {
    try {
      aao__Agent_Run__c run = [
        SELECT
          aao__History_Json__c,
          aao__Status__c,
          aao__Error_Message__c,
          CreatedById
        FROM aao__Agent_Run__c
        WHERE Id = :runId
        LIMIT 1
      ];
      if (String.isBlank(run.aao__History_Json__c)) {
        return;
      }

      LLMClient client = resolveClient();
      List<MemoryRecord> captured = new List<MemoryRecord>();

      if (extractFacts) {
        captured.addAll(runExtraction(client, run));
      }
      if (reflect) {
        captured.addAll(runReflection(client, run));
      }
      if (!captured.isEmpty()) {
        MemoryProviderFactory.forConfig(memoryConfigDeveloperName)
          .store(captured);
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'Memory capture failed for run ' + runId + ': ' + e.getMessage()
      );
    }
  }

  private List<MemoryRecord> runExtraction(
    LLMClient client,
    aao__Agent_Run__c run
  ) {
    LLMRequest req = new LLMRequest();
    req.messages.add(
      new LLMMessage(
        'system',
        'You extract durable memories from an agent conversation transcript. Return a ' +
          'JSON array (possibly empty) of memories worth keeping for future ' +
          'conversations: stable user preferences, org facts, and decisions with ' +
          'lasting relevance. Never store secrets, one-off details, or anything only ' +
          'relevant to this single task. Each item: {"content":"...","type":"Fact" or ' +
          '"Preference","scope":"User" or "Agent" or "Global","keywords":"comma,separated"}. ' +
          'Default scope to "User". Respond with the JSON array only.'
      )
    );
    req.messages.add(new LLMMessage('user', run.aao__History_Json__c));

    LLMResponse res = client.complete(req);
    List<MemoryRecord> records = new List<MemoryRecord>();
    for (Object itemObj : (List<Object>) JSON.deserializeUntyped(res.text)) {
      Map<String, Object> item = (Map<String, Object>) itemObj;
      String content = String.valueOf(item.get('content'));
      if (String.isBlank(content)) {
        continue;
      }
      String memoryType = normalize(
        String.valueOf(item.get('type')),
        new Set<String>{ 'Fact', 'Preference' },
        'Fact'
      );
      String scope = normalize(
        String.valueOf(item.get('scope')),
        new Set<String>{ 'User', 'Agent', 'Global' },
        'User'
      );
      MemoryRecord rec = new MemoryRecord(
        agentDeveloperName,
        scope == 'User' ? run.CreatedById : null,
        scope,
        memoryType,
        content,
        item.get('keywords') == null
          ? null
          : String.valueOf(item.get('keywords'))
      );
      rec.sourceRunId = runId;
      records.add(rec);
    }
    return records;
  }

  private List<MemoryRecord> runReflection(
    LLMClient client,
    aao__Agent_Run__c run
  ) {
    // Cap active reflections per agent (consolidation is a future pass; for now stop adding).
    Integer active = [
      SELECT COUNT()
      FROM Agent_Memory__c
      WHERE
        Agent__c = :agentDeveloperName
        AND Type__c = 'Reflection'
        AND Is_Active__c = TRUE
    ];
    if (active >= MAX_ACTIVE_REFLECTIONS) {
      return new List<MemoryRecord>();
    }

    LLMRequest req = new LLMRequest();
    req.messages.add(
      new LLMMessage(
        'system',
        'You are reviewing one of your own past runs as this agent. The run ended with ' +
          'status "' +
          run.aao__Status__c +
          '"' +
          (String.isBlank(run.aao__Error_Message__c)
            ? ''
            : ' (error: ' + run.aao__Error_Message__c + ')') +
          '. Write ONE short, general lesson that would improve future runs — a tool-usage ' +
          'mistake to avoid, better sequencing, or a formatting rule. If there is no ' +
          'useful lesson, respond with exactly NONE. Respond with the lesson text only.'
      )
    );
    req.messages.add(new LLMMessage('user', run.aao__History_Json__c));

    LLMResponse res = client.complete(req);
    String lesson = res.text == null ? '' : res.text.trim();
    if (String.isBlank(lesson) || lesson.equalsIgnoreCase('NONE')) {
      return new List<MemoryRecord>();
    }

    MemoryRecord rec = new MemoryRecord(
      agentDeveloperName,
      null,
      'Agent',
      'Reflection',
      lesson,
      null
    );
    rec.sourceRunId = runId;
    return new List<MemoryRecord>{ rec };
  }

  private LLMClient resolveClient() {
    List<aao__Memory_Config__mdt> configs = [
      SELECT Maintenance_Provider__c
      FROM aao__Memory_Config__mdt
      WHERE DeveloperName = :memoryConfigDeveloperName
      LIMIT 1
    ];
    String provider = !configs.isEmpty() &&
      String.isNotBlank(configs[0].Maintenance_Provider__c)
      ? configs[0].Maintenance_Provider__c
      : [
          SELECT aao__LLMProvider__c
          FROM aao__Agent_Definition__mdt
          WHERE DeveloperName = :agentDeveloperName
          LIMIT 1
        ]
        .aao__LLMProvider__c;
    return LLMClientFactory.forProvider(provider);
  }

  private static String normalize(
    String value,
    Set<String> allowed,
    String fallback
  ) {
    if (value != null) {
      for (String candidate : allowed) {
        if (candidate.equalsIgnoreCase(value)) {
          return candidate;
        }
      }
    }
    return fallback;
  }
}
