/**
 * @description `@AuraEnabled` backend for the `aaoMemoryManager` LWC: users see and curate
 * what agents remember about them; admins curate everything (including Agent-scope
 * lessons and the reflection review flow).
 *
 * Deliberately `without sharing`: memory rows are inserted by `MemoryCaptureQueueable`
 * running as the Automated Process user, so under the object's Private OWD a sharing-
 * enforced query would hide users' own memories from them. Access control is explicit
 * instead — the my-memories path is hard-filtered to `User__c = current user`, and the
 * everything path requires delete permission on `Agent_Memory__c` (granted only by
 * `AAO_Admin`).
 * @group Memory
 */
public without sharing class MemoryManagerController {
  private static final Integer LIST_LIMIT = 200;

  /**
   * @description Whether the running user may manage all memories (drives the admin tab).
   * @return True when the user holds delete permission on Agent_Memory__c (AAO_Admin).
   */
  @AuraEnabled(cacheable=true)
  public static Boolean canManageAll() {
    return Schema.sObjectType.Agent_Memory__c.isDeletable();
  }

  /**
   * @description The running user's own memories (User/Session scope), newest first.
   * @param includeInactive Include soft-deleted rows.
   * @return MemoryInfo rows belonging to the current user.
   */
  @AuraEnabled
  public static List<MemoryInfo> getMyMemories(Boolean includeInactive) {
    Id userId = UserInfo.getUserId();
    List<Agent_Memory__c> rows;
    if (includeInactive == true) {
      rows = [
        SELECT
          Id,
          Name,
          Agent__c,
          Scope__c,
          Type__c,
          Content__c,
          Keywords__c,
          Is_Active__c,
          Access_Count__c,
          Last_Accessed__c,
          CreatedDate
        FROM Agent_Memory__c
        WHERE User__c = :userId
        ORDER BY CreatedDate DESC
        LIMIT :LIST_LIMIT
      ];
    } else {
      rows = [
        SELECT
          Id,
          Name,
          Agent__c,
          Scope__c,
          Type__c,
          Content__c,
          Keywords__c,
          Is_Active__c,
          Access_Count__c,
          Last_Accessed__c,
          CreatedDate
        FROM Agent_Memory__c
        WHERE User__c = :userId AND Is_Active__c = TRUE
        ORDER BY CreatedDate DESC
        LIMIT :LIST_LIMIT
      ];
    }
    return toInfos(rows);
  }

  /**
   * @description All memories, filterable — admin only.
   * @param agentFilter Optional agent DeveloperName.
   * @param typeFilter Optional Type__c value (e.g. 'Reflection' for the lesson review queue).
   * @param includeInactive Include soft-deleted rows.
   * @return MemoryInfo rows across all users and scopes.
   */
  @AuraEnabled
  public static List<MemoryInfo> getAllMemories(
    String agentFilter,
    String typeFilter,
    Boolean includeInactive
  ) {
    requireAdmin();

    String query =
      'SELECT Id, Name, Agent__c, User__c, Scope__c, Type__c, Content__c, Keywords__c, ' +
      'Is_Active__c, Access_Count__c, Last_Accessed__c, CreatedDate ' +
      'FROM Agent_Memory__c';
    List<String> clauses = new List<String>();
    if (String.isNotBlank(agentFilter)) {
      clauses.add('Agent__c = :agentFilter');
    }
    if (String.isNotBlank(typeFilter)) {
      clauses.add('Type__c = :typeFilter');
    }
    if (includeInactive != true) {
      clauses.add('Is_Active__c = TRUE');
    }
    if (!clauses.isEmpty()) {
      query += ' WHERE ' + String.join(clauses, ' AND ');
    }
    query += ' ORDER BY CreatedDate DESC LIMIT ' + LIST_LIMIT;

    return toInfos((List<Agent_Memory__c>) Database.query(query));
  }

  /**
   * @description Activates or deactivates (soft-deletes) a memory. Users may curate their
   * own memories; admins may curate any.
   * @param memoryId Agent_Memory__c Id.
   * @param isActive New Is_Active__c value.
   */
  @AuraEnabled
  public static void setActive(Id memoryId, Boolean isActive) {
    requireOwnershipOrAdmin(memoryId);
    update new Agent_Memory__c(Id = memoryId, Is_Active__c = isActive == true);
  }

  /**
   * @description Permanently deletes a memory. Users may delete their own; admins any.
   * @param memoryId Agent_Memory__c Id.
   */
  @AuraEnabled
  public static void deleteMemory(Id memoryId) {
    requireOwnershipOrAdmin(memoryId);
    delete new Agent_Memory__c(Id = memoryId);
  }

  private static void requireAdmin() {
    if (!Schema.sObjectType.Agent_Memory__c.isDeletable()) {
      throw new AuraHandledException(
        'You do not have permission to manage all agent memories.'
      );
    }
  }

  private static void requireOwnershipOrAdmin(Id memoryId) {
    if (Schema.sObjectType.Agent_Memory__c.isDeletable()) {
      return; // admin
    }
    List<Agent_Memory__c> rows = [
      SELECT User__c
      FROM Agent_Memory__c
      WHERE Id = :memoryId
      LIMIT 1
    ];
    if (rows.isEmpty() || rows[0].User__c != UserInfo.getUserId()) {
      throw new AuraHandledException(
        'You can only manage memories that belong to you.'
      );
    }
  }

  private static List<MemoryInfo> toInfos(List<Agent_Memory__c> rows) {
    List<MemoryInfo> infos = new List<MemoryInfo>();
    for (Agent_Memory__c row : rows) {
      MemoryInfo info = new MemoryInfo();
      info.memoryId = row.Id;
      info.name = row.Name;
      info.agentDeveloperName = row.Agent__c;
      info.scope = row.Scope__c;
      info.memoryType = row.Type__c;
      info.content = row.Content__c;
      info.keywords = row.Keywords__c;
      info.isActive = row.Is_Active__c;
      info.accessCount = row.Access_Count__c == null
        ? 0
        : Integer.valueOf(row.Access_Count__c);
      info.lastAccessed = row.Last_Accessed__c;
      info.createdDate = row.CreatedDate;
      infos.add(info);
    }
    return infos;
  }

  /** @description One memory row for the manager UI. */
  public class MemoryInfo {
    @AuraEnabled
    public Id memoryId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String agentDeveloperName;
    @AuraEnabled
    public String scope;
    @AuraEnabled
    public String memoryType;
    @AuraEnabled
    public String content;
    @AuraEnabled
    public String keywords;
    @AuraEnabled
    public Boolean isActive;
    @AuraEnabled
    public Integer accessCount;
    @AuraEnabled
    public Datetime lastAccessed;
    @AuraEnabled
    public Datetime createdDate;
  }
}
