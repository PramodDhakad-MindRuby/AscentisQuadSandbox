/**
 * @class       QuadMeetingService
 * @description Dynamic, reusable service class for creating Quad Meeting records.
 *              Supports two execution modes:
 *
 *              1. ANNUAL BATCH (Jan 1st) – createAnnualQuadMeetings(accountIds)
 *                 Called from the scheduled batch class on January 1st each year.
 *                 Evaluates Account Segmentation__c and creates all typed records for the full year:
 *                   - AAA / A  → Cash Flow (Q1), Risk Management (Q2), Estate Planning (Q3), Tax Planning (Q4)
 *                   - B        → B-Segment 1H, B-Segment 2H
 *                   - C        → C-Segment
 *
 *              2. MID-YEAR ONBOARDING – createMidYearQuadMeetings(accountIds)
 *                 Called from OpportunityTriggerHelperAfterUpdate for accounts onboarded after Jan 1st.
 *                 Always creates an Introductory Quad, then based on current quarter/half:
 *                   - AAA / A  → Intro + remaining quarters after today's quarter
 *                                (Q1 → Intro + Q2, Q3, Q4 | Q2 → Intro + Q3, Q4 | Q3 → Intro + Q4 | Q4 → Intro only)
 *                   - B        → Intro + B-Segment 2H (only if current date is in H1 i.e. Jan–Jun)
 *                   - C        → Intro only
 *
 *              Record Types are resolved dynamically by DeveloperName.
 *              Duplicate prevention: skips Accounts that already have Quad
 *              Meetings created in the current calendar year.
 *
 *              Naming convention: "FY{year} {period} | {Account Name}"
 *              e.g.  "FY2026 Q3 | Smith Household"
 *
 * @author      Mindruby Team
 * @date        2026-05-04
 */
public with sharing class QuadMeetingService {

    // =========================================================================
    // CONSTANTS – Record Type Developer Names
    // =========================================================================
    @TestVisible static final String RT_CASH_FLOW        = 'Cash_Flow';
    @TestVisible static final String RT_RISK_MANAGEMENT  = 'Risk_Management';
    @TestVisible static final String RT_ESTATE_PLANNING  = 'Estate_Planning';
    @TestVisible static final String RT_TAX_PLANNING     = 'Tax_Planning';
    @TestVisible static final String RT_B_SEGMENT_1H     = 'B_Segment_1H';
    @TestVisible static final String RT_B_SEGMENT_2H     = 'B_Segment_2H';
    @TestVisible static final String RT_C_SEGMENT        = 'C_Segment';
    @TestVisible static final String RT_INTRODUCTORY     = 'Introductory_Quad';

    // =========================================================================
    // ANNUAL SEGMENTATION MAP
    // Full-year record types per segmentation (used by Annual Batch on Jan 1st)
    // =========================================================================
    @TestVisible
    private static final Map<String, List<String>> ANNUAL_SEGMENTATION_RECORD_TYPES =
        new Map<String, List<String>>{
            'AAA' => new List<String>{ RT_CASH_FLOW, RT_RISK_MANAGEMENT, RT_ESTATE_PLANNING, RT_TAX_PLANNING },
            'A'   => new List<String>{ RT_CASH_FLOW, RT_RISK_MANAGEMENT, RT_ESTATE_PLANNING, RT_TAX_PLANNING },
            'B'   => new List<String>{ RT_B_SEGMENT_1H, RT_B_SEGMENT_2H },
            'C'   => new List<String>{ RT_C_SEGMENT }
        };

    // =========================================================================
    // AAA/A QUARTERLY SEQUENCE
    // Ordered list: index 0 = Q1, 1 = Q2, 2 = Q3, 3 = Q4
    // Used to determine remaining quarters from current quarter onward.
    // =========================================================================
    @TestVisible
    private static final List<String> AAA_A_QUARTERLY_SEQUENCE =
        new List<String>{ RT_CASH_FLOW, RT_RISK_MANAGEMENT, RT_ESTATE_PLANNING, RT_TAX_PLANNING };

    // =========================================================================
    // RECORD TYPE → PERIOD LABEL (used in naming convention)
    // Naming format: "FY{year} {period} | {Account Name}"
    // =========================================================================
    @TestVisible
    private static final Map<String, String> RECORD_TYPE_NAME_PREFIX =
        new Map<String, String>{
            RT_CASH_FLOW       => 'Q1',
            RT_RISK_MANAGEMENT => 'Q2',
            RT_ESTATE_PLANNING => 'Q3',
            RT_TAX_PLANNING    => 'Q4',
            RT_B_SEGMENT_1H    => 'H1',
            RT_B_SEGMENT_2H    => 'H2',
            RT_C_SEGMENT       => 'C',
            RT_INTRODUCTORY    => 'Intro'
        };

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    /**
     * @description ANNUAL BATCH entry point – intended to be called on January 1st each year.
     *              For each Account, creates the full set of Quad Meeting records for the
     *              entire year based on Account Segmentation__c:
     *                - AAA / A  → Cash Flow (Q1), Risk Management (Q2), Estate Planning (Q3), Tax Planning (Q4)
     *                - B        → B-Segment 1H, B-Segment 2H
     *                - C        → C-Segment
     *              Accounts already having Quad Meetings in the current year are skipped.
     *
     * @param accountIds  Set of Account Ids to process (passed from the batch class).
     */
    public static void createAnnualQuadMeetings(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        Map<Id, Account>    accountMap    = queryAccounts(accountIds);
        Set<Id>             skipSet       = getAccountsWithMeetingsThisYear(accountIds);
        Map<String, Id>     recordTypeMap = getRecordTypeMap();
        List<Quad_Meeting__c> toInsert    = new List<Quad_Meeting__c>();

        for (Id accId : accountIds) {
            if (skipSet.contains(accId)) {
                System.debug(LoggingLevel.INFO, 'QuadMeetingService.createAnnualQuadMeetings - Skipping (already processed): ' + accId);
                continue;
            }

            Account acc = accountMap.get(accId);
            if (acc == null || String.isBlank(acc.Segmentation__c)) continue;

            List<String> rtDevNames = ANNUAL_SEGMENTATION_RECORD_TYPES.get(acc.Segmentation__c);
            if (rtDevNames == null || rtDevNames.isEmpty()) continue;

            for (String rtDevName : rtDevNames) {
                toInsert.add(buildMeeting(accId, recordTypeMap.get(rtDevName), rtDevName, acc.Name, acc.OwnerId));
            }
        }

        Set<Id> successfulAccountIds = insertMeetings(toInsert);
        updateAccountsPostQuadCreation(successfulAccountIds);
    }

    /**
     * @description MID-YEAR ONBOARDING entry point – called from OpportunityTriggerHelperAfterUpdate.
     *              Creates an Introductory Quad record for every qualifying Account, then
     *              adds remaining period-based records depending on the current date and segmentation:
     *
     *                AAA / A (quarter-based):
     *                  Current Q1 (Jan–Mar) → Intro + Q2 (Risk Mgmt) + Q3 (Estate) + Q4 (Tax)
     *                  Current Q2 (Apr–Jun) → Intro + Q3 (Estate) + Q4 (Tax)
     *                  Current Q3 (Jul–Sep) → Intro + Q4 (Tax)
     *                  Current Q4 (Oct–Dec) → Intro only
     *
     *                B (half-based):
     *                  Current H1 (Jan–Jun) → Intro + B-Segment 2H
     *                  Current H2 (Jul–Dec) → Intro only
     *
     *                C → Intro only (regardless of date)
     *
     *              Accounts already having Quad Meetings in the current year are skipped.
     *
     * @param accountIds  Set of Account Ids to process (passed from OpportunityTriggerHelperAfterUpdate).
     */
    public static void createMidYearQuadMeetings(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        Map<Id, Account>    accountMap    = queryAccounts(accountIds);
        Set<Id>             skipSet       = getAccountsWithMeetingsThisYear(accountIds);
        Map<String, Id>     recordTypeMap = getRecordTypeMap();
        Id                  introRtId     = recordTypeMap.get(RT_INTRODUCTORY);

        // Determine current quarter (1–4) and half (1–2) once for all accounts
        Integer currentMonth   = Date.today().month();
        Integer currentQuarter = getCurrentQuarter(currentMonth);   // 1, 2, 3, or 4
        Boolean isFirstHalf    = (currentMonth <= 6);               // Jan–Jun = H1

        List<Quad_Meeting__c> toInsert = new List<Quad_Meeting__c>();

        for (Id accId : accountIds) {
            if (skipSet.contains(accId)) {
                System.debug(LoggingLevel.INFO, 'QuadMeetingService.createMidYearQuadMeetings - Skipping (already processed): ' + accId);
                continue;
            }

            Account acc     = accountMap.get(accId);
            String  seg     = (acc != null) ? acc.Segmentation__c : null;
            String  accName = (acc != null && !String.isBlank(acc.Name)) ? acc.Name : '';
            Id      accOwner = (acc != null) ? acc.OwnerId : null;

            // Always create Introductory Quad first
            toInsert.add(buildMeeting(accId, introRtId, RT_INTRODUCTORY, accName, accOwner));

            if (String.isBlank(seg)) continue;

            // AAA / A – add remaining quarters AFTER the current quarter
            if (seg == 'AAA' || seg == 'A') {
                // AAA_A_QUARTERLY_SEQUENCE is 0-indexed: index 0=Q1, 1=Q2, 2=Q3, 3=Q4
                // Remaining = quarters whose index >= currentQuarter (i.e. after current quarter)
                for (Integer i = currentQuarter; i < AAA_A_QUARTERLY_SEQUENCE.size(); i++) {
                    String rtDevName = AAA_A_QUARTERLY_SEQUENCE[i];
                    toInsert.add(buildMeeting(accId, recordTypeMap.get(rtDevName), rtDevName, accName, accOwner));
                }
            }
            // B – add B-Segment 2H only when onboarding happens in H1 (there is still H2 remaining)
            else if (seg == 'B') {
                if (isFirstHalf) {
                    toInsert.add(buildMeeting(accId, recordTypeMap.get(RT_B_SEGMENT_2H), RT_B_SEGMENT_2H, accName, accOwner));
                }
            }
            // C – Intro only; no additional records needed
        }

        insertMeetings(toInsert); // No Account field update required for mid-year onboarding
    }

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    /**
     * @description Returns the current fiscal quarter (1–4) based on the calendar month.
     *              Q1 = Jan–Mar, Q2 = Apr–Jun, Q3 = Jul–Sep, Q4 = Oct–Dec.
     */
    private static Integer getCurrentQuarter(Integer month) {
        if (month <= 3)  return 1;
        if (month <= 6)  return 2;
        if (month <= 9)  return 3;
        return 4;
    }

    /**
     * @description Builds a Quad_Meeting__c record.
     *              Naming convention: "FY{year} {period} | {Account Name}"
     *              e.g.  "FY2026 Q3 | Smith Household"
     *                    "FY2026 Intro | Smith Household"
     */
    private static Quad_Meeting__c buildMeeting(Id accountId, Id recordTypeId, String rtDevName, String accountName, Id ownerId) {
        String  period      = RECORD_TYPE_NAME_PREFIX.containsKey(rtDevName) ? RECORD_TYPE_NAME_PREFIX.get(rtDevName) : '';
        String  fyLabel     = '' + Date.today().year();
        String  meetingName = fyLabel + ' ' + period + ' | ' + (String.isBlank(accountName) ? '' : accountName);

        Quad_Meeting__c meeting = new Quad_Meeting__c(
            Name              = meetingName,
            Client_Account__c = accountId,
            Meeting_Status__c = 'Need to Schedule',
            Meeting_Date__c   = Date.today(),
            Goals_for_Year__c = Date.newInstance(Date.today().year(), 1, 1),
            OwnerId           = ownerId
        );
        if (recordTypeId != null) {
            meeting.RecordTypeId = recordTypeId;
        }
        return meeting;
    }

    /**
     * @description Queries Account fields required for segmentation and naming.
     */
    private static Map<Id, Account> queryAccounts(Set<Id> accountIds) {
        Map<Id, Account> accountMap = new Map<Id, Account>();
        for (Account acc : [
            SELECT Id, Name, Segmentation__c, CreatedDate, OwnerId
            FROM   Account
            WHERE  Id IN :accountIds
        ]) {
            accountMap.put(acc.Id, acc);
        }
        return accountMap;
    }

    /**
     * @description Returns Account Ids that already have at least one Quad Meeting
     *              record in the current calendar year (duplicate prevention).
     */
    @TestVisible
    private static Set<Id> getAccountsWithMeetingsThisYear(Set<Id> accountIds) {
        Set<Id>  result    = new Set<Id>();
        Integer  currYear  = Date.today().year();
        Date     yearStart = Date.newInstance(currYear, 1, 1);
        Date     yearEnd   = Date.newInstance(currYear, 12, 31);
        for (AggregateResult ar : [
            SELECT Client_Account__c
            FROM   Quad_Meeting__c
            WHERE  Client_Account__c IN :accountIds
            AND    Goals_for_Year__c >= :yearStart
            AND    Goals_for_Year__c <= :yearEnd
            GROUP BY Client_Account__c
        ]) {
            result.add((Id) ar.get('Client_Account__c'));
        }
        return result;
    }

    /**
     * @description Dynamically fetches all Record Type Ids for Quad_Meeting__c
     *              keyed by DeveloperName. Avoids hardcoded Ids.
     */
    @TestVisible
    private static Map<String, Id> getRecordTypeMap() {
        Map<String, Id> rtMap = new Map<String, Id>();
        for (RecordType rt : [
            SELECT Id, DeveloperName
            FROM   RecordType
            WHERE  SObjectType = 'Quad_Meeting__c'
        ]) {
            rtMap.put(rt.DeveloperName, rt.Id);
        }
        return rtMap;
    }

    /**
     * @description Performs a partial DML insert and logs any per-record errors.
     *              Returns a Set of Account Ids for which at least one Quad Meeting
     *              was successfully inserted (used for post-creation Account updates).
     */
    private static Set<Id> insertMeetings(List<Quad_Meeting__c> meetings) {
        Set<Id> successfulAccountIds = new Set<Id>();
        if (meetings == null || meetings.isEmpty()) return successfulAccountIds;

        List<Database.SaveResult> results = Database.insert(meetings, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successfulAccountIds.add(meetings[i].Client_Account__c);
            } else {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'QuadMeetingService - Insert failed. ' +
                        'Account: '       + meetings[i].Client_Account__c +
                        ' | RecordType: ' + meetings[i].RecordTypeId +
                        ' | Error: '      + err.getMessage()
                    );
                }
            }
        }
        return successfulAccountIds;
    }

    /**
     * @description After successful Quad Meeting creation (annual batch only),
     *              updates the following fields on the related Accounts:
     *                - Segmentation_Lock_Date__c  → today's date
     *                - Quad_Meeting_Creation_Pending__c → false
     *              Only Accounts with at least one successfully inserted Quad record are updated.
     *              Uses partial DML to avoid a single bad record blocking the rest.
     *
     * @param accountIds  Set of Account Ids to update.
     */
    private static void updateAccountsPostQuadCreation(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        List<Account> accountsToUpdate = new List<Account>();
        for (Id accId : accountIds) {
            accountsToUpdate.add(new Account(
                Id                               = accId,
                Segmentation_Lock_Date__c        = Date.today(),
                Quad_Meeting_Creation_Pending__c = false
            ));
        }

        List<Database.SaveResult> results = Database.update(accountsToUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'QuadMeetingService - Account update failed post Quad creation. ' +
                        'Account: ' + accountsToUpdate[i].Id +
                        ' | Error: ' + err.getMessage()
                    );
                }
            }
        }
    }
}