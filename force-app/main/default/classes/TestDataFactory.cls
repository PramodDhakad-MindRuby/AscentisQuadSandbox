/**
 * @class       TestDataFactory
 * @description Centralised test data factory used by all test classes.
 *              Annotated with @isTest so it is excluded from org code-size limits
 *              and is accessible only from a running test context.
 *
 *              Supported objects
 *              ─────────────────
 *              • Account  (Household – includes all segmentation fields)
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
public class TestDataFactory {

    // =========================================================================
    // ACCOUNT
    // =========================================================================

    /**
     * @description Creates a standard unlocked Household Account with sensible
     *              default financial values (Net Worth 5 M, Income 300 K, AUM 2 M).
     *              No lock date is set so segmentation can be calculated freely.
     *
     * @param  doInsert  When true the record is inserted before returning.
     * @return           New Account record.
     */
    public static Account createHouseholdAccount(Boolean doInsert) {
        return createHouseholdAccount(
            'Test Household Account',
            5000000,
            300000,
            2000000,
            null,
            doInsert
        );
    }

    /**
     * @description Creates a Household Account with full parameter control.
     *              Pass lockDate = null to leave the account unlocked.
     *              Delegates to the testTag overload with testTag = null.
     *
     * @param  name      Account Name.
     * @param  netWorth  Stated_Net_Worth__c value.
     * @param  income    Stated_HH_Income__c value.
     * @param  aum       Billed_AUM__c value.
     * @param  lockDate  Segmentation_Lock_Date__c value (null = unlocked).
     * @param  doInsert  When true the record is inserted before returning.
     * @return           New Account record.
     */
    public static Account createHouseholdAccount(
        String  name,
        Decimal netWorth,
        Decimal income,
        Decimal aum,
        Date    lockDate,
        Boolean doInsert
    ) {
        return createHouseholdAccount(name, netWorth, income, aum, lockDate, null, doInsert);
    }

    /**
     * @description Creates a Household Account with full parameter control and a
     *              stable test tag stored in External_System_ID__c.
     *
     *              Flows and triggers frequently rename the Account.Name field after
     *              save (e.g. Household_Account_Created_or_Updated renames to
     *              "LastName, FirstName | State | HH | Id"). Storing a unique tag
     *              in External_System_ID__c — a field that no flow touches — lets
     *              test methods reliably re-query @TestSetup records by that tag
     *              instead of by Name.
     *
     * @param  name      Account Name (may be overwritten by a flow after insert).
     * @param  netWorth  Stated_Net_Worth__c value.
     * @param  income    Stated_HH_Income__c value.
     * @param  aum       Billed_AUM__c value.
     * @param  lockDate  Segmentation_Lock_Date__c value (null = unlocked).
     * @param  testTag   Value written to External_System_ID__c; must be ≤ 25 chars.
     *                   Pass null when tagging is not needed.
     * @param  doInsert  When true the record is inserted before returning.
     * @return           New Account record.
     */
    public static Account createHouseholdAccount(
        String  name,
        Decimal netWorth,
        Decimal income,
        Decimal aum,
        Date    lockDate,
        String  testTag,
        Boolean doInsert
    ) {
        Account acc = new Account(
            Name                      = name,
            Stated_Net_Worth__c       = netWorth,
            Stated_HH_Income__c       = income,
            Billed_AUM__c             = aum,
            Segmentation_Lock_Date__c = lockDate,
            External_System_ID__c     = testTag
        );
        if (doInsert) {
            insert acc;
        }
        return acc;
    }

    /**
     * @description Creates a Household Account locked in the current calendar year.
     *              Delegates to the testTag overload with testTag = null.
     *
     * @param  name      Account Name.
     * @param  segScore  Segmentation_Score__c value to stamp on the record.
     * @param  segment   Segmentation__c label to stamp on the record.
     * @param  doInsert  When true the record is inserted before returning.
     * @return           New Account record with lock date = today.
     */
    public static Account createLockedHouseholdAccount(
        String  name,
        Decimal segScore,
        String  segment,
        Boolean doInsert
    ) {
        return createLockedHouseholdAccount(name, segScore, segment, null, doInsert);
    }

    /**
     * @description Creates a Household Account locked in the current calendar year
     *              with a stable test tag stored in External_System_ID__c.
     *              See createHouseholdAccount(…, testTag, …) for tagging rationale.
     *
     * @param  name      Account Name (may be overwritten by a flow after insert).
     * @param  segScore  Segmentation_Score__c value to stamp on the record.
     * @param  segment   Segmentation__c label to stamp on the record.
     * @param  testTag   Value written to External_System_ID__c; must be ≤ 25 chars.
     * @param  doInsert  When true the record is inserted before returning.
     * @return           New Account record with lock date = today.
     */
    public static Account createLockedHouseholdAccount(
        String  name,
        Decimal segScore,
        String  segment,
        String  testTag,
        Boolean doInsert
    ) {
        Account acc = new Account(
            Name                      = name,
            Stated_Net_Worth__c       = 5000000,
            Stated_HH_Income__c       = 300000,
            Billed_AUM__c             = 2000000,
            Segmentation_Score__c     = segScore,
            Segmentation__c           = segment,
            Segmentation_Lock_Date__c = Date.today(),
            External_System_ID__c     = testTag
        );
        if (doInsert) {
            insert acc;
        }
        return acc;
    }

    /**
     * @description Creates a Wealth Management Household Account that satisfies
     *              every filter in AccountSegmentationBatch.start():
     *                  Client_Type__c = 'Wealth Management'
     *                  Segmentation__c        != null
     *                  Stated_Net_Worth__c    != null
     *                  Stated_HH_Income__c    != null
     *                  Billed_AUM__c          != null
     *
     *              The Account.Name is intentionally set to a dummy value because
     *              org flows overwrite it after save.  testTag is written to
     *              External_System_ID__c for stable re-querying.
     *
     * @param  testTag   Value for External_System_ID__c (≤ 25 chars).
     * @param  lockDate  Segmentation_Lock_Date__c (null = unlocked).
     * @param  segScore  Segmentation_Score__c initial value.
     * @param  segment   Segmentation__c initial value (must be non-null for batch eligibility).
     * @param  doInsert  When true the record is inserted before returning.
     * @return           New Account record.
     */
    public static Account createWMHouseholdAccount(
        String  testTag,
        Date    lockDate,
        Decimal segScore,
        String  segment,
        Boolean doInsert
    ) {
        return createWMHouseholdAccount(testTag, lockDate, segScore, segment, null, doInsert);
    }

    /**
     * @description Creates a Wealth Management Household Account that satisfies
     *              every filter in AccountSegmentationBatch.start():
     *                  Client_Type__c = 'Wealth Management'
     *                  Segmentation__c        != null
     *                  Stated_Net_Worth__c    != null
     *                  Stated_HH_Income__c    != null
     *                  Billed_AUM__c          != null
     *                  FinServ__Status__c     = provided value when not null
     *
     *              The Account.Name is intentionally set to a dummy value because
     *              org flows overwrite it after save.  testTag is written to
     *              External_System_ID__c for stable re-querying.
     *
     * @param  testTag       Value for External_System_ID__c (≤ 25 chars).
     * @param  lockDate      Segmentation_Lock_Date__c (null = unlocked).
     * @param  segScore      Segmentation_Score__c initial value.
     * @param  segment       Segmentation__c initial value (must be non-null for batch eligibility).
     * @param  finServStatus FinServ__Status__c picklist value; pass null to leave unset.
     * @param  doInsert      When true the record is inserted before returning.
     * @return               New Account record.
     */
    public static Account createWMHouseholdAccount(
        String  testTag,
        Date    lockDate,
        Decimal segScore,
        String  segment,
        String  finServStatus,
        Boolean doInsert
    ) {
        // Client_Type__c is a RecordType-controlled picklist (restricted=true).
        // Without the correct RecordTypeId, Salesforce uses the Master RecordType
        // which does not include 'Wealth Management' as a valid value, so the field
        // is silently cleared on save.
        //
        // Schema.getRecordTypeInfosByDeveloperName() keys on the LOCAL DeveloperName
        // WITHOUT any namespace prefix (i.e., 'IndustriesHousehold', never
        // 'FinServ__IndustriesHousehold'). Using Schema.describe avoids a SOQL
        // call and is null-safe via the isAvailable() guard.
        Schema.RecordTypeInfo rtInfo = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName()
            .get('IndustriesHousehold');
        Id householdRtId = (rtInfo != null && rtInfo.isAvailable())
            ? rtInfo.getRecordTypeId()
            : null;

        Account acc = new Account(
            Name                      = 'WM Household ' + testTag,
            RecordTypeId              = householdRtId,
            Stated_Net_Worth__c       = 5000000,
            Stated_HH_Income__c       = 300000,
            Billed_AUM__c             = 2000000,
            Client_Type__c            = 'Wealth Management',
            Segmentation__c           = segment,
            Segmentation_Score__c     = segScore,
            Segmentation_Lock_Date__c = lockDate,
            External_System_ID__c     = testTag
        );
        if (String.isNotBlank(finServStatus)) {
            acc.FinServ__Status__c = finServStatus;
        }
        if (doInsert) {
            insert acc;
        }
        return acc;
    }

    /**
     * @description Creates a bulk list of unlocked Household Accounts with
     *              identical mid-range financial values.  Names are sequenced
     *              as "Bulk Test HH 0", "Bulk Test HH 1", … for easy filtering.
     *
     * @param  count     Number of Account records to create.
     * @param  doInsert  When true the list is bulk-inserted before returning.
     * @return           List of Account records.
     */
    public static List<Account> createHouseholdAccounts(Integer count, Boolean doInsert) {
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accs.add(new Account(
                Name                      = 'Bulk Test HH ' + i,
                Stated_Net_Worth__c       = 3000000,
                Stated_HH_Income__c       = 150000,
                Billed_AUM__c             = 1000000,
                Segmentation_Lock_Date__c = null
            ));
        }
        if (doInsert) {
            insert accs;
        }
        return accs;
    }
}