/**
 * @class       QuadMeetingServiceTest
 * @description Tests for QuadMeetingService.
 *              Uses TestDataFactory for Account creation and verifies the annual,
 *              mid-year, archival, duplicate-prevention, and weekend-adjustment paths.
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class QuadMeetingServiceTest {

    private static final String TAG_A = 'QMS_A';
    private static final String TAG_B = 'QMS_B';
    private static final String TAG_C = 'QMS_C';

    private static List<Account> createAccounts() {
        return new List<Account>{
            TestDataFactory.createWMHouseholdAccount(TAG_A, null, 20, 'A', true),
            TestDataFactory.createWMHouseholdAccount(TAG_B, null, 20, 'B', true),
            TestDataFactory.createWMHouseholdAccount(TAG_C, null, 20, 'C', true)
        };
    }

    private static Integer meetingCount(Id accountId) {
        return [
            SELECT COUNT()
            FROM   Quad_Meeting__c
            WHERE  Client_Account__c = :accountId
        ];
    }

    private static Quad_Meeting__c getFirstMeeting(Id accountId) {
        return [
            SELECT Id,
                   Expiration_Date__c,
                   Meeting_Status__c,
                   Incomplete_Reason__c
            FROM   Quad_Meeting__c
            WHERE  Client_Account__c = :accountId
            ORDER BY CreatedDate ASC
            LIMIT  1
        ];
    }

    private static Account getAccountByTag(String tag) {
        return [
            SELECT Id,
                   Segmentation_Lock_Date__c,
                   Quad_Meeting_Creation_Pending__c
            FROM   Account
            WHERE  External_System_ID__c = :tag
            LIMIT  1
        ];
    }

    @isTest
    static void testCreateAnnualQuadMeetings_createsExpectedRecordsAndLocksAccounts() {
        List<Account> accounts = createAccounts();
        Id accountA = accounts[0].Id;
        Id accountB = accounts[1].Id;
        Id accountC = accounts[2].Id;

        Test.startTest();
        QuadMeetingService.createAnnualQuadMeetings(new Set<Id>{ accountA, accountB, accountC });
        Test.stopTest();

        System.assertEquals(4, meetingCount(accountA),
            'Segmentation A must create four annual Quad Meetings');
        System.assertEquals(2, meetingCount(accountB),
            'Segmentation B must create two annual Quad Meetings');
        System.assertEquals(1, meetingCount(accountC),
            'Segmentation C must create one annual Quad Meeting');

        Account accountAAfter = getAccountByTag(TAG_A);
        Account accountBAfter = getAccountByTag(TAG_B);
        Account accountCAfter = getAccountByTag(TAG_C);

        System.assertEquals(Date.today(), accountAAfter.Segmentation_Lock_Date__c,
            'Annual creation must lock processed Accounts');
        System.assertEquals(Date.today(), accountBAfter.Segmentation_Lock_Date__c,
            'Annual creation must lock processed Accounts');
        System.assertEquals(Date.today(), accountCAfter.Segmentation_Lock_Date__c,
            'Annual creation must lock processed Accounts');
        System.assertEquals(false, accountAAfter.Quad_Meeting_Creation_Pending__c,
            'Annual creation must clear the pending flag');
        System.assertEquals(false, accountBAfter.Quad_Meeting_Creation_Pending__c,
            'Annual creation must clear the pending flag');
        System.assertEquals(false, accountCAfter.Quad_Meeting_Creation_Pending__c,
            'Annual creation must clear the pending flag');
    }

    @isTest
    static void testCreateAnnualQuadMeetings_skipsAccountsWithMeetingsThisYear() {
        List<Account> accounts = createAccounts();
        Id accountA = accounts[0].Id;

        Test.startTest();
        QuadMeetingService.createAnnualQuadMeetings(new Set<Id>{ accountA });
        QuadMeetingService.createAnnualQuadMeetings(new Set<Id>{ accountA });
        Test.stopTest();

        System.assertEquals(4, meetingCount(accountA),
            'The second annual run must skip an Account that already has meetings this year');

        Set<Id> existing = QuadMeetingService.getAccountsWithMeetingsThisYear(new Set<Id>{ accountA });
        System.assertEquals(1, existing.size(),
            'The helper must report Accounts that already have current-year meetings');
        System.assert(existing.contains(accountA),
            'The helper must include the Account that already has meetings');
    }

    @isTest
    static void testCreateMidYearQuadMeetings_createsExpectedRecordsForCurrentDate() {
        List<Account> accounts = createAccounts();
        Id accountA = accounts[0].Id;
        Id accountB = accounts[1].Id;
        Id accountC = accounts[2].Id;

        Test.startTest();
        QuadMeetingService.createMidYearQuadMeetings(new Set<Id>{ accountA, accountB, accountC });
        Test.stopTest();

        System.assertEquals(3, meetingCount(accountA),
            'On the current date, segmentation A must create Intro + remaining quarters');
        System.assertEquals(2, meetingCount(accountB),
            'On the current date, segmentation B must create Intro + H2');
        System.assertEquals(1, meetingCount(accountC),
            'Segmentation C must create Intro only');
    }

    @isTest
    static void testArchiveExpiredMeetings_archivesMeetingAndSetsReason() {
        List<Account> accounts = createAccounts();
        Id accountC = accounts[2].Id;

        QuadMeetingService.createAnnualQuadMeetings(new Set<Id>{ accountC });

        Quad_Meeting__c meeting = getFirstMeeting(accountC);
        meeting.Expiration_Date__c = Date.today().addDays(-1);
        update meeting;

        Test.startTest();
        QuadMeetingService.archiveExpiredMeetings(new Set<Id>{ meeting.Id });
        Test.stopTest();

        Quad_Meeting__c archived = [
            SELECT Meeting_Status__c, Incomplete_Reason__c
            FROM   Quad_Meeting__c
            WHERE  Id = :meeting.Id
        ];
        System.assertEquals('Archived', archived.Meeting_Status__c,
            'archiveExpiredMeetings must archive expired meetings');
        System.assertEquals('Updated by Automation', archived.Incomplete_Reason__c,
            'archiveExpiredMeetings must stamp the automation reason');
    }

    @isTest
    static void testAdjustForWeekend_rollsSaturdayAndSundayToMonday() {
        Date saturday = Date.newInstance(2026, 5, 30);
        Date sunday   = Date.newInstance(2026, 5, 31);

        System.assertEquals(Date.newInstance(2026, 6, 1), QuadMeetingService.adjustForWeekend(saturday),
            'Saturday must roll forward to Monday');
        System.assertEquals(Date.newInstance(2026, 6, 1), QuadMeetingService.adjustForWeekend(sunday),
            'Sunday must roll forward to Monday');
    }
}