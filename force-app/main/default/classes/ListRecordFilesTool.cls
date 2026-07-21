/**
 * @description Lists the Salesforce Files (ContentDocuments) attached to a record, returning
 * metadata only — never file content. The LLM uses this to discover what is attached and pick
 * a file to read via `ReadFileTool`, instead of paying the heap/context cost of loading blobs
 * up front. The query runs in user mode (`WITH USER_MODE`), so a caller only sees files shared
 * with the running user on records they can access.
 * @group Agent Tools
 */
public with sharing class ListRecordFilesTool implements AgentTool {
  public String getName() {
    return 'ListRecordFiles';
  }

  public String getDescription() {
    return 'Lists the files attached to a Salesforce record (metadata only, no content).';
  }

  /**
   * @description Returns metadata for each file linked to the given record.
   * @param args Must contain `recordId` (the Id of the record whose files to list).
   * @return Success result containing a `files` list of file metadata.
   */
  public AgentToolResult run(Map<String, Object> args) {
    try {
      String recordId = (String) args.get('recordId');
      if (String.isBlank(recordId)) {
        return AgentToolResult.error('Missing recordId');
      }
      try {
        Id.valueOf(recordId);
      } catch (Exception e) {
        return AgentToolResult.error('Invalid recordId: ' + recordId);
      }

      List<ContentDocumentLink> links = [
        SELECT
          ContentDocumentId,
          ContentDocument.Title,
          ContentDocument.FileType,
          ContentDocument.FileExtension,
          ContentDocument.ContentSize,
          ContentDocument.ContentModifiedDate
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :recordId
        WITH USER_MODE
        ORDER BY ContentDocument.ContentModifiedDate DESC
      ];

      List<Map<String, Object>> files = new List<Map<String, Object>>();
      for (ContentDocumentLink link : links) {
        ContentDocument doc = link.ContentDocument;
        files.add(
          new Map<String, Object>{
            'contentDocumentId' => link.ContentDocumentId,
            'title' => doc.Title,
            'fileType' => doc.FileType,
            'fileExtension' => doc.FileExtension,
            'contentSize' => doc.ContentSize,
            'modifiedDate' => doc.ContentModifiedDate
          }
        );
      }

      return AgentToolResult.success(
        files.isEmpty()
          ? 'No files are attached to this record'
          : files.size() + ' file(s) found',
        new Map<String, Object>{ 'files' => files }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
