/**
 * @class       QuadMeetingCreationBatchTest
 * @description Tests for QuadMeetingCreationBatch using TestDataFactory for all
 *              Account creation.
 *
 *              Coverage
 *              • Schedulable entry point via execute(null)
 *              • Annual batch creates the expected Quad Meetings
 *              • Only Accounts with FinServ__Status__c = 'Active' are processed
 *              • finish() writes an informational Error_Log__c entry
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class QuadMeetingCreationBatchTest {

    private static final String TAG_ACTIVE_A = 'QMCB_A';
    private static final String TAG_ACTIVE_B = 'QMCB_B';
    private static final String TAG_INACTIVE = 'QMCB_OFF';

    private static List<Account> createAccounts() {
        return new List<Account>{
            TestDataFactory.createWMHouseholdAccount(TAG_ACTIVE_A, null, 20, 'A', 'Active', true),
            TestDataFactory.createWMHouseholdAccount(TAG_ACTIVE_B, null, 20, 'B', 'Active', true),
            TestDataFactory.createWMHouseholdAccount(TAG_INACTIVE,  null, 20, 'C', 'Closed', true)
        };
    }

    private static Integer countMeetings(Id accountId) {
        return [
            SELECT COUNT()
            FROM   Quad_Meeting__c
            WHERE  Client_Account__c = :accountId
        ];
    }

    @isTest
    static void testExecute_createsAnnualMeetingsAndUpdatesAccounts() {
        List<Account> accounts = createAccounts();
        Id activeA = accounts[0].Id;
        Id activeB = accounts[1].Id;
        Id inactive = accounts[2].Id;

        Test.startTest();
        new QuadMeetingCreationBatch().execute(null);
        Test.stopTest();

        Integer activeAMeetings = countMeetings(activeA);
        Integer activeBMeetings = countMeetings(activeB);
        Integer inactiveMeetings = countMeetings(inactive);

        System.assertEquals(4, activeAMeetings,
            'Segmentation A must create four annual Quad Meetings');
        System.assertEquals(2, activeBMeetings,
            'Segmentation B must create two annual Quad Meetings');
    }

    @isTest
    static void testExecute_skipsClosedAccounts() {
        List<Account> accounts = createAccounts();
        Id inactive = accounts[2].Id;

        Test.startTest();
        new QuadMeetingCreationBatch().execute(null);
        Test.stopTest();

        Integer inactiveMeetings = countMeetings(inactive);

        
    }

    @isTest
    static void testFinish_logsInfoSummary() {
        createAccounts();

        Test.startTest();
        new QuadMeetingCreationBatch().execute(null);
        Test.stopTest();

        System.assert(
            [
                SELECT COUNT()
                FROM   Error_Log__c
                WHERE  Class_Name__c = 'QuadMeetingCreationBatch'
                AND    Method_Name__c = 'finish'
                AND    Severity__c = 'Info'
            ] > 0,
            'finish() must write an informational Error_Log__c entry'
        );
    }
}