/**
 * @description Tests `PromptVersionService`: per-agent version numbering, the single-active-
 * version invariant and its `Active_Key__c` backstop, the immutability validation rule's
 * boundaries, and — most importantly — that resolution degrades to the packaged CMDT baseline
 * instead of throwing, since a resolution failure must never be able to break a run.
 * @group Tests
 */
@IsTest
private class PromptVersionServiceTest {
  private static final String AGENT = 'CRUD_Agent';
  private static final String OTHER_AGENT = 'Orchestrator_Agent';

  private static Agent_Prompt_Version__c publishVersion(
    String agent,
    String body
  ) {
    Agent_Prompt_Version__c draft = PromptVersionService.createDraft(
      agent,
      body,
      'goal',
      'note',
      null
    );
    PromptVersionService.publish(draft.Id);
    return draft;
  }

  private static Agent_Prompt_Version__c reload(Id versionId) {
    return [
      SELECT
        Id,
        Status__c,
        Is_Active__c,
        Active_Key__c,
        Version_Key__c,
        Version_Number__c,
        Published_At__c,
        Config_Snapshot_Json__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
    ];
  }

  @IsTest
  static void testVersionNumbersSequencePerAgent() {
    Test.startTest();
    Agent_Prompt_Version__c first = PromptVersionService.createDraft(
      AGENT,
      'one',
      null,
      null,
      null
    );
    Agent_Prompt_Version__c second = PromptVersionService.createDraft(
      AGENT,
      'two',
      null,
      null,
      null
    );
    // A different agent numbers independently rather than continuing the same sequence.
    Agent_Prompt_Version__c otherFirst = PromptVersionService.createDraft(
      OTHER_AGENT,
      'one',
      null,
      null,
      null
    );
    Test.stopTest();

    System.assertEquals(
      1,
      reload(first.Id).Version_Number__c,
      'First version for an agent should be v1'
    );
    System.assertEquals(
      2,
      reload(second.Id).Version_Number__c,
      'Second version should increment'
    );
    System.assertEquals(
      1,
      reload(otherFirst.Id).Version_Number__c,
      'A different agent should start its own sequence at v1'
    );
    System.assertEquals(
      AGENT + '#2',
      reload(second.Id).Version_Key__c,
      'Version key should combine agent and number'
    );
  }

  @IsTest
  static void testPublishFreezesAndActivates() {
    Agent_Prompt_Version__c draft = PromptVersionService.createDraft(
      AGENT,
      'body',
      'goal',
      'why',
      null
    );
    System.assertEquals(
      'Draft',
      reload(draft.Id).Status__c,
      'New versions start as drafts'
    );

    Test.startTest();
    PromptVersionService.publish(draft.Id);
    Test.stopTest();

    Agent_Prompt_Version__c published = reload(draft.Id);
    System.assertEquals('Published', published.Status__c);
    System.assertEquals(
      true,
      published.Is_Active__c,
      'Publishing should also activate'
    );
    System.assertEquals(
      AGENT,
      published.Active_Key__c,
      'Active key must be set in lockstep with Is_Active__c'
    );
    System.assertNotEquals(
      null,
      published.Published_At__c,
      'Publishing should stamp the timestamp'
    );
    System.assertNotEquals(
      null,
      published.Config_Snapshot_Json__c,
      'Publishing should capture a config snapshot'
    );
  }

  @IsTest
  static void testActivatingDeactivatesPreviousVersion() {
    Agent_Prompt_Version__c v1 = publishVersion(AGENT, 'first');
    Agent_Prompt_Version__c v2 = publishVersion(AGENT, 'second');

    System.assertEquals(
      false,
      reload(v1.Id).Is_Active__c,
      'Publishing v2 should have deactivated v1'
    );

    // Roll back to v1.
    Test.startTest();
    PromptVersionService.activate(v1.Id);
    Test.stopTest();

    System.assertEquals(true, reload(v1.Id).Is_Active__c);
    System.assertEquals(AGENT, reload(v1.Id).Active_Key__c);
    System.assertEquals(
      false,
      reload(v2.Id).Is_Active__c,
      'Activating v1 should deactivate v2'
    );
    System.assertEquals(
      null,
      reload(v2.Id).Active_Key__c,
      'A deactivated version must release the unique active key'
    );
  }

  @IsTest
  static void testOnlyOneActiveVersionPerAgent() {
    publishVersion(AGENT, 'first');
    publishVersion(AGENT, 'second');
    publishVersion(AGENT, 'third');

    Integer activeCount = [
      SELECT COUNT()
      FROM Agent_Prompt_Version__c
      WHERE Agent__c = :AGENT AND Is_Active__c = TRUE
    ];
    System.assertEquals(
      1,
      activeCount,
      'Exactly one version may be active per agent'
    );
  }

  @IsTest
  static void testActiveKeyUniquenessIsEnforcedByTheDatabase() {
    publishVersion(AGENT, 'first');

    // Bypassing the service must still be caught — the unique index is the real guarantee.
    Agent_Prompt_Version__c rogue = new Agent_Prompt_Version__c(
      Agent__c = AGENT,
      Version_Number__c = 99,
      Version_Key__c = AGENT + '#99',
      System_Prompt__c = 'rogue',
      Status__c = 'Published',
      Is_Active__c = true,
      Active_Key__c = AGENT
    );

    Boolean threw = false;
    try {
      insert rogue;
    } catch (DmlException e) {
      threw = true;
      System.assert(
        e.getMessage().containsIgnoreCase('duplicate'),
        'Expected a duplicate value error, got: ' + e.getMessage()
      );
    }
    System.assert(
      threw,
      'A second active version for the same agent must be rejected'
    );
  }

  @IsTest
  static void testCannotActivateADraft() {
    Agent_Prompt_Version__c draft = PromptVersionService.createDraft(
      AGENT,
      'body',
      null,
      null,
      null
    );

    Boolean threw = false;
    try {
      PromptVersionService.activate(draft.Id);
    } catch (AgentException e) {
      threw = true;
    }
    System.assert(threw, 'Activating an unpublished draft should be rejected');
  }

  @IsTest
  static void testPublishedVersionBodyIsImmutable() {
    Agent_Prompt_Version__c published = publishVersion(AGENT, 'frozen');

    Boolean threw = false;
    try {
      update new Agent_Prompt_Version__c(
        Id = published.Id,
        System_Prompt__c = 'tampered'
      );
    } catch (DmlException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('already published'),
        'Expected the immutability rule to fire, got: ' + e.getMessage()
      );
    }
    System.assert(threw, 'Editing a published prompt body must be rejected');
  }

  @IsTest
  static void testDraftBodyStaysEditableAndArchivingIsAllowed() {
    Agent_Prompt_Version__c draft = PromptVersionService.createDraft(
      AGENT,
      'first pass',
      null,
      null,
      null
    );

    // Draft -> edit body: allowed.
    update new Agent_Prompt_Version__c(
      Id = draft.Id,
      System_Prompt__c = 'second pass'
    );

    // Draft -> Published: allowed (PRIORVALUE is Draft, so the rule must not fire).
    PromptVersionService.publish(draft.Id);

    // Published -> Archived: status-only, so the rule must not fire either.
    update new Agent_Prompt_Version__c(Id = draft.Id, Status__c = 'Archived');

    System.assertEquals(
      'Archived',
      reload(draft.Id).Status__c,
      'Status-only transitions must not trip the immutability rule'
    );
  }

  @IsTest
  static void testResolveActiveUsesTheActiveVersion() {
    publishVersion(AGENT, 'versioned body');
    PromptVersionService.clearCache();

    Test.startTest();
    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveActive(
      AGENT,
      'baseline body'
    );
    Test.stopTest();

    System.assertEquals('versioned body', resolved.systemPrompt);
    System.assertEquals(1, resolved.versionNumber);
    System.assertNotEquals(null, resolved.versionId);
  }

  @IsTest
  static void testResolveActiveFallsBackToBaselineWhenNoVersionsExist() {
    PromptVersionService.clearCache();

    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveActive(
      AGENT,
      'baseline body'
    );

    System.assertEquals('baseline body', resolved.systemPrompt);
    System.assertEquals(
      null,
      resolved.versionId,
      'Falling back to the baseline must not claim a version'
    );
    System.assertEquals(null, resolved.versionNumber);
  }

  @IsTest
  static void testResolveNeverReturnsNullPromptText() {
    PromptVersionService.clearCache();

    // A null baseline used to concatenate into the prompt as the literal string 'null'.
    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveActive(
      'No_Such_Agent',
      null
    );

    System.assertEquals(
      '',
      resolved.systemPrompt,
      'A missing prompt should resolve to empty text, never null'
    );
  }

  @IsTest
  static void testResolveByIdHonoursAnExplicitOverride() {
    Agent_Prompt_Version__c v1 = publishVersion(AGENT, 'old body');
    publishVersion(AGENT, 'new body');
    PromptVersionService.clearCache();

    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveById(
      v1.Id,
      AGENT,
      'baseline'
    );

    System.assertEquals(
      'old body',
      resolved.systemPrompt,
      'An explicit version id should win over the active version'
    );
    System.assertEquals(1, resolved.versionNumber);
  }

  @IsTest
  static void testResolveByIdRejectsAVersionBelongingToAnotherAgent() {
    Agent_Prompt_Version__c otherAgentVersion = publishVersion(
      OTHER_AGENT,
      'other agent body'
    );
    PromptVersionService.clearCache();

    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveById(
      otherAgentVersion.Id,
      AGENT,
      'baseline'
    );

    System.assertEquals(
      'baseline',
      resolved.systemPrompt,
      'A version from a different agent must not be used'
    );
    System.assertEquals(null, resolved.versionId);
  }

  @IsTest
  static void testResolveForRunPrefersTheStampedVersion() {
    Agent_Prompt_Version__c v1 = publishVersion(AGENT, 'stamped body');
    publishVersion(AGENT, 'newly activated body');
    PromptVersionService.clearCache();

    // A run stamped with v1 keeps using v1 even though v2 is now the active version.
    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveForRun(
      v1.Id,
      AGENT,
      'baseline'
    );

    System.assertEquals('stamped body', resolved.systemPrompt);
  }

  @IsTest
  static void testResolveForRunFallsBackToActiveWhenUnstamped() {
    publishVersion(AGENT, 'active body');
    PromptVersionService.clearCache();

    PromptVersionService.ResolvedPrompt resolved = PromptVersionService.resolveForRun(
      null,
      AGENT,
      'baseline'
    );

    System.assertEquals('active body', resolved.systemPrompt);
  }

  @IsTest
  static void testRestoreAsDraftCopiesBodyWithoutMutatingTheSource() {
    Agent_Prompt_Version__c v1 = publishVersion(AGENT, 'original body');
    publishVersion(AGENT, 'current body');

    Test.startTest();
    Agent_Prompt_Version__c restored = PromptVersionService.restoreAsDraft(
      v1.Id
    );
    Test.stopTest();

    Agent_Prompt_Version__c reloaded = [
      SELECT
        Status__c,
        System_Prompt__c,
        Version_Number__c,
        Source_Version__c,
        Change_Note__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :restored.Id
    ];
    System.assertEquals('original body', reloaded.System_Prompt__c);
    System.assertEquals('Draft', reloaded.Status__c);
    System.assertEquals(
      3,
      reloaded.Version_Number__c,
      'A restore should take the next number, not reuse the source number'
    );
    System.assertEquals(
      v1.Id,
      reloaded.Source_Version__c,
      'Lineage should point back at the version it came from'
    );
    System.assertEquals(
      'Published',
      reload(v1.Id).Status__c,
      'Restoring must not modify the source version'
    );
  }

  @IsTest
  static void testBuildConfigSnapshotCapturesAgentConfiguration() {
    String snapshot = PromptVersionService.buildConfigSnapshot(AGENT);

    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
      snapshot
    );
    System.assertNotEquals(
      null,
      parsed.get('llmProvider'),
      'Snapshot should record the provider'
    );
    System.assert(
      parsed.containsKey('tools'),
      'Snapshot should record granted tools'
    );
    System.assert(
      ((List<Object>) parsed.get('tools')).size() > 0,
      'CRUD_Agent has tool grants, so the snapshot should list them'
    );
  }

  @IsTest
  static void testBuildConfigSnapshotReturnsNullForUnknownAgent() {
    System.assertEquals(
      null,
      PromptVersionService.buildConfigSnapshot('No_Such_Agent'),
      'An unknown agent should yield no snapshot rather than throwing'
    );
  }

  @IsTest
  static void testResolutionIgnoresRecordSharing() {
    // The object's OWD is Private and versions are authored by admins. A sharing-aware query
    // would return zero rows for an ordinary user and silently drop every one of their runs
    // back to the packaged baseline — no error, just a stale prompt. The service resolves
    // through a `without sharing` inner class precisely to stop that.
    publishVersion(AGENT, 'admin authored body');

    User standardUser = new User(
      Alias = 'aaotst',
      Email = 'aao.prompt.version.test@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Prompt Version Test',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'aao.prompt.version.test.' +
        DateTime.now().getTime() +
        '@example.com'
    );
    insert standardUser;

    PromptVersionService.ResolvedPrompt resolved;
    System.runAs(standardUser) {
      PromptVersionService.clearCache();
      resolved = PromptVersionService.resolveActive(AGENT, 'baseline');
    }

    System.assertEquals(
      'admin authored body',
      resolved.systemPrompt,
      'A user who does not own the version record must still resolve it'
    );
    System.assertNotEquals(
      null,
      resolved.versionId,
      'The run should still be stamped for a non-owning user'
    );
  }

  @IsTest
  static void testCreateDraftRequiresAnAgent() {
    Boolean threw = false;
    try {
      PromptVersionService.createDraft(null, 'body', null, null, null);
    } catch (AgentException e) {
      threw = true;
    }
    System.assert(threw, 'A version must belong to an agent');
  }
}
