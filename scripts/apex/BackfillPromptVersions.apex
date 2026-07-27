/**
 * Seeds v1 of every agent's prompt from the packaged Agent_Definition__mdt.SystemPrompt__c
 * baseline, so prompt history starts from something real rather than from the next edit.
 *
 * Idempotent: an agent that already has any Agent_Prompt_Version__c row is skipped, so this is
 * safe to re-run after adding new agents.
 *
 * Optional. AgentEngine falls back to the CMDT baseline for any agent without versions, so the
 * framework is correct whether or not this ever runs — the backfill just makes the starting
 * point visible and diffable in the Agent Builder.
 *
 *   sf apex run --file scripts/apex/BackfillPromptVersions.apex --target-org aao
 */

Set<String> alreadyVersioned = new Set<String>();
for (AggregateResult row : [
  SELECT aao__Agent__c agentName
  FROM aao__Agent_Prompt_Version__c
  GROUP BY aao__Agent__c
]) {
  alreadyVersioned.add((String) row.get('agentName'));
}

List<aao__Agent_Prompt_Version__c> toInsert = new List<aao__Agent_Prompt_Version__c>();
List<String> skipped = new List<String>();

for (aao__Agent_Definition__mdt def : [
  SELECT DeveloperName, aao__Goal__c, aao__SystemPrompt__c
  FROM aao__Agent_Definition__mdt
  ORDER BY DeveloperName
]) {
  if (alreadyVersioned.contains(def.DeveloperName)) {
    skipped.add(def.DeveloperName + ' (already has versions)');
    continue;
  }
  if (String.isBlank(def.aao__SystemPrompt__c)) {
    skipped.add(def.DeveloperName + ' (blank baseline prompt)');
    continue;
  }

  toInsert.add(
    new aao__Agent_Prompt_Version__c(
      aao__Agent__c = def.DeveloperName,
      aao__Version_Number__c = 1,
      aao__Version_Key__c = def.DeveloperName + '#1',
      aao__System_Prompt__c = def.aao__SystemPrompt__c,
      aao__Goal__c = def.aao__Goal__c,
      aao__Change_Note__c = 'Backfilled from the packaged baseline prompt.',
      aao__Status__c = 'Published',
      aao__Published_At__c = System.now(),
      // Active_Key__c is what makes "one active version per agent" a database guarantee;
      // it must be set in lockstep with Is_Active__c or the invariant is unenforced.
      aao__Is_Active__c = true,
      aao__Active_Key__c = def.DeveloperName,
      aao__Config_Snapshot_Json__c = PromptVersionService.buildConfigSnapshot(
        def.DeveloperName
      )
    )
  );
}

if (!toInsert.isEmpty()) {
  insert toInsert;
}

System.debug(LoggingLevel.INFO, '=== Prompt version backfill ===');
for (aao__Agent_Prompt_Version__c created : toInsert) {
  System.debug(
    LoggingLevel.INFO,
    'Created v1 (active) for ' + created.aao__Agent__c
  );
}
for (String reason : skipped) {
  System.debug(LoggingLevel.INFO, 'Skipped ' + reason);
}
System.debug(
  LoggingLevel.INFO,
  'Created ' + toInsert.size() + ', skipped ' + skipped.size() + '.'
);
