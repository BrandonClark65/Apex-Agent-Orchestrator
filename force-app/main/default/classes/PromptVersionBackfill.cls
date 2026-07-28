/**
 * @description Seeds v1 of every agent's prompt from the packaged
 * `Agent_Definition__mdt.SystemPrompt__c` baseline, so prompt history starts from something real
 * rather than from the next edit.
 *
 * This is the `global` entry point behind `scripts/apex/BackfillPromptVersions.apex`. The logic
 * lives in the package rather than in the script because the script runs in the *subscriber*
 * org: anything it hardcodes — the `Version_Key__c` format, the `Active_Key__c`/`Is_Active__c`
 * lockstep that makes "one active version per agent" a database guarantee, the `Status__c`
 * picklist values — is a package invariant that a pasted copy of the script would silently
 * carry forward after the package changed it. Keeping it here means the subscriber runs one
 * line and always gets the current rules.
 *
 * Idempotent: an agent that already has any `Agent_Prompt_Version__c` row is skipped, so this is
 * safe to re-run after adding new agents.
 *
 * Optional. `AgentEngine` falls back to the CMDT baseline for any agent without versions, so the
 * framework is correct whether or not this ever runs — the backfill just makes the starting
 * point visible and diffable in the Agent Builder.
 * @group Agent Engine
 */
global with sharing class PromptVersionBackfill {
  /** @description What a `run()` did, so callers can report and assert on it. */
  global class Result {
    /** @description Number of v1 versions created. */
    global Integer created = 0;
    /** @description Number of agents left alone. */
    global Integer skipped = 0;
    /** @description One human-readable line per agent, created and skipped alike. */
    global List<String> messages = new List<String>();
  }

  /**
   * @description Creates an active, published v1 from the packaged baseline for every agent
   * that has no versions yet. Agents that already have versions, and agents whose baseline
   * prompt is blank, are skipped.
   * @return What was created and skipped.
   */
  global static Result run() {
    Result result = new Result();

    Set<String> alreadyVersioned = new Set<String>();
    for (AggregateResult row : [
      SELECT Agent__c agentName
      FROM Agent_Prompt_Version__c
      GROUP BY Agent__c
    ]) {
      alreadyVersioned.add((String) row.get('agentName'));
    }

    List<Agent_Prompt_Version__c> toInsert = new List<Agent_Prompt_Version__c>();

    for (aao__Agent_Definition__mdt def : [
      SELECT DeveloperName, aao__Goal__c, aao__SystemPrompt__c
      FROM aao__Agent_Definition__mdt
      ORDER BY DeveloperName
    ]) {
      if (alreadyVersioned.contains(def.DeveloperName)) {
        result.messages.add(
          'Skipped ' + def.DeveloperName + ' (already has versions)'
        );
        result.skipped++;
        continue;
      }
      if (String.isBlank(def.aao__SystemPrompt__c)) {
        result.messages.add(
          'Skipped ' + def.DeveloperName + ' (blank baseline prompt)'
        );
        result.skipped++;
        continue;
      }

      toInsert.add(
        new Agent_Prompt_Version__c(
          Agent__c = def.DeveloperName,
          Version_Number__c = 1,
          Version_Key__c = def.DeveloperName + '#1',
          System_Prompt__c = def.aao__SystemPrompt__c,
          Goal__c = def.aao__Goal__c,
          Change_Note__c = 'Backfilled from the packaged baseline prompt.',
          Status__c = 'Published',
          Published_At__c = System.now(),
          // Active_Key__c is what makes "one active version per agent" a database guarantee;
          // it must be set in lockstep with Is_Active__c or the invariant is unenforced.
          Is_Active__c = true,
          Active_Key__c = def.DeveloperName,
          // Two queries per agent, in a loop. Fine at the scale this runs at — a one-shot
          // setup step over the handful of agents an org defines — but it is the ceiling
          // here: an org with ~50 agents would need buildConfigSnapshot bulkified first.
          Config_Snapshot_Json__c = PromptVersionService.buildConfigSnapshot(
            def.DeveloperName
          )
        )
      );
    }

    if (!toInsert.isEmpty()) {
      insert toInsert;
    }

    for (Agent_Prompt_Version__c created : toInsert) {
      result.messages.add('Created v1 (active) for ' + created.Agent__c);
    }
    result.created = toInsert.size();

    return result;
  }
}
