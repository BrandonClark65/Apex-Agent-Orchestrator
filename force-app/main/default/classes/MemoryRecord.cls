/**
 * @description Provider-agnostic representation of one memory, decoupling
 * `MemoryProvider` implementations from the `Agent_Memory__c` schema (a vector-store
 * provider round-trips these without touching SObjects).
 * @group Memory
 */
public with sharing class MemoryRecord {
  public Id recordId;
  public String agentDeveloperName;
  public Id userId;
  public String scope; // Session | User | Agent | Global
  public String memoryType; // Fact | Preference | Reflection | Summary
  public String content;
  public String keywords; // comma-separated
  public Id sourceRunId;

  @SuppressWarnings('PMD.EmptyStatementBlock')
  public MemoryRecord() {
  }

  /**
   * @description Convenience constructor for capture paths.
   */
  public MemoryRecord(
    String agentDeveloperName,
    Id userId,
    String scope,
    String memoryType,
    String content,
    String keywords
  ) {
    this.agentDeveloperName = agentDeveloperName;
    this.userId = userId;
    this.scope = scope;
    this.memoryType = memoryType;
    this.content = content;
    this.keywords = keywords;
  }

  /**
   * @description Maps an `Agent_Memory__c` row into the provider-agnostic shape.
   * @param row Queried Agent_Memory__c record.
   * @return Populated MemoryRecord.
   */
  public static MemoryRecord fromSObject(Agent_Memory__c row) {
    MemoryRecord rec = new MemoryRecord();
    rec.recordId = row.Id;
    rec.agentDeveloperName = row.Agent__c;
    rec.userId = row.User__c;
    rec.scope = row.Scope__c;
    rec.memoryType = row.Type__c;
    rec.content = row.Content__c;
    rec.keywords = row.Keywords__c;
    rec.sourceRunId = row.Source_Run__c;
    return rec;
  }

  /**
   * @description Maps this record onto a new `Agent_Memory__c` row for insert.
   * @return Unsaved Agent_Memory__c.
   */
  public Agent_Memory__c toSObject() {
    return new Agent_Memory__c(
      Agent__c = agentDeveloperName,
      User__c = userId,
      Scope__c = scope,
      Type__c = memoryType,
      Content__c = content,
      Keywords__c = keywords,
      Source_Run__c = sourceRunId,
      Is_Active__c = true
    );
  }
}
