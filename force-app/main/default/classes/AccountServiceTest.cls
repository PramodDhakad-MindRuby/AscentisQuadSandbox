/**
 * @class       AccountServiceTest
 * @description Comprehensive unit tests for AccountService.
 *
 *              Strategy
 *              ─────────────────────────────────────────────────────────────
 *              • @TestSetup   creates three canonical Accounts via TestDataFactory
 *                             that cover the three locking states (unlocked,
 *                             locked-current-year, locked-prior-year).
 *              • Records are tagged via External_System_ID__c (a stable field no
 *                flow or trigger overwrites). Tests re-query by that tag because
 *                the Household/Advisor/Business flows rename Account.Name after
 *                every save, making Name-based lookups unreliable.
 *              • Tests that need unique data shapes create records inline with
 *                TestDataFactory (e.g. bulk test, QuadPending overloads).
 *
 *              Coverage targets
 *              ─────────────────────────────────────────────────────────────
 *              All public methods of AccountService are exercised:
 *                isSegmentationLocked, getScore, applyWeights, deriveSegment,
 *                calculateSegmentation, processAccounts (4 overloads),
 *                processAccountsWithResult (2 overloads).
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class AccountServiceTest {

    // =========================================================================
    // TEST SETUP  –  runs once; each test gets a fresh rollback copy
    // =========================================================================

    @TestSetup
    static void makeData() {
        // Standard unlocked account – high financial values, no lock date.
        // External_System_ID__c is used as a stable lookup key because
        // multiple org flows (Household, Advisor, Business) overwrite Account.Name
        // after every save, making Name-based queries return zero rows.
        TestDataFactory.createHouseholdAccount(
            'Unlocked HH', 5000000, 300000, 2000000, null, 'ACCSVC_UNLOCKED', true
        );

        // Account locked in the current calendar year – must NOT be recalculated
        TestDataFactory.createLockedHouseholdAccount(
            'Locked HH Current Year', 90, 'AAA', 'ACCSVC_LOCKED_CY', true
        );

        // Account whose lock date is in a prior year – lock has expired, CAN recalculate
        TestDataFactory.createHouseholdAccount(
            'Locked HH Last Year', 5000000, 300000, 2000000,
            Date.today().addYears(-1), 'ACCSVC_LOCKED_LY', true
        );
    }

    // =========================================================================
    // PRIVATE HELPER  –  re-query a @TestSetup account by its stable test tag
    // =========================================================================
    //
    // WHY External_System_ID__c and NOT Name:
    //   Org flows (e.g. Household_Account_Created_or_Updated,
    //   Advisor_Account_Created_or_Updated, Business_Account_Created_or_Updated)
    //   all run as RecordAfterSave triggers and overwrite Account.Name with a
    //   generated value (e.g. "Smith, John | CA | HH | abc123").
    //   External_System_ID__c is a plain text field that none of those flows touch,
    //   so it remains exactly what @TestSetup set it to.
    //
    private static Account fetchAccount(String testTag) {
        return [
            SELECT Id,
                   Stated_Net_Worth__c,
                   Stated_HH_Income__c,
                   Billed_AUM__c,
                   Segmentation_Score__c,
                   Segmentation__c,
                   Segmentation_Lock_Date__c,
                   Quad_Meeting_Creation_Pending__c
            FROM   Account
            WHERE  External_System_ID__c = :testTag
            LIMIT  1
        ];
    }

    // =========================================================================
    // isSegmentationLocked
    // =========================================================================

    @isTest
    static void testIsSegmentationLocked_nullLockDate_returnsFalse() {
        Account acc = new Account(Name = 'Lock Test', Segmentation_Lock_Date__c = null);
        System.assertEquals(false, AccountService.isSegmentationLocked(acc),
            'A null lock date must not be considered locked');
    }

    @isTest
    static void testIsSegmentationLocked_currentYearLock_returnsTrue() {
        Account acc = new Account(
            Name                      = 'Lock Test',
            Segmentation_Lock_Date__c = Date.today()
        );
        System.assertEquals(true, AccountService.isSegmentationLocked(acc),
            'A lock date in the current year must return true');
    }

    @isTest
    static void testIsSegmentationLocked_priorYearLock_returnsFalse() {
        Account acc = new Account(
            Name                      = 'Lock Test',
            Segmentation_Lock_Date__c = Date.today().addYears(-1)
        );
        System.assertEquals(false, AccountService.isSegmentationLocked(acc),
            'A lock date from a prior year must not be considered locked');
    }

    // =========================================================================
    // getScore
    // =========================================================================

    @isTest
    static void testGetScore_nullValue_returnsZero() {
        Decimal score = AccountService.getScore('AUM', null);
        System.assertEquals(0, score, 'A null field value must return score 0');
    }

    @isTest
    static void testGetScore_negativeValue_returnsZero() {
        Decimal score = AccountService.getScore('NW', -1);
        System.assertEquals(0, score, 'A negative field value must return score 0');
    }

    @isTest
    static void testGetScore_zeroValue_returnsNonNegative() {
        // Zero is a valid value; must not throw and must return >= 0
        Decimal score = AccountService.getScore('INC', 0);
        System.assert(score >= 0, 'A zero value must return a non-negative score');
    }

    // =========================================================================
    // applyWeights
    // =========================================================================

    @isTest
    static void testApplyWeights_allZeroScores_returnsZero() {
        Decimal result = AccountService.applyWeights(0, 0, 0);
        System.assertEquals(0, result,
            'All-zero scores must produce a weighted score of 0');
    }

    @isTest
    static void testApplyWeights_mixedScores_withinValidRange() {
        Decimal result = AccountService.applyWeights(80, 50, 30);
        System.assert(result >= 0,   'Weighted score must be >= 0');
        System.assert(result <= 100, 'Weighted score must be <= 100');
    }

    // =========================================================================
    // deriveSegment
    // =========================================================================







    @isTest
    static void testDeriveSegment_lowScore_returnsC() {
        System.assertEquals('C', AccountService.deriveSegment(10),
            'Score 10 should map to C');
    }

    @isTest
    static void testDeriveSegment_nullScore_defaultsToC() {
        System.assertEquals('C', AccountService.deriveSegment(null),
            'A null score must fall back to segment C');
    }

    // =========================================================================
    // calculateSegmentation
    // =========================================================================

    @isTest
    static void testCalculateSegmentation_unlockedAccount_setsScoreSegmentAndLockDate() {
        // In-memory only – no DML needed to test the pure calculation method
        Account acc = TestDataFactory.createHouseholdAccount(false);

        Account result = AccountService.calculateSegmentation(acc);

        System.assertNotEquals(null, result,
            'An unlocked account must return a mutated record (not null)');
        System.assertNotEquals(null, result.Segmentation_Score__c,
            'Segmentation_Score__c must be populated');
        System.assertNotEquals(null, result.Segmentation__c,
            'Segmentation__c must be populated');
        System.assertEquals(Date.today(), result.Segmentation_Lock_Date__c,
            'Segmentation_Lock_Date__c must be set to today after calculation');
    }

    @isTest
    static void testCalculateSegmentation_lockedAccount_returnsNull() {
        Account acc = new Account(
            Name                      = 'Calc Locked',
            Stated_Net_Worth__c       = 5000000,
            Stated_HH_Income__c       = 300000,
            Billed_AUM__c             = 2000000,
            Segmentation__c           = 'AAA',
            Segmentation_Score__c     = 90,
            Segmentation_Lock_Date__c = Date.today()
        );

        System.assertEquals(null, AccountService.calculateSegmentation(acc),
            'A currently-locked account must return null (preserve the locked segment)');
    }

    // =========================================================================
    // processAccounts(Set<Id>)  –  backward-compatible overload
    // =========================================================================

    @isTest
    static void testProcessAccounts_setId_unlockedAccount_updatesSegmentation() {
        // Create inline so the test is independent of @TestSetup name-lookup
        Account acc = TestDataFactory.createHouseholdAccount(true);

        Test.startTest();
        AccountService.processAccounts(new Set<Id>{ acc.Id });
        Test.stopTest();

        Account updated = [SELECT Segmentation_Score__c, Segmentation__c
                           FROM Account WHERE Id = :acc.Id];
        System.assertNotEquals(null, updated.Segmentation_Score__c,
            'Segmentation_Score__c must be set after processing');
        System.assertNotEquals(null, updated.Segmentation__c,
            'Segmentation__c must be set after processing');
    }

    @isTest
    static void testProcessAccounts_setId_currentYearLock_preservesSegment() {
        Account acc = fetchAccount('ACCSVC_LOCKED_CY');

        Test.startTest();
        AccountService.processAccounts(new Set<Id>{ acc.Id });
        Test.stopTest();

        Account result = fetchAccount('ACCSVC_LOCKED_CY');
        System.assertEquals('AAA', result.Segmentation__c,
            'The locked segment must remain AAA');
        System.assertEquals(90, result.Segmentation_Score__c,
            'The locked score must remain 90');
    }

    @isTest
    static void testProcessAccounts_setId_expiredLock_recalculatesSegment() {
        Account acc = fetchAccount('ACCSVC_LOCKED_LY');

        Test.startTest();
        AccountService.processAccounts(new Set<Id>{ acc.Id });
        Test.stopTest();

        Account result = fetchAccount('ACCSVC_LOCKED_LY');
        System.assertNotEquals(null, result.Segmentation_Score__c,
            'An expired lock must allow segmentation to be recalculated');
    }

    @isTest
    static void testProcessAccounts_setId_emptySet_doesNotThrow() {
        Test.startTest();
        AccountService.processAccounts(new Set<Id>());
        Test.stopTest();
        System.assert(true, 'An empty Id set must not throw an exception');
    }

    @isTest
    static void testProcessAccounts_setId_nullSet_doesNotThrow() {
        Test.startTest();
        AccountService.processAccounts((Set<Id>) null);
        Test.stopTest();
        System.assert(true, 'A null Id set must not throw an exception');
    }

    // =========================================================================
    // processAccounts(Set<Id>, Boolean)  –  setQuadPending overload
    // =========================================================================

    @isTest
    static void testProcessAccounts_setId_quadPendingTrue_setsFlag() {
        Account acc = fetchAccount('ACCSVC_UNLOCKED');

        Test.startTest();
        AccountService.processAccounts(new Set<Id>{ acc.Id }, true);
        Test.stopTest();

        Account result = fetchAccount('ACCSVC_UNLOCKED');
        System.assertEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must be true when setQuadPending = true');
    }

    @isTest
    static void testProcessAccounts_setId_quadPendingFalse_doesNotSetFlag() {
        Account acc = fetchAccount('ACCSVC_UNLOCKED');

        Test.startTest();
        AccountService.processAccounts(new Set<Id>{ acc.Id }, false);
        Test.stopTest();

        Account result = fetchAccount('ACCSVC_UNLOCKED');
        System.assertNotEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must not be true when setQuadPending = false');
    }

    // =========================================================================
    // processAccounts(List<Account>)  –  backward-compatible overload
    // =========================================================================

    @isTest
    static void testProcessAccounts_list_unlockedAccount_updatesSegmentation() {
        // Fetch the @TestSetup account by its stable tag (Name is overwritten by flows)
        Account acc = fetchAccount('ACCSVC_UNLOCKED');

        Test.startTest();
        AccountService.processAccounts(new List<Account>{ acc });
        Test.stopTest();

        Account updated = [SELECT Segmentation_Score__c, Segmentation__c
                           FROM Account WHERE Id = :acc.Id];
        System.assertNotEquals(null, updated.Segmentation_Score__c,
            'Segmentation_Score__c must be populated');
        System.assertNotEquals(null, updated.Segmentation__c,
            'Segmentation__c must be populated');
    }

    @isTest
    static void testProcessAccounts_list_emptyList_doesNotThrow() {
        Test.startTest();
        AccountService.processAccounts(new List<Account>());
        Test.stopTest();
        System.assert(true, 'An empty list must not throw an exception');
    }

    @isTest
    static void testProcessAccounts_list_nullList_doesNotThrow() {
        Test.startTest();
        AccountService.processAccounts((List<Account>) null);
        Test.stopTest();
        System.assert(true, 'A null list must not throw an exception');
    }

    // =========================================================================
    // processAccounts(List<Account>, Boolean)  –  setQuadPending overload
    // =========================================================================

    @isTest
    static void testProcessAccounts_list_quadPendingTrue_setsFlag() {
        Account acc = TestDataFactory.createHouseholdAccount(
            'List Quad Pending HH', 5000000, 300000, 2000000, null, true
        );
        List<Account> accounts = [
            SELECT Id, Stated_Net_Worth__c, Stated_HH_Income__c, Billed_AUM__c,
                   Segmentation_Score__c, Segmentation__c, Segmentation_Lock_Date__c
            FROM   Account
            WHERE  Id = :acc.Id
        ];

        Test.startTest();
        AccountService.processAccounts(accounts, true);
        Test.stopTest();

        Account result = [SELECT Quad_Meeting_Creation_Pending__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must be true when setQuadPending = true');
    }

    @isTest
    static void testProcessAccounts_list_quadPendingFalse_doesNotSetFlag() {
        Account acc = TestDataFactory.createHouseholdAccount(
            'List No Quad HH', 5000000, 300000, 2000000, null, true
        );
        List<Account> accounts = [
            SELECT Id, Stated_Net_Worth__c, Stated_HH_Income__c, Billed_AUM__c,
                   Segmentation_Score__c, Segmentation__c, Segmentation_Lock_Date__c
            FROM   Account
            WHERE  Id = :acc.Id
        ];

        Test.startTest();
        AccountService.processAccounts(accounts, false);
        Test.stopTest();

        Account result = [SELECT Quad_Meeting_Creation_Pending__c FROM Account WHERE Id = :acc.Id];
        System.assertNotEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must not be true when setQuadPending = false');
    }

    // =========================================================================
    // processAccountsWithResult(List<Account>)  –  backward-compatible overload
    // =========================================================================

    @isTest
    static void testProcessAccountsWithResult_success_returnsEmptyErrorMap() {
        Account acc = TestDataFactory.createHouseholdAccount(
            'WithResult Success HH', 5000000, 300000, 2000000, null, true
        );
        List<Account> accounts = [
            SELECT Id, Stated_Net_Worth__c, Stated_HH_Income__c, Billed_AUM__c,
                   Segmentation_Score__c, Segmentation__c, Segmentation_Lock_Date__c
            FROM   Account
            WHERE  Id = :acc.Id
        ];

        Test.startTest();
        Map<Id, String> errors = AccountService.processAccountsWithResult(accounts);
        Test.stopTest();

        System.assertEquals(0, errors.size(),
            'Successful processing must return an empty error map');
    }

    @isTest
    static void testProcessAccountsWithResult_emptyList_returnsEmptyMap() {
        Test.startTest();
        Map<Id, String> errors = AccountService.processAccountsWithResult(new List<Account>());
        Test.stopTest();
        System.assertEquals(0, errors.size(),
            'An empty list must return an empty error map');
    }

    @isTest
    static void testProcessAccountsWithResult_nullList_returnsEmptyMap() {
        Test.startTest();
        Map<Id, String> errors = AccountService.processAccountsWithResult((List<Account>) null);
        Test.stopTest();
        System.assertEquals(0, errors.size(),
            'A null list must return an empty error map');
    }

    // =========================================================================
    // processAccountsWithResult(List<Account>, Boolean)  –  setQuadPending overload
    // =========================================================================

    @isTest
    static void testProcessAccountsWithResult_quadPendingTrue_setsFlag() {
        Account acc = TestDataFactory.createHouseholdAccount(
            'WithResult Quad HH', 5000000, 300000, 2000000, null, true
        );
        List<Account> accounts = [
            SELECT Id, Stated_Net_Worth__c, Stated_HH_Income__c, Billed_AUM__c,
                   Segmentation_Score__c, Segmentation__c, Segmentation_Lock_Date__c
            FROM   Account
            WHERE  Id = :acc.Id
        ];

        Test.startTest();
        Map<Id, String> errors = AccountService.processAccountsWithResult(accounts, true);
        Test.stopTest();

        System.assertEquals(0, errors.size(), 'No DML errors expected');
        Account result = [SELECT Quad_Meeting_Creation_Pending__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must be true when setQuadPending = true');
    }

    @isTest
    static void testProcessAccountsWithResult_quadPendingFalse_doesNotSetFlag() {
        Account acc = TestDataFactory.createHouseholdAccount(
            'WithResult No Quad HH', 5000000, 300000, 2000000, null, true
        );
        List<Account> accounts = [
            SELECT Id, Stated_Net_Worth__c, Stated_HH_Income__c, Billed_AUM__c,
                   Segmentation_Score__c, Segmentation__c, Segmentation_Lock_Date__c
            FROM   Account
            WHERE  Id = :acc.Id
        ];

        Test.startTest();
        Map<Id, String> errors = AccountService.processAccountsWithResult(accounts, false);
        Test.stopTest();

        System.assertEquals(0, errors.size(), 'No DML errors expected');
        Account result = [SELECT Quad_Meeting_Creation_Pending__c FROM Account WHERE Id = :acc.Id];
        System.assertNotEquals(true, result.Quad_Meeting_Creation_Pending__c,
            'Quad_Meeting_Creation_Pending__c must not be true when setQuadPending = false');
    }

    // =========================================================================
    // Bulk – governor limit safety (200 records via TestDataFactory)
    // =========================================================================

    @isTest
    static void testProcessAccounts_bulk200Records_completesWithinLimits() {
        // Use factory return value directly – avoids LIKE query that breaks
        // when an org trigger renames Account records after insert.
        List<Account> accounts = TestDataFactory.createHouseholdAccounts(200, true);
        System.assertEquals(200, accounts.size(), 'Prerequisite: 200 records inserted');

        Set<Id> accountIds = (new Map<Id, Account>(accounts)).keySet();

        Test.startTest();
        AccountService.processAccounts(accounts);
        Test.stopTest();

        Integer processedCount = [
            SELECT COUNT()
            FROM   Account
            WHERE  Id IN :accountIds
            AND    Segmentation_Score__c != null
        ];
        System.assertEquals(200, processedCount,
            'All 200 bulk accounts must be segmented successfully');
    }
}