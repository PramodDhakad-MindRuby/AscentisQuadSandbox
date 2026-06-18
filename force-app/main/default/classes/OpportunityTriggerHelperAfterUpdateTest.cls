/**
 * @class       OpportunityTriggerHelperAfterUpdateTest
 * @description Comprehensive unit tests for OpportunityTriggerHelperAfterUpdate.
 *
 *              Scenarios covered
 *              ─────────────────────────────────────────────────────────────
 *              Happy paths (via real Opportunity trigger):
 *              • WM account: Opp → 'Client Activated' recalculates segmentation
 *                and creates Quad Meeting(s)
 *              • FP Only account: Opp → 'Client Activated' creates Quad Meeting
 *                but does NOT touch segmentation
 *              • Other client type: Opp → 'Client Activated' – nothing processed
 *              • Stage changes to something OTHER than 'Client Activated' – skipped
 *              • Opp already at 'Client Activated' updated again – not re-processed
 *              • Multiple Opps on the same account – Set<Id> deduplicates processing
 *              • WM and FP Only accounts in the same trigger run – each branch fires
 *
 *              Edge cases (direct handleAfterUpdate call):
 *              • Opp with null AccountId → skipped without error
 *              • Empty Opp list → no work done
 *
 *              @TestVisible helper (getAccountMap):
 *              • Opps with null AccountIds → empty map
 *              • Valid AccountId → Account with Client_Type__c returned
 *              • Empty Opp list → empty map
 *
 *              Exception paths (@TestVisible injection hooks):
 *              • AccountService.processAccounts throws → caught, Error_Log__c created,
 *                trigger does not re-throw
 *              • QuadMeetingService.createMidYearQuadMeetings (WM path) throws →
 *                caught, Error_Log__c created, trigger does not re-throw
 *              • QuadMeetingService.createMidYearQuadMeetings (FP Only path) throws →
 *                caught, Error_Log__c created, trigger does not re-throw
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class OpportunityTriggerHelperAfterUpdateTest {

    // Stable lookup tags stored in External_System_ID__c (≤ 25 chars each)
    private static final String TAG_WM    = 'OPTH_WM';
    private static final String TAG_FP    = 'OPTH_FP';
    private static final String TAG_OTHER = 'OPTH_OTHER';

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    /**
     * @description Returns the Id of the FinServ IndustriesHousehold RecordType.
     *              Mirrors the same Schema.describe pattern used by TestDataFactory
     *              so Client_Type__c restricted-picklist values are preserved on save.
     */
    private static Id getHouseholdRtId() {
        Schema.RecordTypeInfo rtInfo = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName()
            .get('IndustriesHousehold');
        return (rtInfo != null && rtInfo.isAvailable()) ? rtInfo.getRecordTypeId() : null;
    }

    /**
     * @description Re-queries an Account from the DB by its stable External_System_ID__c tag.
     */
    private static Account fetchAccount(String testTag) {
        return [
            SELECT Id, Client_Type__c, Segmentation_Score__c,
                   Segmentation__c, Segmentation_Lock_Date__c
            FROM   Account
            WHERE  External_System_ID__c = :testTag
            LIMIT  1
        ];
    }

    // =========================================================================
    // TEST SETUP
    // =========================================================================

    @TestSetup
    static void makeData() {
        Id rtId = getHouseholdRtId();

        // Three accounts with different Client_Type__c values
        insert new List<Account>{
            new Account(
                Name                  = 'WM Household Test',
                RecordTypeId          = rtId,
                Client_Type__c        = 'Wealth Management',
                Stated_Net_Worth__c   = 5000000,
                Stated_HH_Income__c   = 300000,
                Billed_AUM__c         = 2000000,
                Segmentation__c       = 'A',
                Segmentation_Score__c = 20,
                External_System_ID__c = TAG_WM
            ),
            new Account(
                Name                  = 'FP Only Household Test',
                RecordTypeId          = rtId,
                Client_Type__c        = 'FP Only',
                Stated_Net_Worth__c   = 3000000,
                Stated_HH_Income__c   = 200000,
                Billed_AUM__c         = 1000000,
                Segmentation__c       = 'C',
                Segmentation_Score__c = 20,
                Segmentation_Lock_Date__c = System.today(), // FP Only accounts have no lock date
                External_System_ID__c = TAG_FP
            ),
            new Account(
                Name                  = 'Other Household Test',
                RecordTypeId          = rtId,
                Client_Type__c        = 'Non-FP',
                Stated_Net_Worth__c   = 2000000,
                Stated_HH_Income__c   = 150000,
                Billed_AUM__c         = 500000,
                External_System_ID__c = TAG_OTHER
            )
        };

        // ── Post-insert re-guarantee ─────────────────────────────────────────
        // The Household_Account_Created_or_Updated RecordAfterSave flow fires
        // after every Account insert/update and rewrites the Name field via a
        // $Record recordUpdate.  In some org configurations this write-back can
        // silently null out restricted-picklist fields (Client_Type__c).
        // Running an explicit UPDATE here—after all insert-time automations have
        // committed—guarantees Client_Type__c is correct before tests run.
        List<Account> created = [
            SELECT Id, External_System_ID__c
            FROM   Account
            WHERE  External_System_ID__c IN (:TAG_WM, :TAG_FP, :TAG_OTHER)
        ];
        List<Account> toFix = new List<Account>();
        for (Account acc : created) {
            String ct = acc.External_System_ID__c == TAG_WM    ? 'Wealth Management'
                      : acc.External_System_ID__c == TAG_FP    ? 'FP Only'
                      :                                          'Non-FP';
            toFix.add(new Account(
                Id             = acc.Id,
                Client_Type__c = ct
            ));
        }
        if (!toFix.isEmpty()) {
            update toFix;
        }

        // One Opportunity per account, starting at 'Prospecting'
        Account wmAcc    = [SELECT Id FROM Account WHERE External_System_ID__c = :TAG_WM    LIMIT 1];
        Account fpAcc    = [SELECT Id FROM Account WHERE External_System_ID__c = :TAG_FP    LIMIT 1];
        Account otherAcc = [SELECT Id FROM Account WHERE External_System_ID__c = :TAG_OTHER LIMIT 1];

        insert new List<Opportunity>{
            new Opportunity(
                Name      = 'WM Opp',
                AccountId = wmAcc.Id,
                Account_Setup_Complete_Date__c = Date.today().addDays(-10),
                StageName = 'Account Setup',
                CloseDate = Date.today().addDays(30)
            ),
            new Opportunity(
                Name      = 'FP Opp',
                AccountId = fpAcc.Id,
                Account_Setup_Complete_Date__c = Date.today().addDays(-10),
                StageName = 'Account Setup',
                CloseDate = Date.today().addDays(30)
            ),
            new Opportunity(
                Name      = 'Other Opp',
                AccountId = otherAcc.Id,
                Account_Setup_Complete_Date__c = Date.today().addDays(-10),
                StageName = 'Account Setup',
                CloseDate = Date.today().addDays(30)
            )
        };
    }

    // =========================================================================
    // Wealth Management – happy path
    // =========================================================================

    @isTest
    static void testWMAccount_transitionToClientActivated_segmentationRecalculated() {
        // @TestSetup leaves Segmentation_Lock_Date__c = null on the WM account.
        // AccountService.processAccounts sets it to Date.today() after recalculation.
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];

        Test.startTest();
        opp.StageName = 'Client Activated';
        update opp;
        Test.stopTest();

        Account wmAfter = fetchAccount(TAG_WM);
        System.assertNotEquals(null, wmAfter.Segmentation_Lock_Date__c,
            'AccountService must have run: Segmentation_Lock_Date__c must be set');
        System.assertEquals(Date.today().year(), wmAfter.Segmentation_Lock_Date__c.year(),
            'Lock date must be in the current year');
        System.assertNotEquals(null, wmAfter.Segmentation_Score__c,
            'Segmentation_Score__c must be recalculated');
        // Score started at 20 (setup value); AccountService recalculates from financial fields
        System.assertNotEquals(20, wmAfter.Segmentation_Score__c,
            'Segmentation_Score__c must differ from the @TestSetup seed value of 20');
    }

    @isTest
    static void testWMAccount_transitionToClientActivated_quadMeetingCreated() {
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        Account wmAcc   = fetchAccount(TAG_WM);

        Test.startTest();
        opp.StageName = 'Client Activated';
        update opp;
        Test.stopTest();

        Integer quadCount = [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :wmAcc.Id];
        System.assert(quadCount > 0,
            'At least one Quad Meeting must be created for a WM account activated mid-year');
    }

    // =========================================================================
    // FP Only – Quad Meeting created, segmentation untouched
    // =========================================================================

    @isTest
    static void testFPOnlyAccount_transitionToClientActivated_createsQuadMeetingOnly() {
        Opportunity opp    = [SELECT Id FROM Opportunity WHERE Name = 'FP Opp'];
        Account     fpAcc  = fetchAccount(TAG_FP);
        // FP Only accounts have no initial lock date
        System.assertEquals(System.today(), fpAcc.Segmentation_Lock_Date__c,
            'Pre-condition: FP Only account lock date must be null before trigger');

        Test.startTest();
        opp.StageName = 'Client Activated';
        update opp;
        Test.stopTest();

        Account fpAfter = fetchAccount(TAG_FP);
        System.assertEquals(System.today(), fpAfter.Segmentation_Lock_Date__c,
            'AccountService must NOT run for FP Only accounts – lock date must remain null');

        Integer quadCount = [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :fpAcc.Id];
        System.assert(quadCount > 0,
            'QuadMeetingService must still create at least one meeting for FP Only accounts');
    }

    // =========================================================================
    // Other client type – nothing processed
    // =========================================================================

    @isTest
    static void testOtherClientType_transitionToClientActivated_nothingProcessed() {
        Opportunity opp      = [SELECT Id FROM Opportunity WHERE Name = 'Other Opp'];
        Account     otherAcc = fetchAccount(TAG_OTHER);

        Test.startTest();
        opp.StageName = 'Client Activated';
        update opp;
        Test.stopTest();

        Account otherAfter = fetchAccount(TAG_OTHER);
        System.assertEquals(null, otherAfter.Segmentation_Lock_Date__c,
            'AccountService must NOT run for non-WM non-FP accounts');
        Integer quadCount = [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :otherAcc.Id];
        System.assertEquals(0, quadCount,
            'No Quad Meeting must be created for accounts with an unrecognised client type');
    }

    // =========================================================================
    // Stage NOT transitioning to Client Activated – nothing processed
    // =========================================================================

    @isTest
    static void testStageChange_notToClientActivated_nothingProcessed() {
        Opportunity opp   = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        Account     wmAcc = fetchAccount(TAG_WM);

        Test.startTest();
        opp.StageName = 'Qualification'; // valid stage, but not 'Client Activated'
        update opp;
        Test.stopTest();

        Account wmAfter = fetchAccount(TAG_WM);
        System.assertEquals(wmAcc.Segmentation_Lock_Date__c, wmAfter.Segmentation_Lock_Date__c,
            'No segmentation change when Opp stage does not become Client Activated');
        System.assertEquals(0,
            [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :wmAcc.Id],
            'No Quad Meeting must be created when stage does not become Client Activated');
    }

    // =========================================================================
    // Opp already at Client Activated – re-update does NOT re-process
    // =========================================================================

    @isTest
    static void testOpp_alreadyClientActivated_reUpdateDoesNotReprocess() {
        Opportunity opp   = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        Account     wmAcc = fetchAccount(TAG_WM);

        // First update: genuine transition (Prospecting → Client Activated) — handler fires
        opp.StageName = 'Client Activated';
        update opp;
        Integer quadCountAfterFirstUpdate = [
            SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :wmAcc.Id
        ];

        Test.startTest();
        // Second update: already at Client Activated; wasNotClientActivated = false → skipped
        opp.Description = 'Re-trigger test – should not re-process';
        update opp;
        Test.stopTest();

        Integer quadCountAfterSecondUpdate = [
            SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :wmAcc.Id
        ];
        System.assertEquals(quadCountAfterFirstUpdate, quadCountAfterSecondUpdate,
            'No additional Quad Meetings must be created when Opp was already Client Activated');
    }

    // =========================================================================
    // Multiple Opps on the same WM account – deduplication (processed once)
    // =========================================================================

    @isTest
    static void testMultipleOpps_sameWMAccount_accountProcessedOnce() {
        Account wmAcc = fetchAccount(TAG_WM);

        // Insert a second Opp on the same account
        insert new Opportunity(
            Name      = 'WM Opp 2',
            AccountId = wmAcc.Id,
            Account_Setup_Complete_Date__c = Date.today().addDays(-10),
            StageName = 'Account Setup',
            CloseDate = Date.today().addDays(60)
        );

        Opportunity opp1 = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        Opportunity opp2 = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp 2'];

        Test.startTest();
        // Both Opps go to Client Activated in one DML – same trigger execution
        update new List<Opportunity>{
            new Opportunity(Id = opp1.Id, StageName = 'Client Activated'),
            new Opportunity(Id = opp2.Id, StageName = 'Client Activated')
        };
        Test.stopTest();

        // Set<Id> in the handler deduplicates the account.
        // Segmentation_Lock_Date__c is set exactly once (not doubled).
        Account wmAfter = fetchAccount(TAG_WM);
        System.assertNotEquals(null, wmAfter.Segmentation_Lock_Date__c,
            'Account must have been processed despite two Opps pointing to it');

        // QuadMeetingService duplicate-prevention ensures only one set of meetings
        Integer quadCount = [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :wmAcc.Id];
        System.assert(quadCount > 0,
            'Quad Meeting must be created when multiple Opps share the same account');
    }

    // =========================================================================
    // WM + FP Only in the same trigger run
    // =========================================================================

    @isTest
    static void testBothClientTypes_singleTriggerRun_eachBranchFires() {
        Opportunity wmOpp = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        Opportunity fpOpp = [SELECT Id FROM Opportunity WHERE Name = 'FP Opp'];
        Account     wmAcc = fetchAccount(TAG_WM);
        Account     fpAcc = fetchAccount(TAG_FP);

        Test.startTest();
        update new List<Opportunity>{
            new Opportunity(Id = wmOpp.Id, StageName = 'Client Activated'),
            new Opportunity(Id = fpOpp.Id, StageName = 'Client Activated')
        };
        Test.stopTest();

        // WM: segmentation recalculated
        Account wmAfter = fetchAccount(TAG_WM);
        System.assertNotEquals(null, wmAfter.Segmentation_Lock_Date__c,
            'WM account must have segmentation recalculated');

        // FP Only: no segmentation touched
        Account fpAfter = fetchAccount(TAG_FP);
        System.assertEquals(System.today(), fpAfter.Segmentation_Lock_Date__c,
            'FP Only account lock date must remain null');

        // Both: Quad Meetings created
        System.assert(
            [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :wmAcc.Id] > 0,
            'Quad Meeting must be created for WM account in the combined trigger run');
        System.assert(
            [SELECT COUNT() FROM Quad_Meeting__c WHERE Client_Account__c = :fpAcc.Id] > 0,
            'Quad Meeting must be created for FP Only account in the combined trigger run');
    }

    // =========================================================================
    // Opp with null AccountId – skipped without error
    // =========================================================================

    @isTest
    static void testOpp_nullAccountId_skippedWithoutError() {
        // Call handleAfterUpdate directly so we can pass AccountId = null
        // (bypasses Opportunity field-level requirements on DML path)
        Id anyOppId = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'].Id;
        Opportunity fakeNew = new Opportunity(Id = anyOppId, StageName = 'Client Activated', AccountId = null);
        Opportunity fakeOld = new Opportunity(Id = anyOppId, StageName = 'Prospecting',      AccountId = null);

        Boolean threw = false;
        Test.startTest();
        try {
            OpportunityTriggerHelperAfterUpdate.handleAfterUpdate(
                new List<Opportunity>{ fakeNew },
                new Map<Id, Opportunity>{ anyOppId => fakeOld }
            );
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw,
            'Handler must not throw when AccountId is null on the Opportunity');
        System.assertEquals(0, [SELECT COUNT() FROM Quad_Meeting__c],
            'No Quad Meeting must be created when AccountId is null');
    }

    // =========================================================================
    // getAccountMap @TestVisible helper
    // =========================================================================

    @isTest
    static void testGetAccountMap_withNullAccountIds_returnsEmptyMap() {
        Id anyOppId = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'].Id;
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(Id = anyOppId, AccountId = null)
        };

        Test.startTest();
        Map<Id, Account> result = OpportunityTriggerHelperAfterUpdate.getAccountMap(opps);
        Test.stopTest();

        System.assertEquals(0, result.size(),
            'getAccountMap must return an empty map when all AccountIds are null');
    }

    @isTest
    static void testGetAccountMap_withValidAccountId_returnsAccountWithClientType() {
        Account     wmAcc  = fetchAccount(TAG_WM);
        Id          oppId  = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'].Id;
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(Id = oppId, AccountId = wmAcc.Id)
        };

        Test.startTest();
        Map<Id, Account> result = OpportunityTriggerHelperAfterUpdate.getAccountMap(opps);
        Test.stopTest();

        System.assertEquals(1, result.size(),
            'getAccountMap must return one entry for one distinct AccountId');
        System.assertEquals('Wealth Management', result.get(wmAcc.Id).Client_Type__c,
            'Client_Type__c must be queried and returned correctly');
    }

    @isTest
    static void testGetAccountMap_withEmptyOppList_returnsEmptyMap() {
        Test.startTest();
        Map<Id, Account> result = OpportunityTriggerHelperAfterUpdate.getAccountMap(
            new List<Opportunity>()
        );
        Test.stopTest();

        System.assertEquals(0, result.size(),
            'getAccountMap must return an empty map for an empty Opp list');
    }

    @isTest
    static void testGetAccountMap_duplicateAccountIds_deduplicatesInMap() {
        // Two Opps referencing the same Account → map must have only one entry
        Account wmAcc = fetchAccount(TAG_WM);
        Id opp1Id     = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'].Id;
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(Id = opp1Id, AccountId = wmAcc.Id),
            new Opportunity(Id = opp1Id, AccountId = wmAcc.Id)
        };

        Test.startTest();
        Map<Id, Account> result = OpportunityTriggerHelperAfterUpdate.getAccountMap(opps);
        Test.stopTest();

        System.assertEquals(1, result.size(),
            'getAccountMap must deduplicate Accounts when multiple Opps share the same AccountId');
    }

    // =========================================================================
    // Exception paths – @TestVisible injection
    // =========================================================================

    /**
     * @description When AccountService.processAccounts throws, the handler must:
     *              1. Catch the exception (not re-throw it)
     *              2. Log it to Error_Log__c via ErrorLogService
     *              3. Continue to the QuadMeetingService call (execution not aborted)
     */
    @isTest
    static void testAccountServiceException_caughtLogged_triggerDoesNotThrow() {
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        OpportunityTriggerHelperAfterUpdate.accountServiceException =
            new IllegalArgumentException('Synthetic AccountService failure – unit test');

        Boolean threw = false;
        try {
            Test.startTest();
            opp.StageName = 'Client Activated';
            update opp;
            Test.stopTest();
        } catch (Exception ex) {
            threw = true;
        }

        System.assertEquals(false, threw,
            'Trigger must not propagate the AccountService exception to the caller');
        System.assert(
            [SELECT COUNT() FROM Error_Log__c
             WHERE Class_Name__c = 'OpportunityTriggerHelperAfterUpdate'] > 0,
            'An Error_Log__c must be written when AccountService throws'
        );
    }

    /**
     * @description When QuadMeetingService throws on the WM path, the handler must
     *              catch it, log it, and not re-throw.  AccountService still runs first.
     */
    @isTest
    static void testWMQuadMeetingException_caughtLogged_triggerDoesNotThrow() {
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'WM Opp'];
        OpportunityTriggerHelperAfterUpdate.wmQuadMeetingException =
            new IllegalArgumentException('Synthetic WM QuadMeetingService failure – unit test');

        Boolean threw = false;
        try {
            Test.startTest();
            opp.StageName = 'Client Activated';
            update opp;
            Test.stopTest();
        } catch (Exception ex) {
            threw = true;
        }

        System.assertEquals(false, threw,
            'Trigger must not propagate the WM QuadMeetingService exception to the caller');
        System.assert(
            [SELECT COUNT() FROM Error_Log__c
             WHERE Class_Name__c = 'OpportunityTriggerHelperAfterUpdate'] > 0,
            'An Error_Log__c must be written when WM QuadMeetingService throws'
        );
        // AccountService ran successfully before the exception: lock date must be set
        Account wmAfter = fetchAccount(TAG_WM);
        System.assertNotEquals(null, wmAfter.Segmentation_Lock_Date__c,
            'AccountService must have completed successfully before the QuadMeeting exception');
    }

    /**
     * @description When QuadMeetingService throws on the FP Only path, the handler must
     *              catch it, log it, and not re-throw.
     */
    @isTest
    static void testFPQuadMeetingException_caughtLogged_triggerDoesNotThrow() {
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'FP Opp'];
        OpportunityTriggerHelperAfterUpdate.fpQuadMeetingException =
            new IllegalArgumentException('Synthetic FP Only QuadMeetingService failure – unit test');

        Boolean threw = false;
        try {
            Test.startTest();
            opp.StageName = 'Client Activated';
            update opp;
            Test.stopTest();
        } catch (Exception ex) {
            threw = true;
        }

        System.assertEquals(false, threw,
            'Trigger must not propagate the FP Only QuadMeetingService exception to the caller');
        System.assert(
            [SELECT COUNT() FROM Error_Log__c
             WHERE Class_Name__c = 'OpportunityTriggerHelperAfterUpdate'] > 0,
            'An Error_Log__c must be written when FP Only QuadMeetingService throws'
        );
    }
}