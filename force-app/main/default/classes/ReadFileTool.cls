/**
 * @description Reads the text content of a single Salesforce File (ContentDocument). Handles
 * text-based files only (see `ALLOWED_EXTENSIONS`); binary/office/image files are rejected with
 * a clear message, since Apex cannot extract their text and the tool step deliberately forbids
 * the external callout that extraction would require. Protects the async transaction's heap by
 * rejecting files over `MAX_FILE_BYTES` *before* their blob is loaded, and protects the model's
 * context window by truncating the returned text to `maxChars`. The queries run in user mode
 * (`WITH USER_MODE`), so a caller can only read files shared with the running user.
 * @group Agent Tools
 */
public with sharing class ReadFileTool implements AgentTool {
  // Reject files larger than this before their VersionData blob is ever loaded, to protect the
  // async transaction's heap. @TestVisible so tests can exercise the gate without a huge blob.
  @TestVisible
  private static Integer MAX_FILE_BYTES = 1000000;

  // Default cap on characters returned to the model; keeps a large text file from flooding the
  // prompt/context window. Overridable per call via the `maxChars` arg.
  private static final Integer DEFAULT_MAX_CHARS = 20000;

  // File extensions we can decode as UTF-8 text in-Apex. Everything else is rejected.
  private static final Set<String> ALLOWED_EXTENSIONS = new Set<String>{
    'txt',
    'csv',
    'tsv',
    'json',
    'md',
    'markdown',
    'xml',
    'html',
    'htm',
    'log',
    'yaml',
    'yml'
  };

  public String getName() {
    return 'ReadFile';
  }

  public String getDescription() {
    return 'Reads the text content of a file attached to a Salesforce record.';
  }

  /**
   * @description Reads and returns the latest version's text for the given ContentDocument.
   * @param args Must contain `contentDocumentId`; may contain `maxChars` (default 20000).
   * @return Success result with `title`, `fileExtension`, `byteSize`, `truncated`, and `text`.
   */
  public AgentToolResult run(Map<String, Object> args) {
    try {
      String contentDocumentId = (String) args.get('contentDocumentId');
      if (String.isBlank(contentDocumentId)) {
        return AgentToolResult.error('Missing contentDocumentId');
      }
      try {
        Id.valueOf(contentDocumentId);
      } catch (Exception e) {
        return AgentToolResult.error(
          'Invalid contentDocumentId: ' + contentDocumentId
        );
      }

      Integer maxChars = DEFAULT_MAX_CHARS;
      Object maxCharsArg = args.get('maxChars');
      if (maxCharsArg != null) {
        try {
          maxChars = Integer.valueOf(String.valueOf(maxCharsArg));
        } catch (Exception ignored) {
          maxChars = DEFAULT_MAX_CHARS;
        }
      }
      if (maxChars <= 0) {
        maxChars = DEFAULT_MAX_CHARS;
      }

      // Metadata first (no blob) so we can gate on size and type before loading VersionData.
      List<ContentVersion> versions = [
        SELECT Id, Title, FileExtension, FileType, ContentSize
        FROM ContentVersion
        WHERE ContentDocumentId = :contentDocumentId AND IsLatest = TRUE
        WITH USER_MODE
        LIMIT 1
      ];
      if (versions.isEmpty()) {
        return AgentToolResult.error(
          'No file found for contentDocumentId ' + contentDocumentId
        );
      }
      ContentVersion meta = versions[0];

      String ext = meta.FileExtension != null
        ? meta.FileExtension.toLowerCase()
        : '';
      if (!ALLOWED_EXTENSIONS.contains(ext)) {
        return AgentToolResult.error(
          'Unsupported file type for reading: ' +
          (String.isBlank(ext) ? meta.FileType : ext) +
          '. Only text-based files can be read (' +
          String.join(new List<String>(ALLOWED_EXTENSIONS), ', ') +
          ').'
        );
      }

      if (meta.ContentSize != null && meta.ContentSize > MAX_FILE_BYTES) {
        return AgentToolResult.error(
          'File is too large to read: ' +
          meta.ContentSize +
          ' bytes (limit ' +
          MAX_FILE_BYTES +
          '). Narrow the request or read a smaller file.'
        );
      }

      // Size and type both OK — now load the blob for this one version.
      ContentVersion full = [
        SELECT VersionData
        FROM ContentVersion
        WHERE Id = :meta.Id
        WITH USER_MODE
        LIMIT 1
      ];

      String text = full.VersionData != null ? full.VersionData.toString() : '';
      Boolean truncated = text.length() > maxChars;
      if (truncated) {
        text = text.substring(0, maxChars);
      }

      return AgentToolResult.success(
        'File read successfully',
        new Map<String, Object>{
          'title' => meta.Title,
          'fileExtension' => meta.FileExtension,
          'byteSize' => meta.ContentSize,
          'truncated' => truncated,
          'text' => text
        }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
