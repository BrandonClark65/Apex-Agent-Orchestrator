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
 * The work itself lives in the package (aao.PromptVersionBackfill) rather than inline here,
 * because this script runs in the *subscriber* org: the version-key format and the
 * Active_Key__c/Is_Active__c lockstep behind "one active version per agent" are package
 * invariants, and a pasted copy of a script that inlined them would go stale the moment the
 * package changed. Note the aao namespace prefix — packaged Apex is only reachable from
 * subscriber code when it is both global and fully qualified.
 *
 *   sf apex run --file scripts/apex/BackfillPromptVersions.apex --target-org aao
 */

aao.PromptVersionBackfill.Result result = aao.PromptVersionBackfill.run();

System.debug(LoggingLevel.INFO, '=== Prompt version backfill ===');
for (String message : result.messages) {
  System.debug(LoggingLevel.INFO, message);
}
System.debug(
  LoggingLevel.INFO,
  'Created ' + result.created + ', skipped ' + result.skipped + '.'
);
