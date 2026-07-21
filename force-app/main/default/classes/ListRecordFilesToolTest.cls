/**
 * @description Tests `ListRecordFilesTool`: listing files attached to a record, the empty case,
 * and missing/invalid `recordId` args.
 * @group Tests
 */
@IsTest
private class ListRecordFilesToolTest {
  // Attaches a file with the given title/name to a record and returns its ContentDocumentId.
  private static Id attachFile(Id recordId, String title, String pathOnClient) {
    ContentVersion cv = new ContentVersion(
      Title = title,
      PathOnClient = pathOnClient,
      VersionData = Blob.valueOf('hello world')
    );
    insert cv;
    Id docId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      LinkedEntityId = recordId,
      ContentDocumentId = docId,
      ShareType = 'V',
      Visibility = 'AllUsers'
    );
    return docId;
  }

  @IsTest
  static void testGetNameAndDescription() {
    ListRecordFilesTool tool = new ListRecordFilesTool();
    System.assertEquals('ListRecordFiles', tool.getName());
    System.assertEquals(
      'Lists the files attached to a Salesforce record (metadata only, no content).',
      tool.getDescription()
    );
  }

  @IsTest
  static void testListReturnsFiles() {
    Account acct = new Account(Name = 'File Owner');
    insert acct;
    attachFile(acct.Id, 'Notes', 'notes.txt');

    Test.startTest();
    AgentToolResult result = new ListRecordFilesTool()
      .run(new Map<String, Object>{ 'recordId' => acct.Id });
    Test.stopTest();

    System.assert(result.success, result.message);
    List<Object> files = (List<Object>) result.data.get('files');
    System.assertEquals(1, files.size());
    Map<String, Object> f = (Map<String, Object>) files[0];
    System.assertEquals('Notes', f.get('title'));
    System.assertEquals('txt', f.get('fileExtension'));
    System.assertNotEquals(null, f.get('contentDocumentId'));
  }

  @IsTest
  static void testNoFilesReturnsEmptyList() {
    Account acct = new Account(Name = 'No Files');
    insert acct;

    AgentToolResult result = new ListRecordFilesTool()
      .run(new Map<String, Object>{ 'recordId' => acct.Id });

    System.assert(result.success, result.message);
    List<Object> files = (List<Object>) result.data.get('files');
    System.assertEquals(0, files.size());
    System.assertEquals('No files are attached to this record', result.message);
  }

  @IsTest
  static void testMissingRecordId() {
    AgentToolResult result = new ListRecordFilesTool()
      .run(new Map<String, Object>());

    System.assertEquals(false, result.success);
    System.assertEquals('Missing recordId', result.message);
  }

  @IsTest
  static void testInvalidRecordId() {
    AgentToolResult result = new ListRecordFilesTool()
      .run(new Map<String, Object>{ 'recordId' => 'not-an-id' });

    System.assertEquals(false, result.success);
    System.assert(result.message.startsWith('Invalid recordId'));
  }
}
