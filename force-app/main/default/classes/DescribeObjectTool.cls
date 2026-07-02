/**
 * @description Returns describe metadata (label, type, and CRU flags) for every field on a
 * given sObject, so the LLM can discover valid field names before calling
 * `CreateRecordTool`/`UpdateRecordTool`/`QuerySalesforceTool`.
 * @group Agent Tools
 */
public with sharing class DescribeObjectTool implements AgentTool {
  public String getName() {
    return 'DescribeObjectTool';
  }

  public String getDescription() {
    return 'Returns metadata about an sObject, including fields, types, and updateability.';
  }

  /**
   * @description Describes every field on the requested sObject.
   * @param args Must contain `object` (sObject API name).
   * @return Success result containing object and a fields map of API name to {label, type, updateable, createable, nillable}.
   */
  public AgentToolResult run(Map<String, Object> args) {
    try {
      String objectName = (String) args.get('object');
      Schema.SObjectType typeRef = Schema.getGlobalDescribe().get(objectName);

      if (typeRef == null) {
        return AgentToolResult.error('Object not found: ' + objectName);
      }

      Schema.DescribeSObjectResult describe = typeRef.getDescribe();
      Map<String, Schema.SObjectField> fields = describe.fields.getMap();

      Map<String, Object> fieldInfo = new Map<String, Object>();

      for (String apiName : fields.keySet()) {
        Schema.DescribeFieldResult f = fields.get(apiName).getDescribe();

        fieldInfo.put(
          apiName,
          new Map<String, Object>{
            'label' => f.getLabel(),
            'type' => f.getType().name(),
            'updateable' => f.isUpdateable(),
            'createable' => f.isCreateable(),
            'nillable' => f.isNillable()
          }
        );
      }

      return AgentToolResult.success(
        'Object described successfully',
        new Map<String, Object>{ 'object' => objectName, 'fields' => fieldInfo }
      );
    } catch (Exception e) {
      return AgentToolResult.error(e.getMessage());
    }
  }
}
