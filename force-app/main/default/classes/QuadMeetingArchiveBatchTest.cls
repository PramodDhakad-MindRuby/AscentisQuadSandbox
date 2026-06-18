/**
 * @class       QuadMeetingArchiveBatchTest
 * @description Tests for QuadMeetingArchiveBatch.
 *              Uses TestDataFactory for Account creation and seeds valid Quad
 *              Meeting records through QuadMeetingService.createAnnualQuadMeetings().
 *
 *              Coverage
 *              • Schedulable entry point
 *              • Batch execute path archives expired meetings
 *              • Records already Archived or Complete are skipped by the batch scope
 *              • finish() writes an informational Error_Log__c entry
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class QuadMeetingArchiveBatchTest {

    private static final String TAG_ACTIVE = 'QAB_ACTIVE';
    private static final String TAG_ARCHIVED = 'QAB_ARCH';
    private static final String TAG_COMPLETE = 'QAB_COMP';

    private static List<Account> seedAccounts() {
        return new List<Account>{
            TestDataFactory.createWMHouseholdAccount(TAG_ACTIVE, null, 20, 'C', 'Active', true),
            TestDataFactory.createWMHouseholdAccount(TAG_ARCHIVED, null, 20, 'C', 'Active', true),
            TestDataFactory.createWMHouseholdAccount(TAG_COMPLETE, null, 20, 'C', 'Active', true)
        };
    }

    private static Quad_Meeting__c getMeeting(Id accountId) {
        return [
            SELECT Id,
                   Expiration_Date__c,
                   Meeting_Status__c,
                   Incomplete_Reason__c
            FROM   Quad_Meeting__c
            WHERE  Client_Account__c = :accountId
            LIMIT  1
        ];
    }

    private static Quad_Meeting__c buildManualMeeting(
        Id accountId,
        Id ownerId,
        Id recordTypeId,
        String status,
        String reason
    ) {
        Quad_Meeting__c meeting = new Quad_Meeting__c(
            Name                   = 'Archive Batch Test',
            Client_Account__c      = accountId,
            Meeting_Status__c      = status,
            Meeting_Date__c        = Date.today(),
            Goals_for_Year__c      = Date.newInstance(Date.today().year(), 1, 1),
            Expiration_Date__c     = Date.today().addDays(-1),
            Target_Meeting_Date__c = Date.today(),
            OwnerId                = ownerId
        );
        if (recordTypeId != null) {
            meeting.RecordTypeId = recordTypeId;
        }
        if (String.isNotBlank(reason)) {
            meeting.Incomplete_Reason__c = reason;
        }
        return meeting;
    }

    private static Account getAccount(String tag) {
        return [
            SELECT Id,
                   External_System_ID__c,
                   OwnerId,
                   Segmentation_Lock_Date__c,
                   Quad_Meeting_Creation_Pending__c
            FROM   Account
            WHERE  External_System_ID__c = :tag
            LIMIT  1
        ];
    }

    private static void seedMeetings() {
        seedAccounts();
        Account activeAcc   = getAccount(TAG_ACTIVE);
        Account archivedAcc = getAccount(TAG_ARCHIVED);
        Account completeAcc = getAccount(TAG_COMPLETE);
        Map<String, Id> recordTypeMap = QuadMeetingService.getRecordTypeMap();

        
        QuadMeetingService.createAnnualQuadMeetings(new Set<Id>{ activeAcc.Id });
        

        Quad_Meeting__c activeMeeting = getMeeting(activeAcc.Id);

        activeMeeting.Expiration_Date__c = Date.today().addDays(-1);
        update activeMeeting;

        insert new List<Quad_Meeting__c>{
            buildManualMeeting(
                archivedAcc.Id,
                archivedAcc.OwnerId,
                recordTypeMap.get('Introductory_Quad'),
                'Archived',
                'Updated by Automation'
            ),
            buildManualMeeting(
                completeAcc.Id,
                completeAcc.OwnerId,
                recordTypeMap.get('Introductory_Quad'),
                'Complete',
                null
            )
        };
    }

    @isTest
    static void testBatch_execute_archivesExpiredMeetings_andSkipsArchivedAndComplete() {
        seedMeetings();

        Account activeAcc = getAccount(TAG_ACTIVE);
        Account archivedAcc = getAccount(TAG_ARCHIVED);
        Account completeAcc = getAccount(TAG_COMPLETE);

        Test.startTest();
        Database.executeBatch(new QuadMeetingArchiveBatch(), 200);
        Test.stopTest();

        Quad_Meeting__c activeAfter = getMeeting(activeAcc.Id);
        Quad_Meeting__c archivedAfter = getMeeting(archivedAcc.Id);
        Quad_Meeting__c completeAfter = getMeeting(completeAcc.Id);

        System.assertEquals('Archived', activeAfter.Meeting_Status__c,
            'Expired non-archived meetings must be archived by the batch');
        System.assertEquals('Updated by Automation', activeAfter.Incomplete_Reason__c,
            'Archived meetings must be stamped with the automation reason');

        System.assertEquals('Archived', archivedAfter.Meeting_Status__c,
            'Already archived meetings must remain archived');
        System.assertEquals('Complete', completeAfter.Meeting_Status__c,
            'Complete meetings must be excluded from the batch scope');

        System.assert(
            [
                SELECT COUNT()
                FROM   Error_Log__c
                WHERE  Class_Name__c = 'QuadMeetingArchiveBatch'
                AND    Method_Name__c = 'finish'
                AND    Severity__c = 'Info'
            ] > 0,
            'finish() must write an informational Error_Log__c entry'
        );
    }

    @isTest
    static void testSchedulableExecute_runsBatch() {
        seedMeetings();
        Account activeAcc = getAccount(TAG_ACTIVE);

        Test.startTest();
        new QuadMeetingArchiveBatch().execute((SchedulableContext)null);
        Test.stopTest();

        Quad_Meeting__c activeAfter = getMeeting(activeAcc.Id);
        System.assertEquals('Archived', activeAfter.Meeting_Status__c,
            'Schedulable entry point must run the batch and archive expired meetings');
    }
}