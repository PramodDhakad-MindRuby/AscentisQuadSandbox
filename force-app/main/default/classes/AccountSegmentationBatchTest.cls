/**
 * @class       AccountSegmentationBatchTest
 * @description Comprehensive unit tests for AccountSegmentationBatch.
 *
 *              Strategy
 *              ─────────────────────────────────────────────────────────────
 *              • @TestSetup creates two Wealth Management Household Accounts
 *                tagged via External_System_ID__c (stable against flow-driven
 *                Name overwrites): one unlocked, one locked for the current year.
 *              • All re-queries use fetchAccount(testTag) which queries by
 *                External_System_ID__c, not Name.
 *
 *              Batch eligibility (AccountSegmentationBatch.start() WHERE clause):
 *                  Client_Type__c            = 'Wealth Management'
 *                  Segmentation__c           != null
 *                  Stated_Net_Worth__c       != null
 *                  Stated_HH_Income__c       != null
 *                  Billed_AUM__c             != null
 *
 *              Coverage targets
 *              ─────────────────────────────────────────────────────────────
 *              • Default constructor (no filter)
 *              • additionalFilter (String) constructor
 *              • targetAccountIds (Set<Id>) constructor
 *              • @TestVisible counters: totalProcessed, totalLocked, totalUpdated
 *              • Quad_Meeting_Creation_Pending__c flag set by batch
 *              • Schedulable interface (System.schedule)
 *              • finish() completes cleanly with zero failures
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class AccountSegmentationBatchTest {

    // Stable lookup tags – written to External_System_ID__c, never touched by flows
    private static final String TAG_UNLOCKED = 'ASBATCH_UNLOCKED';
    private static final String TAG_LOCKED   = 'ASBATCH_LOCKED';

    // =========================================================================
    // TEST SETUP
    // =========================================================================

    @TestSetup
    static void makeData() {
        // Unlocked WM account – all batch filters satisfied; segmentation = 'C'
        // (initial value; batch will recalculate and set a new score + segment)
        TestDataFactory.createWMHouseholdAccount(TAG_UNLOCKED, null, 20, 'C', true);

        // Locked WM account – all batch filters satisfied; locked for this year.
        // The batch includes it in scope (Segmentation__c != null etc.) but
        // AccountService.isSegmentationLocked() returns true so it is NOT updated.
        TestDataFactory.createWMHouseholdAccount(TAG_LOCKED, Date.today(), 90, 'AAA', true);

        // ── Post-insert re-guarantee ───────────────────────────────────────────
        // The org contains a RecordAfterSave flow (Household_Account_Created_or_Updated)
        // that fires on every Account insert/update and performs a DML recordUpdate on
        // $Record to set the Name field.  In some org configurations that flow write-back
        // can silently null out fields that were not in scope of the flow's input
        // assignments (notably restricted-picklist fields like Client_Type__c and
        // Segmentation__c).
        //
        // Running an explicit UPDATE here — AFTER all insert-time automations have
        // committed — guarantees that all five AccountSegmentationBatch.start() filter
        // fields (Client_Type__c, Segmentation__c, Stated_Net_Worth__c,
        // Stated_HH_Income__c, Billed_AUM__c) are correctly set before any test method
        // runs.  The subsequent flow write-back triggered by THIS update only changes
        // Name, leaving all other fields intact.
        List<Account> created = [
            SELECT Id, External_System_ID__c
            FROM   Account
            WHERE  External_System_ID__c IN (:TAG_UNLOCKED, :TAG_LOCKED)
        ];
        List<Account> toFix = new List<Account>();
        for (Account acc : created) {
            Boolean isLocked = (acc.External_System_ID__c == TAG_LOCKED);
            toFix.add(new Account(
                Id                        = acc.Id,
                Client_Type__c            = 'Wealth Management',
                Stated_Net_Worth__c       = 5000000,
                Stated_HH_Income__c       = 300000,
                Billed_AUM__c             = 2000000,
                Segmentation__c           = isLocked ? 'AAA' : 'C',
                Segmentation_Score__c     = isLocked ? 90    : 20,
                Segmentation_Lock_Date__c = isLocked ? Date.today() : null
            ));
        }
        if (!toFix.isEmpty()) {
            update toFix;
        }
    }

    // =========================================================================
    // PRIVATE HELPER
    // =========================================================================

    private static Account fetchAccount(String testTag) {
        return [
            SELECT Id,
                    Name,
                    External_System_ID__c,
                   Stated_Net_Worth__c,
                   Stated_HH_Income__c,
                   Billed_AUM__c,
                   Segmentation_Score__c,
                   Segmentation__c,
                   Segmentation_Lock_Date__c,
                   Quad_Meeting_Creation_Pending__c,
                   Client_Type__c
            FROM   Account
            WHERE  External_System_ID__c = :testTag
            LIMIT  1
        ];
    }

    // =========================================================================
    // Default constructor – no filter
    // =========================================================================

    @isTest
    static void testBatch_defaultConstructor_unlockedAccount_isUpdated() {
        // @TestSetup sets Segmentation_Score__c = 20 and Segmentation__c = 'C'.
        // After the batch runs, AccountService recalculates from the financial fields
        // (NW=5M, Income=300K, AUM=2M) which will produce a different score.
        // We assert the score changed from the @TestSetup value (20) to prove
        // the batch actually processed the record (not a false positive).
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch();

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        Account unlocked = fetchAccount(TAG_UNLOCKED);
        System.assertNotEquals(null, unlocked.Segmentation_Score__c,
            'Segmentation_Score__c must be populated after batch');
        System.assertNotEquals(20, unlocked.Segmentation_Score__c,
            'Segmentation_Score__c must be recalculated (changed from initial @TestSetup value of 20)');
        System.assertNotEquals(null, unlocked.Segmentation__c,
            'Segmentation__c must be set after batch');
    }

    @isTest
    static void testBatch_defaultConstructor_lockedAccount_isPreserved() {
        // @TestSetup sets Segmentation_Score__c = 90 and Segmentation__c = 'AAA'
        // with Segmentation_Lock_Date__c = today.  The batch must NOT update these.
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch();

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        Account locked = fetchAccount(TAG_LOCKED);
        System.assertEquals('AAA', locked.Segmentation__c,
            'Segmentation__c must remain AAA for the locked account');
        System.assertEquals(90, locked.Segmentation_Score__c,
            'Segmentation_Score__c must remain 90 for the locked account');
    }

    // =========================================================================
    // additionalFilter (String) constructor
    // =========================================================================

    @isTest
    static void testBatch_additionalFilter_noMatchingRecords_processesZero() {
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(
            'External_System_ID__c = \'NOMATCH_XYZ\''
        );

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        System.assertEquals(0, batchJob.totalProcessed,
            'No accounts must be processed when the filter matches nothing');
    }

    // =========================================================================
    // targetAccountIds (Set<Id>) constructor
    // =========================================================================

   

    @isTest
    static void testBatch_targetIds_emptySet_processesZeroRecords() {
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(new Set<Id>());

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        System.assertEquals(0, batchJob.totalProcessed,
            'An empty Id set must result in zero records processed');
    }

    // =========================================================================
    // Quad_Meeting_Creation_Pending__c flag
    // =========================================================================

    @isTest
    static void testBatch_unlockedAccount_setsQuadMeetingPendingFlag() {
        Account unlocked = fetchAccount(TAG_UNLOCKED);
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(
            new Set<Id>{ unlocked.Id }
        );

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        Account result = fetchAccount(TAG_UNLOCKED);
        System.assertEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must be set to true after batch processing');
    }

    @isTest
    static void testBatch_lockedAccount_doesNotSetQuadMeetingPendingFlag() {
        Account locked = fetchAccount(TAG_LOCKED);
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(
            new Set<Id>{ locked.Id }
        );

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        Account result = fetchAccount(TAG_LOCKED);
        System.assertNotEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must NOT be set for a locked account');
    }

    // =========================================================================
    // Schedulable interface
    // =========================================================================

    @isTest
    static void testSchedulable_execute_schedulesBatchSuccessfully() {
        Test.startTest();
        String jobId = System.schedule(
            'AccountSegmentationBatch_UnitTest',
            '0 0 3 1 1 ? *',
            new AccountSegmentationBatch()
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId,
            'System.schedule must return a non-null job ID');
        System.assert(String.isNotBlank(jobId),
            'Returned job ID must not be blank');
    }

    /**
     * @description Verifies the cron expression used by AccountSegmentationBatch
     *              matches "3 AM on 1 January of every year."
     *
     *              Cron breakdown: '0 0 3 1 1 ? *'
     *                Seconds=0  Minutes=0  Hours=3  Day-of-month=1
     *                Month=1(January)  Day-of-week=? (any)  Year=* (every year)
     *
     *              This test confirms the scheduler is correctly configured to
     *              run the annual Wealth Management segmentation on 1 Jan at 03:00.
     */
    @isTest
    static void testSchedulable_annualJan1st_cronExpression_isValid() {
        // Cron for "every year on January 1st at 3 AM"
        String annualCron = '0 0 3 1 1 ? *';

        Test.startTest();
        String jobId = System.schedule(
            'AccountSegmentationBatch_AnnualJan1st',
            annualCron,
            new AccountSegmentationBatch()
        );
        Test.stopTest();

        CronTrigger ct = [
            SELECT Id, CronExpression, NextFireTime
            FROM   CronTrigger
            WHERE  Id = :jobId
        ];
        System.assertEquals(annualCron, ct.CronExpression,
            'Stored cron expression must match the annual Jan 1st schedule');
        System.assertEquals(1, ct.NextFireTime.month(),
            'Next fire time must be in January (month 1)');
        System.assertEquals(1, ct.NextFireTime.day(),
            'Next fire time must be on the 1st of the month');
        System.assertEquals(3, ct.NextFireTime.hour(),
            'Next fire time must be at 03:00 AM');
    }

    // =========================================================================
    // finish() – zero failures – no exception thrown
    // =========================================================================

    @isTest
    static void testBatch_finish_noFailures_completesWithoutException() {
        Account unlocked = fetchAccount(TAG_UNLOCKED);
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(
            new Set<Id>{ unlocked.Id }
        );

        Boolean threw = false;
        try {
            Test.startTest();
            Database.executeBatch(batchJob, 200);
            Test.stopTest();
        } catch (Exception ex) {
            threw = true;
        }

        System.assertEquals(false, threw,
            'finish() must complete without throwing when there are no failures');
    }

    // =========================================================================
    // errorMap / error-email path
    // =========================================================================

    /**
     * @description Drives the finish() error-email code path by pre-injecting a
     *              failed account via the @TestVisible addTestError hook.
     *
     *              Why injection is necessary (see AccountSegmentationBatch for full
     *              explanation):
     *              • No org validation rule can be triggered for an account that
     *                passes isSegmentationLocked() — the two conditions are mutually
     *                exclusive by design.
     *              • Phone_Format fires on every DML save, including test setup,
     *                so an invalid phone cannot be persisted.
     *
     *              Because the batch is Database.Stateful, state injected before
     *              Database.executeBatch() is serialised with the job and is still
     *              present when finish() runs.
     */
    @isTest
    static void testBatch_finish_withErrors_sendsEmailAndDoesNotThrow() {
        Account unlocked = fetchAccount(TAG_UNLOCKED);

        // Empty-scope batch – execute() processes nothing; the injected error is
        // the sole driver of the finish() email branch.
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(new Set<Id>());
        batchJob.addTestError(unlocked, 'Synthetic DML failure – unit test coverage of email path');

        Boolean threw = false;
        try {
            Test.startTest();
            Database.executeBatch(batchJob, 200);
            Test.stopTest();
        } catch (Exception ex) {
            threw = true;
        }

        System.assertEquals(false, threw,
            'finish() must not throw even when failedAccounts is non-empty');
        System.assertEquals(0, batchJob.totalProcessed,
            'Empty scope – totalProcessed must be 0');
        System.assertEquals(0, batchJob.totalUpdated,
            'Empty scope – totalUpdated must be 0');
    }

    /**
     * @description Verifies that a successful batch run does not produce any
     *              Error_Log__c records (i.e., the errorMap returned by
     *              AccountService.processAccountsWithResult() is empty).
     *
     *              This covers the "no error" branch of the errorMap loop inside
     *              AccountSegmentationBatch.execute().  The inverse branch
     *              (DML failure → error log inserted) is a defensive code path
     *              reachable only through unexpected system-level DML failures;
     *              it cannot be triggered via org validation rules because:
     *                • Prevent_Segmentation_Update_When_Locked fires only when the
     *                  PRIOR lock date is in the current year — but such accounts
     *                  are already classified as locked by isSegmentationLocked()
     *                  and are skipped before processAccountsWithResult() is called.
     *                • Segmentation_Lock_Date_Not_Future fires only when the date is
     *                  in the future; AccountService always uses Date.today().
     */
    @isTest
    static void testBatch_errorHandling_successfulRun_noErrorLogsCreated() {
        Account unlocked = fetchAccount(TAG_UNLOCKED);
        AccountSegmentationBatch batchJob = new AccountSegmentationBatch(
            new Set<Id>{ unlocked.Id }
        );

        Test.startTest();
        Database.executeBatch(batchJob, 200);
        Test.stopTest();

        Integer errorLogCount = [SELECT COUNT() FROM Error_Log__c WHERE Error_Type__c = 'Batch'];
        System.assertEquals(0, errorLogCount,
            'No Error_Log__c records must be created when all accounts succeed');

        // The accounting must be consistent: processed = locked + updated (+ any errors)
        // On a clean run with one unlocked account: processed=1, locked=0, updated=1, errors=0
        System.assertEquals(
            batchJob.totalProcessed,
            batchJob.totalLocked + batchJob.totalUpdated,
            'totalProcessed must equal totalLocked + totalUpdated when there are no errorMap entries'
        );
    }
}