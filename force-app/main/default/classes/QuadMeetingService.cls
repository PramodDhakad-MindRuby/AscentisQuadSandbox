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
    // RECORD TYPE DEV NAME → CUSTOM METADATA KEY
    // Maps actual RT DeveloperName values to the Record_Type_Dev_Name__c values
    // stored in Quad_Agenda_Template__mdt records.
    // =========================================================================
    @TestVisible
    private static final Map<String, String> RT_DEV_NAME_TO_CMT_KEY =
        new Map<String, String>{
            RT_CASH_FLOW        => 'RT_CASH_FLOW',
            RT_RISK_MANAGEMENT  => 'RT_RISK_MANAGEMENT',
            RT_ESTATE_PLANNING  => 'RT_ESTATE_PLANNING',
            RT_TAX_PLANNING     => 'RT_TAX_PLANNING',
            RT_B_SEGMENT_1H     => 'RT_B_SEGMENT_1H',
            RT_B_SEGMENT_2H     => 'RT_B_SEGMENT_2H',
            RT_C_SEGMENT        => 'RT_C_SEGMENT',
            RT_INTRODUCTORY     => 'RT_INTRODUCTORY'
        };

    // =========================================================================
    // RECORD TYPE → EXPIRATION MONTH (last month of the quarter/period)
    // Q1 (Cash Flow)         → Mar 31  (month 3,  day 31)
    // Q2 (Risk Mgmt) / H1   → Jun 30  (month 6,  day 30)
    // Q3 (Estate Planning)   → Sep 30  (month 9,  day 30)
    // Q4 (Tax Planning) / H2 / C / Intro → Dec 31 (month 12, day 31)
    // =========================================================================
    @TestVisible
    private static final Map<String, Integer> RT_EXPIRATION_MONTH =
        new Map<String, Integer>{
            RT_CASH_FLOW       => 3,
            RT_RISK_MANAGEMENT => 6,
            RT_ESTATE_PLANNING => 9,
            RT_TAX_PLANNING    => 12,
            RT_B_SEGMENT_1H    => 6,
            RT_B_SEGMENT_2H    => 12,
            RT_C_SEGMENT       => 12,
            RT_INTRODUCTORY    => 12
        };

    // =========================================================================
    // RECORD TYPE → TARGET MEETING MONTH (day is always 15)
    // Annual:   use fixed month from this map
    // Mid-year: RT_INTRODUCTORY → Today + 15 days (handled in buildMeeting)
    //           All others      → use fixed month from this map
    // Q1 / H1 / C  → Jan 15   (month 1)
    // Q2          → Apr 15   (month 4)
    // Q3 / H2     → Jul 15   (month 7)
    // Q4          → Oct 15   (month 10)
    // =========================================================================
    @TestVisible
    private static final Map<String, Integer> RT_TARGET_MEETING_MONTH =
        new Map<String, Integer>{
            RT_CASH_FLOW       => 1,   // Q1  → 15 Jan
            RT_RISK_MANAGEMENT => 4,   // Q2  → 15 Apr
            RT_ESTATE_PLANNING => 7,   // Q3  → 15 Jul
            RT_TAX_PLANNING    => 10,  // Q4  → 15 Oct
            RT_B_SEGMENT_1H    => 1,   // H1  → 15 Jan
            RT_B_SEGMENT_2H    => 7,   // H2  → 15 Jul
            RT_C_SEGMENT       => 1    // C   → 15 Jan
        };

    // =========================================================================
    // LAZY-LOADED STATIC CACHE
    // Populated on first access; reused within the same transaction.
    // =========================================================================
    @TestVisible
    private static Map<String, Quad_Agenda_Template__mdt> agendaTemplateCache {
        get {
            if (agendaTemplateCache == null) {
                agendaTemplateCache = new Map<String, Quad_Agenda_Template__mdt>();
                for (Quad_Agenda_Template__mdt template : [
                    SELECT Record_Type_Dev_Name__c, Agenda_Template__c, Is_Active__c
                    FROM   Quad_Agenda_Template__mdt
                    WHERE  Is_Active__c = true
                ]) {
                    if (String.isNotBlank(template.Record_Type_Dev_Name__c)) {
                        agendaTemplateCache.put(template.Record_Type_Dev_Name__c, template);
                    }
                }
            }
            return agendaTemplateCache;
        }
        set;
    }

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

        Map<Id, Account>      accountMap    = queryAccounts(accountIds);
        Set<Id>               skipSet       = getAccountsWithMeetingsThisYear(accountIds);
        Map<String, Id>       recordTypeMap = getRecordTypeMap();
        List<Quad_Meeting__c> toInsert      = new List<Quad_Meeting__c>();

        for (Id accId : accountIds) {
            if (skipSet.contains(accId)) {
                continue;
            }

            Account acc = accountMap.get(accId);
            if (acc == null || String.isBlank(acc.Segmentation__c)) continue;

            List<String> rtDevNames = ANNUAL_SEGMENTATION_RECORD_TYPES.get(acc.Segmentation__c);
            if (rtDevNames == null || rtDevNames.isEmpty()) continue;

            for (String rtDevName : rtDevNames) {
                toInsert.add(buildMeeting(accId, recordTypeMap.get(rtDevName), rtDevName, acc.Name, acc.OwnerId, false));
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
                continue;
            }

            Account acc     = accountMap.get(accId);
            String  seg     = (acc != null) ? acc.Segmentation__c : null;
            String  accName = (acc != null && !String.isBlank(acc.Name)) ? acc.Name : '';
            Id      accOwner = (acc != null) ? acc.OwnerId : null;

            // Always create Introductory Quad first
            toInsert.add(buildMeeting(accId, introRtId, RT_INTRODUCTORY, accName, accOwner, true));

            if (String.isBlank(seg)) continue;

            // AAA / A – add remaining quarters AFTER the current quarter
            if (seg == 'AAA' || seg == 'A') {
                // AAA_A_QUARTERLY_SEQUENCE is 0-indexed: index 0=Q1, 1=Q2, 2=Q3, 3=Q4
                // Remaining = quarters whose index >= currentQuarter (i.e. after current quarter)
                for (Integer i = currentQuarter; i < AAA_A_QUARTERLY_SEQUENCE.size(); i++) {
                    String rtDevName = AAA_A_QUARTERLY_SEQUENCE[i];
                    toInsert.add(buildMeeting(accId, recordTypeMap.get(rtDevName), rtDevName, accName, accOwner, true));
                }
            }
            // B – add B-Segment 2H only when onboarding happens in H1 (there is still H2 remaining)
            else if (seg == 'B') {
                if (isFirstHalf) {
                    toInsert.add(buildMeeting(accId, recordTypeMap.get(RT_B_SEGMENT_2H), RT_B_SEGMENT_2H, accName, accOwner, true));
                }
            }
            // C – Intro only; no additional records needed
        }

        insertMeetings(toInsert); // No Account field update required for mid-year onboarding
    }

    // =========================================================================
    // ARCHIVE EXPIRED MEETINGS
    // =========================================================================

    /**
     * @description Bulk-archives Quad Meeting records whose Expiration_Date__c was yesterday.
     *              Called from QuadMeetingArchiveBatch.execute() on each batch chunk.
     *
     *              Updates per record:
     *                - Meeting_Status__c    → 'Archived'
     *                - Incomplete_Reason__c  → 'Updated by Automation'
     *
     *              Uses partial DML (allOrNothing = false) so one bad record cannot
     *              block the rest of the chunk. All DML errors are captured via
     *              ErrorLogService for future troubleshooting.
     *
     * @param meetingIds  Set of Quad_Meeting__c Ids to archive (passed from the batch scope).
     */
    public static void archiveExpiredMeetings(Set<Id> meetingIds) {
        if (meetingIds == null || meetingIds.isEmpty()) return;

        List<Quad_Meeting__c> toUpdate = new List<Quad_Meeting__c>();
        for (Id mId : meetingIds) {
            toUpdate.add(new Quad_Meeting__c(
                Id                  = mId,
                Meeting_Status__c   = 'Archived',
                Incomplete_Reason__c = 'Updated by Automation'
            ));
        }

        List<Database.SaveResult> results   = Database.update(toUpdate, false);
        List<Error_Log__c>        errorLogs = new List<Error_Log__c>();

        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    errorLogs.add(ErrorLogService.buildLog(
                        'QuadMeetingService', 'archiveExpiredMeetings',
                        'Archive update failed for Quad Meeting: ' + toUpdate[i].Id +
                        ' | Error: ' + err.getMessage(),
                        null, ErrorLogService.SEVERITY_ERROR, ErrorLogService.TYPE_APEX
                    ));
                }
            }
        }
        ErrorLogService.insertLogs(errorLogs);
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
     *              Naming convention: "{year} {period} | {Account Name}"
     *              e.g.  "2026 Q3 | Smith Household"
     *                    "2026 Intro | Smith Household"
     *
     *              Target_Meeting_Date__c rules:
     *              Mid-year  – RT_INTRODUCTORY  → Today + 15 days
     *              Mid-year  – all others       → 15th of the configured target month
     *              Annual    – all types        → 15th of the configured target month
     *
     * @param isMidYear  true  = mid-year onboarding path (createMidYearQuadMeetings)
     *                   false = annual batch path (createAnnualQuadMeetings)
     */
    private static Quad_Meeting__c buildMeeting(Id accountId, Id recordTypeId, String rtDevName,
                                                String accountName, Id ownerId, Boolean isMidYear) {
        String  period      = RECORD_TYPE_NAME_PREFIX.containsKey(rtDevName) ? RECORD_TYPE_NAME_PREFIX.get(rtDevName) : '';
        String  fyLabel     = '' + Date.today().year();
        String  meetingName = fyLabel + ' ' + period + ' | ' + (String.isBlank(accountName) ? '' : accountName);

        Integer expirationMonth = RT_EXPIRATION_MONTH.get(rtDevName);
        Integer expirationDay   = (expirationMonth != null && (expirationMonth == 3 || expirationMonth == 12)) ? 31 : 30;
        Date    expirationDate  = (expirationMonth != null)
            ? Date.newInstance(Date.today().year(), expirationMonth, expirationDay)
            : null;

        // ── Target Meeting Date ──────────────────────────────────────────────
        // Mid-year Introductory  → Today + 15 days
        // Everything else        → 15th of the configured target month
        // If the resolved date falls on a Saturday or Sunday, roll forward to Monday.
        Date targetMeetingDate;
        if (isMidYear && rtDevName == RT_INTRODUCTORY) {
            targetMeetingDate = adjustForWeekend(Date.today().addDays(15));
        } else {
            Integer targetMonth = RT_TARGET_MEETING_MONTH.get(rtDevName);
            if (targetMonth != null) {
                targetMeetingDate = adjustForWeekend(Date.newInstance(Date.today().year(), targetMonth, 15));
            }
        }
        // ────────────────────────────────────────────────────────────────────

        Quad_Meeting__c meeting = new Quad_Meeting__c(
            Name                  = meetingName,
            Client_Account__c     = accountId,
            Meeting_Status__c     = 'Need to Schedule',
            Meeting_Date__c       = Date.today(),
            Goals_for_Year__c     = Date.newInstance(Date.today().year(), 1, 1),
            Expiration_Date__c    = expirationDate,
            Target_Meeting_Date__c = targetMeetingDate,
            OwnerId               = ownerId
        );
        if (recordTypeId != null) {
            meeting.RecordTypeId = recordTypeId;
        }
        // Populate Agenda_Topics__c from the lazy-loaded static cache
        String cmtKey = RT_DEV_NAME_TO_CMT_KEY.get(rtDevName);
        Quad_Agenda_Template__mdt agendaTemplate = (cmtKey != null) ? agendaTemplateCache.get(cmtKey) : null;
        if (agendaTemplate != null && String.isNotBlank(agendaTemplate.Agenda_Template__c)) {
            // Extract the long text value
            String plainTextAgenda = agendaTemplate.Agenda_Template__c;
    
            // Replace carriage returns and newlines with HTML line breaks
            String htmlAgenda = plainTextAgenda.replaceAll('\r\n', '<br/>').replaceAll('\n', '<br/>');
    
            // Assign the formatted HTML string to the Rich Text Area field
            meeting.Agenda_Topics__c = htmlAgenda;
        }
        return meeting;
    }

    /**
     * @description Adjusts a date forward to Monday if it falls on a weekend.
     *              Saturday → +2 days → Monday
     *              Sunday   → +1 day  → Monday
     *              Weekdays → unchanged
     * @param  d  The candidate date to check.
     * @return    The same date if it is a weekday, otherwise the following Monday.
     */
    @TestVisible
    private static Date adjustForWeekend(Date d) {
        // Day-of-week index: daysBetween from a known Sunday (1900-01-07) mod 7
        // gives 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
        Integer dayOfWeek = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(d), 7);
        if (dayOfWeek == 0) {        // Sunday  → roll to Monday
            return d.addDays(1);
        } else if (dayOfWeek == 6) { // Saturday → roll to Monday
            return d.addDays(2);
        }
        return d;
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
        List<Error_Log__c> errorLogs = new List<Error_Log__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successfulAccountIds.add(meetings[i].Client_Account__c);
            } else {
                for (Database.Error err : results[i].getErrors()) {
                    errorLogs.add(ErrorLogService.buildLog(
                        'QuadMeetingService', 'insertMeetings',
                        'Quad Meeting insert failed for Account: ' + meetings[i].Client_Account__c +
                        ' | RecordTypeId: ' + meetings[i].RecordTypeId +
                        ' | Error: ' + err.getMessage(),
                        null, ErrorLogService.SEVERITY_ERROR, ErrorLogService.TYPE_APEX
                    ));
                }
            }
        }
        ErrorLogService.insertLogs(errorLogs);
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
        List<Error_Log__c> errorLogs = new List<Error_Log__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    errorLogs.add(ErrorLogService.buildLog(
                        'QuadMeetingService', 'updateAccountsPostQuadCreation',
                        'Account update failed post Quad Meeting creation for Account: ' +
                        accountsToUpdate[i].Id + ' | Error: ' + err.getMessage(),
                        null, ErrorLogService.SEVERITY_ERROR, ErrorLogService.TYPE_APEX
                    ));
                }
            }
        }
        ErrorLogService.insertLogs(errorLogs);
    }
}