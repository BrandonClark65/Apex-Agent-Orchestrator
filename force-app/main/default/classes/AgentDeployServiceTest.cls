/**
 * @description Tests `AgentDeployService` container construction (deployments themselves
 * cannot run in tests — the enqueue is bypassed and the built container inspected),
 * request validation, the controller entry point, and `AgentDeployCallback` result
 * handling.
 * @group Tests
 */
@IsTest
private class AgentDeployServiceTest {
  private static AgentDeployService.AgentSaveRequest sampleRequest() {
    AgentDeployService.AgentSaveRequest request = new AgentDeployService.AgentSaveRequest();
    request.developerName = 'Sales_Agent';
    request.label = 'Sales Agent';
    request.goal = 'Help with sales data';
    request.systemPrompt = 'You are a sales agent.';
    request.llmProvider = 'OpenAI_GPT4';
    request.maxSteps = 12;
    request.memoryConfig = 'Default_Memory';
    request.isActive = true;

    AgentDeployService.ToolGrant granted = new AgentDeployService.ToolGrant();
    granted.toolDeveloperName = 'QuerySalesforceTool';
    granted.allowed = true;
    AgentDeployService.ToolGrant revoked = new AgentDeployService.ToolGrant();
    revoked.toolDeveloperName = 'UpdateRecordTool';
    revoked.allowed = false;
    request.tools = new List<AgentDeployService.ToolGrant>{ granted, revoked };
    return request;
  }

  @IsTest
  static void testContainerConstruction() {
    Id jobId = AgentDeployService.deployAgent(sampleRequest());
    System.assertEquals(null, jobId, 'enqueue bypassed in tests');

    Metadata.DeployContainer container = AgentDeployService.lastDeployedContainer;
    System.assertEquals(
      3,
      container.getMetadata().size(),
      'definition + two tool mappings'
    );

    Metadata.CustomMetadata definition = (Metadata.CustomMetadata) container.getMetadata()[0];
    System.assertEquals('Agent_Definition.Sales_Agent', definition.fullName);
    System.assertEquals('Sales Agent', definition.label);
    Map<String, Object> defValues = valueMap(definition);
    System.assertEquals('You are a sales agent.', defValues.get('SystemPrompt__c'));
    System.assertEquals('OpenAI_GPT4', defValues.get('LLMProvider__c'));
    System.assertEquals(12, defValues.get('MaxSteps__c'));
    System.assertEquals('Default_Memory', defValues.get('MemoryConfig__c'));
    System.assertEquals(true, defValues.get('IsActive__c'));

    Metadata.CustomMetadata mapping = (Metadata.CustomMetadata) container.getMetadata()[1];
    System.assertEquals(
      'Agent_Tool_Mapping.Sales_Agent_QuerySalesforceTool',
      mapping.fullName
    );
    Map<String, Object> mapValues = valueMap(mapping);
    System.assertEquals('Sales_Agent', mapValues.get('Agent__c'));
    System.assertEquals('QuerySalesforceTool', mapValues.get('Tool__c'));
    System.assertEquals(true, mapValues.get('IsAllowed__c'));

    Metadata.CustomMetadata revokedMapping = (Metadata.CustomMetadata) container.getMetadata()[2];
    System.assertEquals(
      false,
      valueMap(revokedMapping).get('IsAllowed__c'),
      'revoked grants deploy with IsAllowed=false rather than being skipped'
    );
  }

  @IsTest
  static void testMappingNameTruncatedTo40() {
    AgentDeployService.AgentSaveRequest request = sampleRequest();
    request.developerName = 'A_Very_Long_Agent_Developer_Name_Here';
    Id jobId = AgentDeployService.deployAgent(request);
    System.assertEquals(null, jobId);

    Metadata.CustomMetadata mapping = (Metadata.CustomMetadata) AgentDeployService.lastDeployedContainer.getMetadata()[1];
    String recordName = mapping.fullName.substringAfter('.');
    System.assert(
      recordName.length() <= 40,
      'CMDT DeveloperName capped at 40 chars: ' + recordName
    );
  }

  @IsTest
  static void testValidationRejectsBadRequests() {
    AgentDeployService.AgentSaveRequest missingName = sampleRequest();
    missingName.developerName = null;
    try {
      AgentDeployService.deployAgent(missingName);
      System.assert(false, 'expected validation failure');
    } catch (AuraHandledException e) {
      System.assert(true);
    }

    AgentDeployService.AgentSaveRequest badName = sampleRequest();
    badName.developerName = '1 bad name!';
    try {
      AgentDeployService.deployAgent(badName);
      System.assert(false, 'expected validation failure');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @IsTest
  static void testControllerEntryPoint() {
    String jobId = AgentBuilderController.saveAgent(
      JSON.serialize(sampleRequest())
    );
    System.assertEquals(null, jobId, 'null inside tests');
    System.assertNotEquals(
      null,
      AgentDeployService.lastDeployedContainer,
      'container built via the controller path'
    );

    System.assert(
      !AgentBuilderController.getProviderOptions().isEmpty(),
      'provider options come from LLM_Provider__mdt'
    );
    System.assert(
      !AgentBuilderController.getMemoryConfigOptions().isEmpty(),
      'memory options come from Memory_Config__mdt'
    );
  }

  @IsTest
  static void testCallbackHandlesResults() {
    AgentDeployCallback callback = new AgentDeployCallback();

    Metadata.DeployResult success = new Metadata.DeployResult();
    success.status = Metadata.DeployStatus.SUCCEEDED;
    callback.handleResult(success, null);

    Metadata.DeployResult failure = new Metadata.DeployResult();
    failure.status = Metadata.DeployStatus.FAILED;
    callback.handleResult(failure, null);

    callback.handleResult(null, null);
    System.assert(true, 'callback never throws');
  }

  private static Map<String, Object> valueMap(Metadata.CustomMetadata record) {
    Map<String, Object> values = new Map<String, Object>();
    for (Metadata.CustomMetadataValue v : record.values) {
      values.put(v.field, v.value);
    }
    return values;
  }
}
