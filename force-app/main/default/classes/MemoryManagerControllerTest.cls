/**
 * @description Tests `MemoryManagerController`: my-memories scoping, admin all-memories
 * filters, curation (activate/deactivate/delete) with the ownership-or-admin guard, and
 * the non-admin rejection path via a minimal-permission `System.runAs` user.
 * @group Tests
 */
@IsTest
private class MemoryManagerControllerTest {
  private static Agent_Memory__c makeMemory(
    Id userId,
    String scope,
    String memoryType,
    String content
  ) {
    return new Agent_Memory__c(
      Agent__c = 'CRUD_Agent',
      User__c = userId,
      Scope__c = scope,
      Type__c = memoryType,
      Content__c = content,
      Is_Active__c = true
    );
  }

  private static User makeMinimalUser() {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce'
      LIMIT 1
    ];
    User u = new User(
      Alias = 'aaomin',
      Email = 'aao.min@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Minimal',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = 'aao.min.' + System.currentTimeMillis() + '@example.com'
    );
    insert u;
    return u;
  }

  @IsTest
  static void testGetMyMemoriesScopesToRunningUser() {
    User other = makeMinimalUser();
    insert new List<Agent_Memory__c>{
      makeMemory(UserInfo.getUserId(), 'User', 'Preference', 'Mine'),
      makeMemory(other.Id, 'User', 'Preference', 'Theirs')
    };

    List<MemoryManagerController.MemoryInfo> mine = MemoryManagerController.getMyMemories(
      false
    );
    System.assertEquals(1, mine.size());
    System.assertEquals('Mine', mine[0].content);
  }

  @IsTest
  static void testIncludeInactiveToggle() {
    Agent_Memory__c inactive = makeMemory(
      UserInfo.getUserId(),
      'User',
      'Fact',
      'Old fact'
    );
    inactive.Is_Active__c = false;
    insert new List<Agent_Memory__c>{
      makeMemory(UserInfo.getUserId(), 'User', 'Fact', 'Current fact'),
      inactive
    };

    System.assertEquals(
      1,
      MemoryManagerController.getMyMemories(false).size(),
      'inactive hidden by default'
    );
    System.assertEquals(
      2,
      MemoryManagerController.getMyMemories(true).size(),
      'inactive shown when requested'
    );
  }

  @IsTest
  static void testGetAllMemoriesFiltersAsAdmin() {
    insert new List<Agent_Memory__c>{
      makeMemory(UserInfo.getUserId(), 'User', 'Fact', 'A fact'),
      makeMemory(null, 'Agent', 'Reflection', 'A lesson')
    };

    // Running user (sysadmin in tests) has delete permission -> admin path.
    List<MemoryManagerController.MemoryInfo> reflections = MemoryManagerController.getAllMemories(
      'CRUD_Agent',
      'Reflection',
      false
    );
    System.assertEquals(1, reflections.size());
    System.assertEquals('A lesson', reflections[0].content);

    System.assertEquals(
      2,
      MemoryManagerController.getAllMemories(null, null, false).size()
    );
  }

  @IsTest
  static void testCurationTogglesAndDeletes() {
    Agent_Memory__c mine = makeMemory(
      UserInfo.getUserId(),
      'User',
      'Preference',
      'Toggle me'
    );
    insert mine;

    MemoryManagerController.setActive(mine.Id, false);
    System.assertEquals(
      false,
      [SELECT Is_Active__c FROM Agent_Memory__c WHERE Id = :mine.Id]
      .Is_Active__c
    );

    MemoryManagerController.setActive(mine.Id, true);
    System.assertEquals(
      true,
      [SELECT Is_Active__c FROM Agent_Memory__c WHERE Id = :mine.Id]
      .Is_Active__c
    );

    MemoryManagerController.deleteMemory(mine.Id);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Agent_Memory__c WHERE Id = :mine.Id]
    );
  }

  @IsTest
  static void testNonAdminCannotTouchOthersMemories() {
    User minimal = makeMinimalUser();
    Agent_Memory__c someoneElses = makeMemory(
      UserInfo.getUserId(),
      'User',
      'Fact',
      'Not yours'
    );
    insert someoneElses;

    System.runAs(minimal) {
      System.assertEquals(
        false,
        MemoryManagerController.canManageAll(),
        'minimal user is not an admin'
      );
      try {
        MemoryManagerController.getAllMemories(null, null, false);
        System.assert(false, 'expected admin guard to throw');
      } catch (AuraHandledException e) {
        System.assert(true);
      }
      try {
        MemoryManagerController.deleteMemory(someoneElses.Id);
        System.assert(false, 'expected ownership guard to throw');
      } catch (AuraHandledException e) {
        System.assert(true);
      }
    }
  }

  @IsTest
  static void testUserCanCurateOwnMemoriesWithoutAdmin() {
    User minimal = makeMinimalUser();
    Agent_Memory__c theirs = makeMemory(
      minimal.Id,
      'User',
      'Preference',
      'Their memory'
    );
    insert theirs;

    System.runAs(minimal) {
      List<MemoryManagerController.MemoryInfo> mine = MemoryManagerController.getMyMemories(
        false
      );
      System.assertEquals(
        1,
        mine.size(),
        'without-sharing path shows the user their own memories despite Private OWD'
      );

      MemoryManagerController.setActive(theirs.Id, false);
    }
    System.assertEquals(
      false,
      [SELECT Is_Active__c FROM Agent_Memory__c WHERE Id = :theirs.Id]
      .Is_Active__c,
      'owner may curate without admin permission'
    );
  }
}
