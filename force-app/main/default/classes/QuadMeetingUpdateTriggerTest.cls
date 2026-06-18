/**
 * @class       QuadMeetingUpdateTriggerTest
 * @description Test coverage for QuadMeetingUpdateTrigger
 *              (Quad_Meeting_Update_Event__e, after insert).
 *
 *              Covers:
 *              1. RECORD UPDATES - dynamic field assignment, only for populated
 *                 fields, onto Quad_Meeting__c (CF_01__c-CF_03__c, EP_01__c-EP_03__c).
 *              2. FILE CLEANUP - deletion of one or more ContentDocuments via a
 *                 comma-separated Files_To_Delete__c list.
 *              3. Bulk processing of multiple platform events in one transaction.
 *              4. No-op handling when RecordId__c / Files_To_Delete__c are blank.
 *
 *              NOTE: CF_01__c-CF_03__c / EP_01__c-EP_03__c (and the matching
 *              C1__c-C3__c / EP_01__c-EP_03__c fields on the platform event)
 *              are assumed to be Text fields below. If they are a different
 *              data type in your org, update the literal values accordingly.
 *              Also confirm Quad_Meeting__c has no other required fields
 *              beyond Name - add them to setupData() if so.
 *
 * @author      Mindruby Team
 * @date        2026-06-15
 */
@isTest
private class QuadMeetingUpdateTriggerTest {

    // =========================================================================
    // TEST DATA SETUP
    // =========================================================================
    @TestSetup
    static void setupData() {
        insert new Quad_Meeting__c(Name = 'Test Quad Meeting');
    }

    // =========================================================================
    // 1. RECORD UPDATE TESTS
    // =========================================================================

    @isTest
    static void testRecordUpdate_AllFieldsPopulated() {
        Quad_Meeting__c qm = [SELECT Id FROM Quad_Meeting__c LIMIT 1];

        Quad_Meeting_Update_Event__e evt = new Quad_Meeting_Update_Event__e(
            RecordId__c = qm.Id,
            C1__c    = 'Test Field 1',
            C2__c    = 'Test Field 2',
            C3__c    = 'Test Field 3',
            EP_01__c =  true,
            EP_02__c = 'Engagement Point 2',
            EP_03__c =  false
        );

        Test.startTest();
        EventBus.publish(evt);
        Test.getEventBus().deliver();
        Test.stopTest();

        Quad_Meeting__c updated = [
            SELECT CF_01__c, CF_02__c, CF_03__c, EP_01__c, EP_02__c, EP_03__c
            FROM   Quad_Meeting__c
            WHERE  Id = :qm.Id
        ];

        System.assertEquals('Custom Field 1', updated.CF_01__c);
        System.assertEquals('Custom Field 2', updated.CF_02__c);
        System.assertEquals('Custom Field 3', updated.CF_03__c);
        System.assertEquals( true, updated.EP_01__c);
        System.assertEquals('Engagement Point 2', updated.EP_02__c);
        System.assertEquals( false, updated.EP_03__c);
    }

    @isTest
    static void testRecordUpdate_OnlySomeFieldsPopulated() {
        Quad_Meeting__c qm = [SELECT Id FROM Quad_Meeting__c LIMIT 1];

        // Only C1__c and EP_02__c are sent - all other fields must remain untouched
        Quad_Meeting_Update_Event__e evt = new Quad_Meeting_Update_Event__e(
            RecordId__c = qm.Id,
            C1__c    = 'Only This Field',
            EP_02__c = 'Only This EP'
        );

        Test.startTest();
        EventBus.publish(evt);
        Test.getEventBus().deliver();
        Test.stopTest();

        Quad_Meeting__c updated = [
            SELECT CF_01__c, CF_02__c, CF_03__c, EP_01__c, EP_02__c, EP_03__c
            FROM   Quad_Meeting__c
            WHERE  Id = :qm.Id
        ];

        System.assertEquals('Only This Field', updated.CF_01__c);
        System.assertEquals(null, updated.CF_02__c);
        System.assertEquals(null, updated.CF_03__c);
        System.assertEquals(null, updated.EP_01__c);
        System.assertEquals('Only This EP', updated.EP_02__c);
        System.assertEquals(null, updated.EP_03__c);
    }

    @isTest
    static void testRecordUpdate_BlankRecordId_NoUpdate() {
        Quad_Meeting_Update_Event__e evt = new Quad_Meeting_Update_Event__e(
            RecordId__c = null,
            C1__c       = 'Should Not Be Saved'
        );

        Test.startTest();
        EventBus.publish(evt);
        Test.getEventBus().deliver();
        Test.stopTest();

        Quad_Meeting__c qm = [SELECT CF_01__c FROM Quad_Meeting__c LIMIT 1];
        System.assertEquals(null, qm.CF_01__c);
    }

    // =========================================================================
    // 2. FILE CLEANUP TESTS
    // =========================================================================

    @isTest
    static void testFileCleanup_SingleDocumentDeleted() {
        Id contentDocumentId = createContentDocument('TestFile1');

        Quad_Meeting_Update_Event__e evt = new Quad_Meeting_Update_Event__e(
            Files_To_Delete__c = String.valueOf(contentDocumentId)
        );

        Test.startTest();
        EventBus.publish(evt);
        Test.getEventBus().deliver();
        Test.stopTest();

        List<ContentDocument> remaining = [
            SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId
        ];
        System.assertEquals(0, remaining.size());
    }

    @isTest
    static void testFileCleanup_MultipleDocumentsDeleted() {
        Id docId1 = createContentDocument('TestFile1');
        Id docId2 = createContentDocument('TestFile2');

        Quad_Meeting_Update_Event__e evt = new Quad_Meeting_Update_Event__e(
            Files_To_Delete__c = String.valueOf(docId1) + ',' + String.valueOf(docId2)
        );

        Test.startTest();
        EventBus.publish(evt);
        Test.getEventBus().deliver();
        Test.stopTest();

        List<ContentDocument> remaining = [
            SELECT Id FROM ContentDocument WHERE Id IN (:docId1, :docId2)
        ];
        System.assertEquals(0, remaining.size());
    }

    @isTest
    static void testFileCleanup_BlankFilesToDelete_NoError() {
        Quad_Meeting_Update_Event__e evt = new Quad_Meeting_Update_Event__e(
            Files_To_Delete__c = null
        );

        Test.startTest();
        EventBus.publish(evt);
        Test.getEventBus().deliver();
        Test.stopTest();

        // No exception expected - nothing further to assert
    }

    // =========================================================================
    // 3. BULK / COMBINED TEST
    // =========================================================================

    @isTest
    static void testBulkEvents_RecordUpdateAndFileCleanupTogether() {
        Quad_Meeting__c qm = [SELECT Id FROM Quad_Meeting__c LIMIT 1];
        Id contentDocumentId = createContentDocument('BulkTestFile');

        List<Quad_Meeting_Update_Event__e> events = new List<Quad_Meeting_Update_Event__e>();

        // Record update event
        events.add(new Quad_Meeting_Update_Event__e(
            RecordId__c = qm.Id,
            C1__c       = 'Bulk Update Value',
            EP_01__c    = true
        ));

        // File cleanup event
        events.add(new Quad_Meeting_Update_Event__e(
            Files_To_Delete__c = String.valueOf(contentDocumentId)
        ));

        // Additional no-op events to verify bulk safety
        for (Integer i = 0; i < 5; i++) {
            events.add(new Quad_Meeting_Update_Event__e());
        }

        Test.startTest();
        EventBus.publish(events);
        Test.getEventBus().deliver();
        Test.stopTest();

        Quad_Meeting__c updated = [
            SELECT CF_01__c, EP_01__c FROM Quad_Meeting__c WHERE Id = :qm.Id
        ];
        System.assertEquals('Bulk Update Value', updated.CF_01__c);
        System.assertEquals(true, updated.EP_01__c);

        List<ContentDocument> remaining = [
            SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId
        ];
        System.assertEquals(0, remaining.size());
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    /**
     * @description Inserts a ContentVersion (creating its parent ContentDocument)
     *              and returns the ContentDocument Id.
     */
    private static Id createContentDocument(String title) {
        ContentVersion cv = new ContentVersion(
            Title          = title,
            PathOnClient   = title + '.txt',
            VersionData    = Blob.valueOf('Test file content'),
            IsMajorVersion = true
        );
        insert cv;

        return [
            SELECT ContentDocumentId
            FROM   ContentVersion
            WHERE  Id = :cv.Id
        ].ContentDocumentId;
    }
}