/**
 * @description Tests `PromptVersionBackfill`: that a fresh org gets an active, published v1 per
 * agent from the packaged baseline, that the `Active_Key__c` invariant is set in lockstep so the
 * unique index actually enforces one active version per agent, and — the property the script
 * depends on to be safe to re-run — that a second run is a no-op.
 * @group Tests
 */
@IsTest
private class PromptVersionBackfillTest {
  private static final String AGENT = 'CRUD_Agent';

  private static List<Agent_Prompt_Version__c> versionsFor(String agent) {
    return [
      SELECT
        Id,
        Agent__c,
        Version_Number__c,
        Version_Key__c,
        Status__c,
        Is_Active__c,
        Active_Key__c,
        System_Prompt__c,
        Published_At__c
      FROM Agent_Prompt_Version__c
      WHERE Agent__c = :agent
      ORDER BY Version_Number__c
    ];
  }

  @IsTest
  static void testBackfillCreatesActivePublishedV1FromBaseline() {
    Test.startTest();
    PromptVersionBackfill.Result result = PromptVersionBackfill.run();
    Test.stopTest();

    System.assert(
      result.created > 0,
      'The packaged agents have baseline prompts, so the backfill should create versions'
    );

    List<Agent_Prompt_Version__c> versions = versionsFor(AGENT);
    System.assertEquals(
      1,
      versions.size(),
      'Backfill should create exactly v1'
    );

    Agent_Prompt_Version__c v1 = versions[0];
    System.assertEquals(
      1,
      Integer.valueOf(v1.Version_Number__c),
      'Backfill seeds version 1'
    );
    System.assertEquals(
      AGENT + '#1',
      v1.Version_Key__c,
      'Version key must match the format the service generates'
    );
    System.assertEquals(
      'Published',
      v1.Status__c,
      'v1 is published, not draft'
    );
    System.assertEquals(true, v1.Is_Active__c, 'v1 is the active version');
    System.assertEquals(
      AGENT,
      v1.Active_Key__c,
      'Active_Key__c must be set in lockstep with Is_Active__c or the unique index enforces nothing'
    );
    System.assertNotEquals(
      null,
      v1.Published_At__c,
      'A published version should carry a publish timestamp'
    );

    List<aao__Agent_Definition__mdt> defs = [
      SELECT aao__SystemPrompt__c
      FROM aao__Agent_Definition__mdt
      WHERE DeveloperName = :AGENT
      LIMIT 1
    ];
    System.assertEquals(
      defs[0].aao__SystemPrompt__c,
      v1.System_Prompt__c,
      'v1 body should be the packaged baseline verbatim'
    );
  }

  @IsTest
  static void testBackfillResolvesAsTheActiveVersion() {
    Test.startTest();
    PromptVersionBackfill.run();
    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveActive(
      AGENT,
      'baseline-fallback'
    );
    Test.stopTest();

    System.assertEquals(
      1,
      resolved.versionNumber,
      'After a backfill a run should resolve to v1, not fall back to the CMDT baseline'
    );
    System.assertNotEquals(
      'baseline-fallback',
      resolved.systemPrompt,
      'Resolution should return the backfilled body, not the fallback'
    );
  }

  @IsTest
  static void testBackfillIsIdempotent() {
    PromptVersionBackfill.run();
    Integer afterFirst = [SELECT COUNT() FROM Agent_Prompt_Version__c];

    Test.startTest();
    PromptVersionBackfill.Result second = PromptVersionBackfill.run();
    Test.stopTest();

    System.assertEquals(
      0,
      second.created,
      'Re-running the backfill must not create duplicate versions'
    );
    System.assert(
      second.skipped > 0,
      'Agents that already have versions should be reported as skipped'
    );
    System.assertEquals(
      afterFirst,
      [SELECT COUNT() FROM Agent_Prompt_Version__c],
      'A second run should leave the record count untouched'
    );
  }

  @IsTest
  static void testBackfillSkipsAgentsThatAlreadyHaveVersions() {
    // A hand-authored draft is enough to claim the agent: the backfill's job is to seed history
    // where there is none, never to inject a v1 underneath versions someone already wrote.
    PromptVersionService.createDraft(AGENT, 'hand written', null, null, null);

    Test.startTest();
    PromptVersionBackfill.Result result = PromptVersionBackfill.run();
    Test.stopTest();

    List<Agent_Prompt_Version__c> versions = versionsFor(AGENT);
    System.assertEquals(
      1,
      versions.size(),
      'The existing draft should be the only version for this agent'
    );
    System.assertEquals(
      'hand written',
      versions[0].System_Prompt__c,
      'Backfill must not overwrite or duplicate an existing version'
    );
    System.assert(
      result.messages.contains('Skipped ' + AGENT + ' (already has versions)'),
      'The skip should be reported by name, got: ' + result.messages
    );
  }
}
