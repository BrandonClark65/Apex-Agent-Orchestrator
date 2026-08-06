/**
 * @description Tests `AgentAccess`: agents are open until `Required_Custom_Permission__c`
 * names a Custom Permission, then only holders get through. `FeatureManagement.checkPermission`
 * cannot be mocked and a test cannot create a Custom Permission to hold, so the "user holds it"
 * branch runs through the class's `heldPermissions` seam; the "does not hold it" branch is
 * exercised against the real API too, since a permission that does not exist returns false.
 * @group Tests
 */
@IsTest
private class AgentAccessTest {
  private static final String PERMISSION = 'AAO_Finance_Agent_Access';

  @IsTest
  static void testUnrestrictedAgentIsOpenToEveryone() {
    // No override: this reads the real Agent_Definition__mdt, where the packaged demo agents
    // leave Required_Custom_Permission__c blank.
    System.assert(
      AgentAccess.hasAccess('CRUD_Agent'),
      'an agent with no required permission is open to every framework user'
    );
    AgentAccess.assertAccess('CRUD_Agent');
  }

  @IsTest
  static void testBlankAndWhitespaceRequirementsAreNotRestrictions() {
    AgentAccess.setRequirements(
      new Map<String, String>{ 'Blank_Agent' => '', 'Space_Agent' => '   ' }
    );
    System.assert(AgentAccess.hasAccess('Blank_Agent'));
    System.assert(
      AgentAccess.hasAccess('Space_Agent'),
      'whitespace is not a permission name'
    );
    System.assert(
      AgentAccess.restrictions().isEmpty(),
      'blank requirements are not reported as restrictions'
    );
  }

  @IsTest
  static void testRestrictedAgentIsDeniedWithoutThePermission() {
    // No heldPermissions seam here, so this goes through FeatureManagement against a custom
    // permission that does not exist in the org - which is exactly the fail-closed case.
    AgentAccess.setRequirements(
      new Map<String, String>{ 'Finance_Agent' => PERMISSION }
    );

    System.assert(
      !AgentAccess.hasAccess('Finance_Agent'),
      'a permission the user does not hold blocks the agent'
    );

    Boolean threw = false;
    try {
      AgentAccess.assertAccess('Finance_Agent');
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assert(threw, 'assertAccess throws for a restricted agent');
  }

  @IsTest
  static void testRestrictedAgentIsAllowedWithThePermission() {
    AgentAccess.setRequirements(
      new Map<String, String>{ 'Finance_Agent' => PERMISSION }
    );
    AgentAccess.heldPermissions = new Set<String>{ PERMISSION };

    System.assert(
      AgentAccess.hasAccess('Finance_Agent'),
      'holding the custom permission grants access'
    );
    AgentAccess.assertAccess('Finance_Agent');
  }

  @IsTest
  static void testRequirementIsTrimmedBeforeTheCheck() {
    AgentAccess.setRequirements(
      new Map<String, String>{ 'Finance_Agent' => '  ' + PERMISSION + '  ' }
    );
    AgentAccess.heldPermissions = new Set<String>{ PERMISSION };

    System.assert(
      AgentAccess.hasAccess('Finance_Agent'),
      'stray whitespace in the field should not lock an agent out'
    );
    System.assertEquals(
      PERMISSION,
      AgentAccess.restrictions().get('Finance_Agent'),
      'restrictions() reports the trimmed name'
    );
  }

  @IsTest
  static void testFilterAccessibleKeepsOrderAndDropsDenied() {
    AgentAccess.setRequirements(
      new Map<String, String>{
        'Open_Agent' => null,
        'Finance_Agent' => PERMISSION,
        'Hr_Agent' => 'AAO_Hr_Agent_Access'
      }
    );
    AgentAccess.heldPermissions = new Set<String>{ PERMISSION };

    List<String> allowed = AgentAccess.filterAccessible(
      new List<String>{ 'Open_Agent', 'Finance_Agent', 'Hr_Agent' }
    );

    System.assertEquals(
      new List<String>{ 'Open_Agent', 'Finance_Agent' },
      allowed,
      'denied agents drop out, the rest keep their order'
    );
  }

  @IsTest
  static void testBlankAgentNameHasNoAccess() {
    System.assert(
      !AgentAccess.hasAccess(null),
      'a null agent name is not an unrestricted agent'
    );
    System.assert(!AgentAccess.hasAccess(''));
  }

  @IsTest
  static void testRestrictionsListsOnlyRestrictedAgents() {
    AgentAccess.setRequirements(
      new Map<String, String>{
        'Open_Agent' => null,
        'Finance_Agent' => PERMISSION
      }
    );

    Map<String, String> restricted = AgentAccess.restrictions();
    System.assertEquals(1, restricted.size());
    System.assertEquals(PERMISSION, restricted.get('Finance_Agent'));
  }
}
