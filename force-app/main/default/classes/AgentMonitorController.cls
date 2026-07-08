/**
 * @description `@AuraEnabled` backend for the run-monitoring LWCs (`aaoRunMonitor`,
 * `aaoRunDetail`). Returns typed DTOs with large text fields truncated server-side;
 * `getStepDetail` lazy-loads the full request/response text on expand. Cancel routes
 * through `ExecutionLogger.finishRun` so session release, parent resume, and the
 * `RunFinished` UI event all fire exactly as they would for any other termination.
 * @group UI
 */
public with sharing class AgentMonitorController {
  private static final Integer LIST_LIMIT = 50;
  private static final Integer PREVIEW_LENGTH = 500;

  /**
   * @description Lists recent runs for the monitor table, newest first.
   * @param statusFilter Optional `Status__c` value to filter by.
   * @param agentFilter Optional agent DeveloperName to filter by.
   * @return Up to 50 RunSummary rows.
   */
  @AuraEnabled
  public static List<RunSummary> getRuns(
    String statusFilter,
    String agentFilter
  ) {
    String query =
      'SELECT Id, Name, aao__Agent__c, aao__Status__c, aao__Trigger_Type__c, ' +
      'aao__Started_At__c, aao__Finished_At__c, Depth__c, Parent_Run__c, Session__c ' +
      'FROM aao__Agent_Run__c';
    List<String> clauses = new List<String>();
    if (String.isNotBlank(statusFilter)) {
      clauses.add('aao__Status__c = :statusFilter');
    }
    if (String.isNotBlank(agentFilter)) {
      clauses.add('aao__Agent__c = :agentFilter');
    }
    if (!clauses.isEmpty()) {
      query += ' WHERE ' + String.join(clauses, ' AND ');
    }
    query += ' ORDER BY aao__Started_At__c DESC LIMIT ' + LIST_LIMIT;

    List<RunSummary> summaries = new List<RunSummary>();
    for (aao__Agent_Run__c run : Database.query(query)) {
      summaries.add(toSummary(run));
    }
    return summaries;
  }

  /**
   * @description Loads one run's header plus its ordered steps (previews only — use
   * `getStepDetail` for full request/response text).
   * @param runId Id of the Agent_Run__c to load.
   * @return RunDetail DTO with StepSummary children.
   */
  @AuraEnabled
  public static RunDetail getRunDetail(Id runId) {
    aao__Agent_Run__c run = [
      SELECT
        Id,
        Name,
        aao__Agent__c,
        aao__Status__c,
        aao__Trigger_Type__c,
        aao__Input_Context__c,
        aao__Final_Output__c,
        aao__Error_Message__c,
        aao__Started_At__c,
        aao__Finished_At__c,
        Depth__c,
        Parent_Run__c,
        Session__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];

    RunDetail detail = new RunDetail();
    detail.summary = toSummary(run);
    detail.inputContext = truncate(run.aao__Input_Context__c);
    detail.finalOutput = truncate(run.aao__Final_Output__c);
    detail.errorMessage = truncate(run.aao__Error_Message__c);
    detail.steps = new List<StepSummary>();

    for (aao__Agent_Step__c step : [
      SELECT
        Id,
        Name,
        aao__Step_Number__c,
        aao__Step_Type__c,
        aao__Status__c,
        aao__Tool__c,
        aao__Tool_Input__c,
        aao__Tool_Output__c
      FROM aao__Agent_Step__c
      WHERE aao__Agent_Run__c = :runId
      ORDER BY aao__Step_Number__c ASC
    ]) {
      StepSummary s = new StepSummary();
      s.stepId = step.Id;
      s.name = step.Name;
      s.stepNumber = Integer.valueOf(step.aao__Step_Number__c);
      s.stepType = step.aao__Step_Type__c;
      s.status = step.aao__Status__c;
      s.toolName = step.aao__Tool__c;
      s.toolInputPreview = truncate(step.aao__Tool_Input__c);
      s.toolOutputPreview = truncate(step.aao__Tool_Output__c);
      detail.steps.add(s);
    }
    return detail;
  }

  /**
   * @description Lazy-loads one step's full LLM request/response and tool input/output.
   * @param stepId Id of the Agent_Step__c to expand.
   * @return StepDetail with untruncated text.
   */
  @AuraEnabled
  public static StepDetail getStepDetail(Id stepId) {
    aao__Agent_Step__c step = [
      SELECT
        aao__LLM_Request__c,
        aao__LLM_Response__c,
        aao__Tool_Input__c,
        aao__Tool_Output__c
      FROM aao__Agent_Step__c
      WHERE Id = :stepId
      LIMIT 1
    ];
    StepDetail detail = new StepDetail();
    detail.llmRequest = step.aao__LLM_Request__c;
    detail.llmResponse = step.aao__LLM_Response__c;
    detail.toolInput = step.aao__Tool_Input__c;
    detail.toolOutput = step.aao__Tool_Output__c;
    return detail;
  }

  /**
   * @description Walks the run family (root, then all descendants) for the sub-agent tree.
   * @param runId Any run in the family.
   * @return RunSummary rows for the whole family, root first, then by depth/start time.
   */
  @AuraEnabled
  public static List<RunSummary> getRunTree(Id runId) {
    // Walk up to the root.
    Id rootId = runId;
    for (Integer i = 0; i < 5; i++) {
      List<aao__Agent_Run__c> current = [
        SELECT Parent_Run__c
        FROM aao__Agent_Run__c
        WHERE Id = :rootId
        LIMIT 1
      ];
      if (current.isEmpty() || current[0].Parent_Run__c == null) {
        break;
      }
      rootId = current[0].Parent_Run__c;
    }

    // Collect descendants breadth-first (depth is capped at 3 by SubAgentTool).
    List<RunSummary> family = new List<RunSummary>();
    Set<Id> frontier = new Set<Id>{ rootId };
    Set<Id> seen = new Set<Id>();
    for (Integer level = 0; level <= 4 && !frontier.isEmpty(); level++) {
      List<aao__Agent_Run__c> runs = [
        SELECT
          Id,
          Name,
          aao__Agent__c,
          aao__Status__c,
          aao__Trigger_Type__c,
          aao__Started_At__c,
          aao__Finished_At__c,
          Depth__c,
          Parent_Run__c,
          Session__c
        FROM aao__Agent_Run__c
        WHERE
          Id IN :frontier
          OR (Parent_Run__c IN :frontier AND Id NOT IN :seen)
        ORDER BY Depth__c ASC, aao__Started_At__c ASC
      ];
      Set<Id> next = new Set<Id>();
      for (aao__Agent_Run__c run : runs) {
        if (!seen.contains(run.Id)) {
          seen.add(run.Id);
          family.add(toSummary(run));
          next.add(run.Id);
        }
      }
      frontier = next;
    }
    return family;
  }

  /**
   * @description Cancels an in-flight run. The engine's status checks stop the next
   * step from executing; `finishRun` handles session release, parent resume, and the
   * terminal UI event.
   * @param runId Id of the run to cancel.
   */
  @AuraEnabled
  public static void cancelRun(Id runId) {
    aao__Agent_Run__c run = [
      SELECT aao__Status__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
      FOR UPDATE
    ];
    if (run.aao__Status__c != 'Running') {
      throw new AuraHandledException(
        'Only Running runs can be cancelled (current status: ' +
          run.aao__Status__c +
          ').'
      );
    }
    ExecutionLogger.finishRun(runId, null, 'Cancelled', 'Cancelled by user');
  }

  /**
   * @description Starts a fresh run with the same agent and input context.
   * @param runId Id of the run to replay.
   * @return Id of the new run.
   */
  @AuraEnabled
  public static Id rerun(Id runId) {
    aao__Agent_Run__c run = [
      SELECT aao__Agent__c, aao__Input_Context__c
      FROM aao__Agent_Run__c
      WHERE Id = :runId
      LIMIT 1
    ];
    return AgentEngine.runAgent(
      run.aao__Agent__c,
      run.aao__Input_Context__c,
      'UI'
    );
  }

  private static RunSummary toSummary(aao__Agent_Run__c run) {
    RunSummary s = new RunSummary();
    s.runId = run.Id;
    s.name = run.Name;
    s.agentDeveloperName = run.aao__Agent__c;
    s.status = run.aao__Status__c;
    s.triggerType = run.aao__Trigger_Type__c;
    s.startedAt = run.aao__Started_At__c;
    s.finishedAt = run.aao__Finished_At__c;
    s.depth = run.Depth__c == null ? 0 : Integer.valueOf(run.Depth__c);
    s.parentRunId = run.Parent_Run__c;
    s.sessionId = run.Session__c;
    return s;
  }

  private static String truncate(String value) {
    return value == null ? null : value.abbreviate(PREVIEW_LENGTH);
  }

  //
  // ───────────────────────────────────────────────────────────────
  // DTOs
  // ───────────────────────────────────────────────────────────────
  //

  /** @description One run row for the monitor table / tree. */
  public class RunSummary {
    @AuraEnabled
    public Id runId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String agentDeveloperName;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String triggerType;
    @AuraEnabled
    public Datetime startedAt;
    @AuraEnabled
    public Datetime finishedAt;
    @AuraEnabled
    public Integer depth;
    @AuraEnabled
    public Id parentRunId;
    @AuraEnabled
    public Id sessionId;
  }

  /** @description Run header + step previews. */
  public class RunDetail {
    @AuraEnabled
    public RunSummary summary;
    @AuraEnabled
    public String inputContext;
    @AuraEnabled
    public String finalOutput;
    @AuraEnabled
    public String errorMessage;
    @AuraEnabled
    public List<StepSummary> steps;
  }

  /** @description One timeline entry (truncated previews). */
  public class StepSummary {
    @AuraEnabled
    public Id stepId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Integer stepNumber;
    @AuraEnabled
    public String stepType;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String toolName;
    @AuraEnabled
    public String toolInputPreview;
    @AuraEnabled
    public String toolOutputPreview;
  }

  /** @description Full step text, loaded on expand. */
  public class StepDetail {
    @AuraEnabled
    public String llmRequest;
    @AuraEnabled
    public String llmResponse;
    @AuraEnabled
    public String toolInput;
    @AuraEnabled
    public String toolOutput;
  }
}
