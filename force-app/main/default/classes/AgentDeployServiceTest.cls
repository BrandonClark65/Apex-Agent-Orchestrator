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
      2,
      container.getMetadata().size(),
      'definition + the granted mapping; Sales_Agent has no existing mapping for the ' +
      'revoked tool, so no dead IsAllowed=false row is written'
    );

    Metadata.CustomMetadata definition = (Metadata.CustomMetadata) container.getMetadata()[0];
    System.assertEquals(
      'aao__Agent_Definition.Sales_Agent',
      definition.fullName
    );
    System.assertEquals('Sales Agent', definition.label);
    Map<String, Object> defValues = valueMap(definition);
    System.assertEquals(
      'You are a sales agent.',
      defValues.get('aao__SystemPrompt__c')
    );
    System.assertEquals('OpenAI_GPT4', defValues.get('aao__LLMProvider__c'));
    System.assertEquals(12, defValues.get('aao__MaxSteps__c'));
    System.assertEquals(
      'Default_Memory',
      defValues.get('aao__MemoryConfig__c')
    );
    System.assertEquals(true, defValues.get('aao__IsActive__c'));

    Metadata.CustomMetadata mapping = (Metadata.CustomMetadata) container.getMetadata()[1];
    System.assertEquals(
      'aao__Agent_Tool_Mapping.Sales_Agent_QuerySalesforceTool',
      mapping.fullName
    );
    Map<String, Object> mapValues = valueMap(mapping);
    System.assertEquals('Sales_Agent', mapValues.get('aao__Agent__c'));
    System.assertEquals('QuerySalesforceTool', mapValues.get('aao__Tool__c'));
    System.assertEquals(true, mapValues.get('aao__IsAllowed__c'));
  }

  @IsTest
  static void testRevokingAnExistingGrantShipsIsAllowedFalse() {
    // CRUD_Agent really is granted DescribeObjectTool, so unchecking it must ship the
    // mapping with IsAllowed=false — Metadata.Operations upserts and cannot delete, so
    // omitting the record would leave the old true row granting the tool.
    AgentDeployService.AgentSaveRequest request = sampleRequest();
    request.developerName = 'CRUD_Agent';
    request.label = 'CRUD Agent';
    AgentDeployService.ToolGrant revoked = new AgentDeployService.ToolGrant();
    revoked.toolDeveloperName = 'DescribeObjectTool';
    revoked.allowed = false;
    request.tools = new List<AgentDeployService.ToolGrant>{ revoked };

    AgentDeployService.deployAgent(request);

    Metadata.DeployContainer container = AgentDeployService.lastDeployedContainer;
    System.assertEquals(
      2,
      container.getMetadata().size(),
      'definition + the flipped mapping'
    );
    Metadata.CustomMetadata mapping = (Metadata.CustomMetadata) container.getMetadata()[1];
    System.assertEquals(
      'aao__Agent_Tool_Mapping.CRUD_Agent_DescribeObjectTool',
      mapping.fullName
    );
    System.assertEquals(
      false,
      valueMap(mapping).get('aao__IsAllowed__c'),
      'an existing grant is revoked by flipping it, not by dropping it'
    );
  }

  @IsTest
  static void testAddingAToolToAnExistingAgentIsAlwaysDeployed() {
    // SubAgentTool is not currently granted to CRUD_Agent — checking it has no record to
    // flip, so the save must create one.
    AgentDeployService.AgentSaveRequest request = sampleRequest();
    request.developerName = 'CRUD_Agent';
    request.label = 'CRUD Agent';
    AgentDeployService.ToolGrant added = new AgentDeployService.ToolGrant();
    added.toolDeveloperName = 'SubAgentTool';
    added.allowed = true;
    request.tools = new List<AgentDeployService.ToolGrant>{ added };

    AgentDeployService.deployAgent(request);

    Metadata.CustomMetadata mapping = (Metadata.CustomMetadata) AgentDeployService.lastDeployedContainer.getMetadata()[1];
    System.assertEquals(
      'aao__Agent_Tool_Mapping.CRUD_Agent_SubAgentTool',
      mapping.fullName
    );
    System.assertEquals(
      true,
      valueMap(mapping).get('aao__IsAllowed__c'),
      'newly granted tools deploy regardless of whether a mapping already existed'
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
    System.assert(
      !recordName.contains('__') && !recordName.endsWith('_'),
      'DeveloperName may not hold consecutive or trailing underscores: ' +
      recordName
    );
  }

  @IsTest
  static void testLongAgentNameKeepsToolMappingsDistinct() {
    // A 29-char agent name leaves only 10 characters for the tool, so plain
    // truncation collapsed every "DescribeOb*" tool onto one fullName and the
    // deployment failed with "duplicate fullName".
    AgentDeployService.AgentSaveRequest request = sampleRequest();
    request.developerName = 'CaseReasonClassificationAgent';
    request.tools = new List<AgentDeployService.ToolGrant>();
    for (
      String toolName : new List<String>{
        'DescribeObjectTool',
        'DescribeObjectFieldsTool',
        'DescribeObjectRelationshipsTool'
      }
    ) {
      AgentDeployService.ToolGrant grant = new AgentDeployService.ToolGrant();
      grant.toolDeveloperName = toolName;
      grant.allowed = true;
      request.tools.add(grant);
    }

    AgentDeployService.deployAgent(request);

    Set<String> fullNames = new Set<String>();
    for (
      Metadata.Metadata record : AgentDeployService.lastDeployedContainer.getMetadata()
    ) {
      fullNames.add(record.fullName);
    }
    System.assertEquals(
      4,
      fullNames.size(),
      'definition + three distinct tool mappings: ' + fullNames
    );
  }

  @IsTest
  static void testMappingNameIsStableAcrossCalls() {
    String rawName = 'CaseReasonClassificationAgent_DescribeObjectTool';
    System.assertEquals(
      AgentDeployService.mappingName(rawName),
      AgentDeployService.mappingName(rawName),
      'the same agent/tool pair always resolves to the same record name'
    );
    System.assertEquals(
      'Sales_Agent_QuerySalesforceTool',
      AgentDeployService.mappingName('Sales_Agent_QuerySalesforceTool'),
      'names within the limit are left untouched'
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
