/**
 * @class       FPOnlyHouseholdReminderServiceTest
 * @description Tests for FPOnlyHouseholdReminderService.
 *              The service depends on org-wide email configuration, so tests use
 *              the @TestVisible bypass hooks to exercise the email assembly logic
 *              deterministically without relying on org metadata.
 *
 * @author      Mindruby Team
 * @date        2026-06-02
 */
@isTest
private class FPOnlyHouseholdReminderServiceTest {

    private static final String TAG_1 = 'FPO_REM_1';
    private static final String TAG_2 = 'FPO_REM_2';
    private static final String TAG_3 = 'FPO_REM_3';
    private static final String TAG_4 = 'FPO_REM_4';
    private static final String TAG_5 = 'FPO_REM_5';
    private static final String TAG_6 = 'FPO_REM_6';
    private static final String TAG_7 = 'FPO_REM_7';
    private static final String TAG_8 = 'FPO_REM_8';
    private static final String TAG_9 = 'FPO_REM_9';
    private static final String TAG_10 = 'FPO_REM_10';
    private static final String TAG_11 = 'FPO_REM_11';
    private static final String TAG_SKIP = 'FPO_SKIP';

    @TestSetup
    static void makeData() {
        List<Account> accounts = new List<Account>{
            TestDataFactory.createWMHouseholdAccount(TAG_1, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_2, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_3, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_4, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_5, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_6, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_7, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_8, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_9, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_10, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_11, null, 20, 'C', true),
            TestDataFactory.createWMHouseholdAccount(TAG_SKIP, null, 20, 'C', true)
        };

        List<Account> toUpdate = new List<Account>();
        for (Account acc : accounts) {
            Account updateAcc = new Account(Id = acc.Id);
            updateAcc.Client_Type__c = acc.External_System_ID__c == TAG_SKIP ? 'Wealth Management' : 'FP Only';
            updateAcc.Segmentation__c = acc.External_System_ID__c == TAG_SKIP ? 'C' : 'C';
            updateAcc.Quad_Meeting_Creation_Pending__c = acc.External_System_ID__c == TAG_SKIP;
            toUpdate.add(updateAcc);
        }
        update toUpdate;
    }

    private static List<Account> getEligibleAccounts() {
        return [
            SELECT Id, Name, OwnerId, Owner.Email, Owner.FirstName, Segmentation__c,
                   Client_Type__c, Quad_Meeting_Creation_Pending__c
            FROM   Account
            WHERE  External_System_ID__c LIKE 'FPO_REM_%'
            ORDER BY External_System_ID__c
        ];
    }

    private static List<Account> getSkippedAccounts() {
        return [
            SELECT Id, Name, OwnerId, Owner.Email, Owner.FirstName, Segmentation__c,
                   Client_Type__c, Quad_Meeting_Creation_Pending__c
            FROM   Account
            WHERE  External_System_ID__c = :TAG_SKIP
            LIMIT  1
        ];
    }

    private static void resetHooks() {
        FPOnlyHouseholdReminderService.bypassOrgWideLookup = false;
        FPOnlyHouseholdReminderService.bypassEmailSend = false;
        FPOnlyHouseholdReminderService.capturedEmails.clear();
    }

    @isTest
    static void testSendReminders_firstNotice_buildsOneEmailForElevenAccounts() {
        List<Account> eligibleAccounts = getEligibleAccounts();
        System.assertEquals(11, eligibleAccounts.size(),
            'Test setup must create 11 eligible FP Only Accounts');

        FPOnlyHouseholdReminderService.bypassOrgWideLookup = true;
        FPOnlyHouseholdReminderService.bypassEmailSend = true;

        Test.startTest();
        FPOnlyHouseholdReminderService.sendReminders(false);
        Test.stopTest();

        System.assertEquals(1, FPOnlyHouseholdReminderService.capturedEmails.size(),
            'All Accounts for the same owner should produce one email');

        Messaging.SingleEmailMessage email = FPOnlyHouseholdReminderService.capturedEmails[0];
        System.assert(email.getSubject().contains('segmentation window is open'),
            'First notice subject must indicate the window is open');
        System.assertEquals(1, email.getToAddresses().size(),
            'The email must be addressed to the owner only once');
        System.assert(email.getHtmlBody().contains('YOUR FP ONLY HOUSEHOLDS'),
            'The first notice body must render the FP Only households section');
        System.assert(email.getHtmlBody().contains('There might be additional records not shown in this email.'),
            'The first notice must mention when more than 10 households exist');

        resetHooks();
    }

    @isTest
    static void testSendReminders_finalNotice_buildsOneEmailForElevenAccounts() {
        FPOnlyHouseholdReminderService.bypassOrgWideLookup = true;
        FPOnlyHouseholdReminderService.bypassEmailSend = true;

        Test.startTest();
        FPOnlyHouseholdReminderService.sendReminders(true);
        Test.stopTest();

        System.assertEquals(1, FPOnlyHouseholdReminderService.capturedEmails.size(),
            'All Accounts for the same owner should produce one email');

        Messaging.SingleEmailMessage email = FPOnlyHouseholdReminderService.capturedEmails[0];
        System.assert(email.getSubject().contains('Final Notice'),
            'Final notice subject must indicate the closing window');
        System.assert(email.getHtmlBody().contains('NOTICE 02 · FINAL'),
            'Final notice body must render the final notice banner');
        System.assert(email.getHtmlBody().contains('The window closes in'),
            'Final notice body must include the days-left message');

        resetHooks();
    }

    @isTest
    static void testSendReminders_skipsNonQualifyingAccounts() {
        List<Account> skipped = getSkippedAccounts();
        System.assertEquals(1, skipped.size(), 'Test setup must create one skipped Account');

        FPOnlyHouseholdReminderService.bypassOrgWideLookup = true;
        FPOnlyHouseholdReminderService.bypassEmailSend = true;

        Test.startTest();
        FPOnlyHouseholdReminderService.sendReminders(false);
        Test.stopTest();

        System.assertEquals(1, FPOnlyHouseholdReminderService.capturedEmails.size(),
            'The skipped Account must not affect the eligible email group');
        resetHooks();
    }
}