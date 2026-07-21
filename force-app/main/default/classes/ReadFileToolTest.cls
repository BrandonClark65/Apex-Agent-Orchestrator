/**
 * @description Tests `ReadFileTool`: reading text content, truncation, the unsupported-type and
 * oversized-file gates, not-found, and missing/invalid `contentDocumentId` args.
 * @group Tests
 */
@IsTest
private class ReadFileToolTest {
  // Attaches a file with the given name/body to a record and returns its ContentDocumentId.
  private static Id attachFile(
    Id recordId,
    String title,
    String pathOnClient,
    String body
  ) {
    ContentVersion cv = new ContentVersion(
      Title = title,
      PathOnClient = pathOnClient,
      VersionData = Blob.valueOf(body)
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
    ReadFileTool tool = new ReadFileTool();
    System.assertEquals('ReadFile', tool.getName());
    System.assertEquals(
      'Reads the text content of a file attached to a Salesforce record.',
      tool.getDescription()
    );
  }

  @IsTest
  static void testReadReturnsText() {
    Account acct = new Account(Name = 'Reader');
    insert acct;
    Id docId = attachFile(acct.Id, 'Notes', 'notes.txt', 'hello world');

    AgentToolResult result = new ReadFileTool()
      .run(new Map<String, Object>{ 'contentDocumentId' => docId });

    System.assert(result.success, result.message);
    System.assertEquals('hello world', result.data.get('text'));
    System.assertEquals(false, result.data.get('truncated'));
    System.assertEquals('txt', result.data.get('fileExtension'));
  }

  @IsTest
  static void testTruncation() {
    Account acct = new Account(Name = 'Reader');
    insert acct;
    Id docId = attachFile(acct.Id, 'Big', 'big.txt', 'abcdefghij');

    AgentToolResult result = new ReadFileTool()
      .run(
        new Map<String, Object>{
          'contentDocumentId' => docId,
          'maxChars' => 4
        }
      );

    System.assert(result.success, result.message);
    System.assertEquals('abcd', result.data.get('text'));
    System.assertEquals(true, result.data.get('truncated'));
  }

  @IsTest
  static void testUnsupportedType() {
    Account acct = new Account(Name = 'Reader');
    insert acct;
    Id docId = attachFile(acct.Id, 'Doc', 'report.pdf', '%PDF-1.4 fake');

    AgentToolResult result = new ReadFileTool()
      .run(new Map<String, Object>{ 'contentDocumentId' => docId });

    System.assertEquals(false, result.success);
    System.assert(
      result.message.startsWith('Unsupported file type for reading'),
      result.message
    );
  }

  @IsTest
  static void testFileTooLarge() {
    Account acct = new Account(Name = 'Reader');
    insert acct;
    Id docId = attachFile(acct.Id, 'Notes', 'notes.txt', 'hello world');

    // Dial the heap gate below the file's size so the guard trips without a huge blob.
    ReadFileTool.MAX_FILE_BYTES = 5;

    AgentToolResult result = new ReadFileTool()
      .run(new Map<String, Object>{ 'contentDocumentId' => docId });

    System.assertEquals(false, result.success);
    System.assert(
      result.message.startsWith('File is too large to read'),
      result.message
    );
  }

  @IsTest
  static void testFileNotFound() {
    // A syntactically valid Id of the wrong type matches no ContentVersion.
    Account acct = new Account(Name = 'Reader');
    insert acct;

    AgentToolResult result = new ReadFileTool()
      .run(new Map<String, Object>{ 'contentDocumentId' => acct.Id });

    System.assertEquals(false, result.success);
    System.assert(result.message.startsWith('No file found'), result.message);
  }

  @IsTest
  static void testMissingContentDocumentId() {
    AgentToolResult result = new ReadFileTool().run(new Map<String, Object>());

    System.assertEquals(false, result.success);
    System.assertEquals('Missing contentDocumentId', result.message);
  }

  @IsTest
  static void testInvalidContentDocumentId() {
    AgentToolResult result = new ReadFileTool()
      .run(new Map<String, Object>{ 'contentDocumentId' => 'not-an-id' });

    System.assertEquals(false, result.success);
    System.assert(result.message.startsWith('Invalid contentDocumentId'));
  }
}
