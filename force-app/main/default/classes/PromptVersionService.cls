/**
 * @description Owns agent prompt versioning: both the read side the execution loop depends on
 * (resolving which `Agent_Prompt_Version__c` body a run should use) and the authoring side the
 * Agent Builder drives (drafting, publishing, activating, restoring).
 *
 * `Agent_Definition__mdt.SystemPrompt__c` is no longer the live prompt — it is the *packaged
 * baseline*, used only when an agent has no version records. Versions live in a custom SObject
 * rather than custom metadata because Apex cannot DML CMDT: routing prompt edits through
 * `Metadata.Operations` would make every save, and every rollback, a ~90 second async deploy.
 *
 * The resolution methods never throw. A run must not fail because prompt versioning had a bad
 * day — every failure path falls back to the CMDT baseline.
 *
 * Resolution queries run through the `without sharing` inner class `Resolver`. The object's OWD
 * is Private, and versions are authored by admins, so a sharing-aware query would return zero
 * rows for an ordinary chat user and silently degrade every one of their runs to the packaged
 * baseline. A prompt version is configuration that anyone allowed to run the agent must be able
 * to read; authoring below stays `with sharing`.
 * @group Agent Engine
 */
public with sharing class PromptVersionService {
  private static final String STATUS_DRAFT = 'Draft';
  private static final String STATUS_PUBLISHED = 'Published';

  // Resolution is re-entered several times per transaction — parallel tool batches merge back
  // into an LLM step, and sub-agent resumes re-enter the parent loop — so cache per agent.
  private static Map<String, ResolvedPrompt> activeCache = new Map<String, ResolvedPrompt>();

  /** @description The prompt body a run should execute, plus which version it came from. */
  public class ResolvedPrompt {
    /** @description Id of the version used, or null when falling back to the CMDT baseline. */
    public Id versionId;
    /** @description Version number used, or null when falling back to the CMDT baseline. */
    public Integer versionNumber;
    /** @description The system prompt body. Never null — empty string at worst. */
    public String systemPrompt;

    private ResolvedPrompt(
      Id versionId,
      Decimal versionNumber,
      String systemPrompt
    ) {
      this.versionId = versionId;
      this.versionNumber = versionNumber == null
        ? null
        : Integer.valueOf(versionNumber);
      // Callers concatenate this straight into the system message; a null would render the
      // literal string 'null' into the prompt.
      this.systemPrompt = systemPrompt == null ? '' : systemPrompt;
    }
  }

  //
  // ───────────────────────────────────────────────────────────────
  // RESOLUTION (hot path — must never throw)
  // ───────────────────────────────────────────────────────────────
  //

  /**
   * @description Resolves the active published version for an agent, falling back to the
   * packaged CMDT baseline when the agent has no active version or the lookup fails.
   * @param agentDeveloperName DeveloperName of the `Agent_Definition__mdt` being run.
   * @param cmdtBaseline `Agent_Definition__mdt.SystemPrompt__c`, used when no version applies.
   * @return The resolved prompt; never null.
   */
  public static ResolvedPrompt resolveActive(
    String agentDeveloperName,
    String cmdtBaseline
  ) {
    if (activeCache.containsKey(agentDeveloperName)) {
      return activeCache.get(agentDeveloperName);
    }

    ResolvedPrompt resolved = new ResolvedPrompt(null, null, cmdtBaseline);
    try {
      List<Agent_Prompt_Version__c> versions = new Resolver()
        .activeFor(agentDeveloperName);
      if (!versions.isEmpty()) {
        resolved = new ResolvedPrompt(
          versions[0].Id,
          versions[0].Version_Number__c,
          versions[0].System_Prompt__c
        );
      }
    } catch (Exception e) {
      // Most likely cause is missing read access on the object or its fields, which would
      // otherwise silently degrade every run for that user. Log loudly, serve the baseline.
      System.debug(
        LoggingLevel.ERROR,
        'PromptVersionService.resolveActive failed for ' +
          agentDeveloperName +
          ': ' +
          e.getMessage()
      );
    }

    activeCache.put(agentDeveloperName, resolved);
    return resolved;
  }

  /**
   * @description Resolves one specific version by Id, used when the Test Bench runs an input
   * against a version other than the active one. Falls back to the baseline if the version is
   * missing or belongs to a different agent.
   * @param versionId Id of the `Agent_Prompt_Version__c` to run.
   * @param agentDeveloperName Agent the run belongs to; guards against cross-agent Ids.
   * @param cmdtBaseline `Agent_Definition__mdt.SystemPrompt__c`, used when the version can't be used.
   * @return The resolved prompt; never null.
   */
  public static ResolvedPrompt resolveById(
    Id versionId,
    String agentDeveloperName,
    String cmdtBaseline
  ) {
    if (versionId == null) {
      return resolveActive(agentDeveloperName, cmdtBaseline);
    }
    try {
      List<Agent_Prompt_Version__c> versions = new Resolver().byId(versionId);
      if (
        !versions.isEmpty() &&
        (agentDeveloperName == null ||
        versions[0].Agent__c == agentDeveloperName)
      ) {
        return new ResolvedPrompt(
          versions[0].Id,
          versions[0].Version_Number__c,
          versions[0].System_Prompt__c
        );
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'PromptVersionService.resolveById failed for ' +
          versionId +
          ': ' +
          e.getMessage()
      );
    }
    return new ResolvedPrompt(null, null, cmdtBaseline);
  }

  /**
   * @description Resolves the prompt for an in-flight run. Prefers the version stamped on the
   * run at start — so a long run keeps executing the prompt it began with even if someone
   * activates a new version mid-flight — and only resolves the active version if unstamped.
   * @param stampedVersionId `Agent_Run__c.Prompt_Version__c`, or null if the run was never stamped.
   * @param agentDeveloperName DeveloperName of the agent being run.
   * @param cmdtBaseline `Agent_Definition__mdt.SystemPrompt__c`, used when no version applies.
   * @return The resolved prompt; never null.
   */
  public static ResolvedPrompt resolveForRun(
    Id stampedVersionId,
    String agentDeveloperName,
    String cmdtBaseline
  ) {
    return stampedVersionId != null
      ? resolveById(stampedVersionId, agentDeveloperName, cmdtBaseline)
      : resolveActive(agentDeveloperName, cmdtBaseline);
  }

  //
  // ───────────────────────────────────────────────────────────────
  // AUTHORING
  // ───────────────────────────────────────────────────────────────
  //

  /**
   * @description Creates a new Draft version for an agent. Drafts are editable and are not
   * used by any run until published.
   * @param agentDeveloperName Agent this version belongs to.
   * @param body The system prompt text.
   * @param goal Snapshot of the agent's goal.
   * @param note Short explanation of what changed and why.
   * @param sourceVersionId Version this was cloned or restored from, or null.
   * @return The inserted draft record.
   */
  public static Agent_Prompt_Version__c createDraft(
    String agentDeveloperName,
    String body,
    String goal,
    String note,
    Id sourceVersionId
  ) {
    if (String.isBlank(agentDeveloperName)) {
      throw new AgentException('agentDeveloperName is required');
    }
    Integer versionNumber = nextVersionNumber(agentDeveloperName);
    Agent_Prompt_Version__c draft = new Agent_Prompt_Version__c(
      Agent__c = agentDeveloperName,
      Version_Number__c = versionNumber,
      Version_Key__c = versionKey(agentDeveloperName, versionNumber),
      System_Prompt__c = body,
      Goal__c = goal,
      Change_Note__c = note,
      Source_Version__c = sourceVersionId,
      Status__c = STATUS_DRAFT
    );
    insert draft;
    return draft;
  }

  /**
   * @description Edits an existing draft in place. This is the counterpart to `createDraft`:
   * without it every save would insert a new version, so a draft could be created but never
   * refined — you could only publish it blind or abandon it.
   *
   * Only drafts are editable. Published and Archived bodies are frozen by the
   * `Published_Versions_Are_Immutable` validation rule; this check exists so the caller gets a
   * clear message instead of a raw DML error.
   * @param versionId Id of the draft to edit.
   * @param body The revised system prompt text.
   * @param goal The revised goal snapshot.
   * @param note Short explanation of what changed and why.
   * @return The updated draft record.
   */
  public static Agent_Prompt_Version__c updateDraft(
    Id versionId,
    String body,
    String goal,
    String note
  ) {
    Agent_Prompt_Version__c draft = [
      SELECT Id, Status__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
      LIMIT 1
    ];
    if (draft.Status__c != STATUS_DRAFT) {
      throw new AgentException(
        'Only a draft can be edited. Published versions are immutable — restore this one as a draft to work from it.'
      );
    }
    draft.System_Prompt__c = body;
    draft.Goal__c = goal;
    draft.Change_Note__c = note;
    update draft;
    return draft;
  }

  /**
   * @description Freezes a draft into an immutable Published version, snapshots the agent's
   * current configuration onto it, and makes it the active version for new runs.
   * @param versionId Id of the draft to publish.
   * @return The published record, re-queried so callers see the stored state.
   */
  public static Agent_Prompt_Version__c publish(Id versionId) {
    Agent_Prompt_Version__c version = [
      SELECT Id, Agent__c, Status__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
      LIMIT 1
    ];
    if (version.Status__c == STATUS_PUBLISHED) {
      activate(versionId);
      return version;
    }

    version.Status__c = STATUS_PUBLISHED;
    version.Published_At__c = System.now();
    version.Config_Snapshot_Json__c = buildConfigSnapshot(version.Agent__c);
    update version;

    activate(versionId);

    return [
      SELECT
        Id,
        Agent__c,
        Version_Number__c,
        Status__c,
        Is_Active__c,
        Published_At__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
      LIMIT 1
    ];
  }

  /**
   * @description Makes one published version the active one for its agent, deactivating
   * whichever version was active before. This is the rollback path: activating an older
   * version takes effect on the next run with no metadata deploy.
   *
   * Sibling rows are locked `FOR UPDATE` so two concurrent activations serialize; the unique
   * `Active_Key__c` index is the backstop if they somehow don't.
   * @param versionId Id of the version to activate.
   */
  public static void activate(Id versionId) {
    Agent_Prompt_Version__c target = [
      SELECT Id, Agent__c, Status__c, Is_Active__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
      LIMIT 1
    ];
    if (target.Status__c != STATUS_PUBLISHED) {
      throw new AgentException(
        'Only a published version can be made active. Publish it first.'
      );
    }

    String agentName = target.Agent__c;
    List<Agent_Prompt_Version__c> toUpdate = new List<Agent_Prompt_Version__c>();

    for (Agent_Prompt_Version__c current : [
      SELECT Id
      FROM Agent_Prompt_Version__c
      WHERE Agent__c = :agentName AND Is_Active__c = TRUE AND Id != :versionId
      FOR UPDATE
    ]) {
      // Active_Key__c must be nulled, not blanked — the unique index ignores nulls, which is
      // what lets exactly one row per agent hold the key.
      current.Is_Active__c = false;
      current.Active_Key__c = null;
      toUpdate.add(current);
    }

    target.Is_Active__c = true;
    target.Active_Key__c = agentName;
    toUpdate.add(target);

    update toUpdate;
    activeCache.remove(agentName);
  }

  /**
   * @description Copies an existing version's body into a new editable draft, so an author can
   * start from an earlier prompt without mutating it — published bodies are frozen, so this is
   * the only way to build on one. The new draft takes the next version number and records the
   * version it came from in `Source_Version__c`; the source itself is left untouched.
   * @param versionId Id of the version to copy.
   * @return The new draft record.
   */
  public static Agent_Prompt_Version__c restoreAsDraft(Id versionId) {
    Agent_Prompt_Version__c source = [
      SELECT Id, Agent__c, Version_Number__c, System_Prompt__c, Goal__c
      FROM Agent_Prompt_Version__c
      WHERE Id = :versionId
      LIMIT 1
    ];
    return createDraft(
      source.Agent__c,
      source.System_Prompt__c,
      source.Goal__c,
      'Restored from v' + String.valueOf(source.Version_Number__c.intValue()),
      source.Id
    );
  }

  /**
   * @description Returns the next unused version number for an agent. Concurrent callers can
   * race here; the unique `Version_Key__c` field turns that race into a `DUPLICATE_VALUE`
   * error rather than two versions sharing a number.
   * @param agentDeveloperName Agent to number within.
   * @return Highest existing version number + 1, or 1 for the agent's first version.
   */
  public static Integer nextVersionNumber(String agentDeveloperName) {
    List<AggregateResult> results = [
      SELECT MAX(Version_Number__c) maxVersion
      FROM Agent_Prompt_Version__c
      WHERE Agent__c = :agentDeveloperName
    ];
    Decimal maxVersion = results.isEmpty()
      ? null
      : (Decimal) results[0].get('maxVersion');
    return maxVersion == null ? 1 : maxVersion.intValue() + 1;
  }

  /**
   * @description Snapshots the agent's current configuration as JSON for the audit trail:
   * provider, step cap, memory config and the tools granted at publish time. Purely
   * informational — the engine never replays it.
   * @param agentDeveloperName Agent to snapshot.
   * @return JSON snapshot, or null if the agent definition can't be read.
   */
  public static String buildConfigSnapshot(String agentDeveloperName) {
    try {
      List<aao__Agent_Definition__mdt> defs = [
        SELECT
          aao__LLMProvider__c,
          aao__MaxSteps__c,
          aao__MemoryConfig__c,
          aao__IsActive__c
        FROM aao__Agent_Definition__mdt
        WHERE DeveloperName = :agentDeveloperName
        LIMIT 1
      ];
      if (defs.isEmpty()) {
        return null;
      }

      List<String> toolNames = new List<String>(
        ToolRegistry.getToolDefinitionsForAgent(agentDeveloperName).keySet()
      );
      toolNames.sort();

      return JSON.serialize(
        new Map<String, Object>{
          'llmProvider' => defs[0].aao__LLMProvider__c,
          'maxSteps' => defs[0].aao__MaxSteps__c,
          'memoryConfig' => defs[0].aao__MemoryConfig__c,
          'agentIsActive' => defs[0].aao__IsActive__c,
          'tools' => toolNames,
          'capturedAt' => System.now().format('yyyy-MM-dd HH:mm:ss')
        }
      );
    } catch (Exception e) {
      // A snapshot is nice to have; never let it block a publish.
      System.debug(
        LoggingLevel.ERROR,
        'PromptVersionService.buildConfigSnapshot failed for ' +
          agentDeveloperName +
          ': ' +
          e.getMessage()
      );
      return null;
    }
  }

  /**
   * @description Sharing-exempt reads of prompt versions. Ordinary chat users don't own the
   * version records an admin authored, and the object's OWD is Private, so a sharing-aware
   * query would return nothing and every run would quietly fall back to the packaged baseline.
   * Read-only by design — nothing here writes.
   */
  private without sharing class Resolver {
    private List<Agent_Prompt_Version__c> activeFor(String agentDeveloperName) {
      return [
        SELECT Id, Agent__c, Version_Number__c, System_Prompt__c
        FROM Agent_Prompt_Version__c
        WHERE Agent__c = :agentDeveloperName AND Is_Active__c = TRUE
        LIMIT 1
      ];
    }

    private List<Agent_Prompt_Version__c> byId(Id versionId) {
      return [
        SELECT Id, Agent__c, Version_Number__c, System_Prompt__c
        FROM Agent_Prompt_Version__c
        WHERE Id = :versionId
        LIMIT 1
      ];
    }
  }

  private static String versionKey(
    String agentDeveloperName,
    Integer versionNumber
  ) {
    return agentDeveloperName + '#' + String.valueOf(versionNumber);
  }

  /**
   * @description Clears the per-transaction resolution cache. Tests that activate a version
   * and then run an agent in the same transaction need this; production code does not.
   */
  @TestVisible
  private static void clearCache() {
    activeCache.clear();
  }
}
