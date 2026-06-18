/**
 * @class       AccountSegmentationBatch
 * @description Batch Apex class to bulk-process Account segmentation using
 *              AccountService.  Supports optional filtering by a SOQL WHERE
 *              clause or a fixed set of Account Ids.
 *
 * Usage examples:
 *
 *   // Process ALL accounts (no lock filter)
 *   Database.executeBatch(new AccountSegmentationBatch(), 200);
 *
 *   // Process only accounts whose segmentation is NOT locked this year
 *   Database.executeBatch(
 *       new AccountSegmentationBatch('Segmentation_Lock_Date__c = null OR CALENDAR_YEAR(Segmentation_Lock_Date__c) != 2026'),
 *       200
 *   );
 *
 *   // Process a specific set of Account Ids
 *   Set<Id> ids = new Set<Id>{ 'a001000000XXXXX', 'a001000000YYYYY' };
 *   Database.executeBatch(new AccountSegmentationBatch(ids), 200);
 *   String cronExp = '0 0 3 1 1 ? *';
 *   String jobName = 'AccountSegmentationBatch - Annual Jan 1st 3AM';
 *   System.schedule(jobName, cronExp, new AccountSegmentationBatch());
 *
 * @author      Mindruby Team
 * @date        2026-04-21
 */
public with sharing class AccountSegmentationBatch
    implements Database.Batchable<SObject>, Database.Stateful, Schedulable {

    // ─────────────────────────────────────────────────────────────────────────
    // State tracked across chunks
    // ─────────────────────────────────────────────────────────────────────────
    @TestVisible private Integer totalProcessed = 0;
    @TestVisible private Integer totalLocked    = 0;
    @TestVisible private Integer totalUpdated   = 0;

    // Optional additional WHERE clause fragment (no leading WHERE keyword)
    private String additionalFilter;
    // Optional fixed set of Ids to restrict processing
    private Set<Id> targetAccountIds;

    // Track failed records and errors for summary email
    private List<Account> failedAccounts = new List<Account>();
    private List<String> errorMessages = new List<String>();

    // =========================================================================
    // CONSTRUCTORS
    // =========================================================================

    /** Process every Account (locking is handled inside AccountService). */
    public AccountSegmentationBatch() {}

    /**
     * @description Process accounts that match an additional SOQL filter.
     * @param       additionalFilter  SOQL filter string appended with AND
     *                                (do not include the WHERE keyword).
     *                                Example: 'RecordType.Name = \'Household\''
     */
    public AccountSegmentationBatch(String additionalFilter) {
        this.additionalFilter = additionalFilter;
    }

    /**
     * @description Process a specific set of Account Ids.
     * @param       targetAccountIds  Set of Account record Ids.
     */
    public AccountSegmentationBatch(Set<Id> targetAccountIds) {
        this.targetAccountIds = targetAccountIds;
    }

    // =========================================================================
    // TEST HOOKS  (callable only from @isTest code)
    // =========================================================================

    /**
     * @description Pre-populates failedAccounts/errorMessages so that the
     *              finish() error-email branch can be exercised in unit tests
     *              without requiring a genuine DML failure.
     *
     *              Why this hook is needed:
     *              • Prevent_Segmentation_Update_When_Locked fires only when
     *                PRIORVALUE(Segmentation_Lock_Date__c) is in the current year.
     *                Those same accounts are caught by isSegmentationLocked() and
     *                routed to totalLocked before processAccountsWithResult() is
     *                ever called — making it architecturally impossible to trigger
     *                the rule for an account that reaches the error path.
     *              • Phone_Format fires on every DML save, including the test
     *                setup DML, so an invalid phone cannot be persisted to the DB.
     *
     *              Because the class implements Database.Stateful, injected state
     *              survives serialisation and is visible inside finish().
     */
    @TestVisible
    private void addTestError(Account acc, String errorMsg) {
        failedAccounts.add(acc);
        errorMessages.add(
            'Account: ' + acc.Name + ' (Id: ' + acc.Id + ') - ' + errorMsg
        );
    }

    // =========================================================================
    // SCHEDULABLE INTERFACE
    // =========================================================================

    /**
     * @description Schedulable entry point. Fires the batch with a chunk size of 200
     *              on the configured schedule (1 Jan each year at 03:00 AM).
     *              Cron: '0 0 3 1 1 ? *'
     * @param       sc  SchedulableContext provided by the platform.
     */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new AccountSegmentationBatch(), 200);
    }

    // =========================================================================
    // BATCHABLE INTERFACE
    // =========================================================================

    /** @description Builds the query locator used to iterate over accounts. */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        String baseQuery =
            'SELECT Id, Name, RecordType.Name, Client_Type__c, ' +
            '       Stated_Net_Worth__c, Stated_HH_Income__c, Billed_AUM__c, ' +
            '       Segmentation_Score__c, Segmentation__c, Segmentation_Lock_Date__c ' +
            'FROM   Account';


        List<String> filters = new List<String>();
        filters.add('Segmentation__c != null');
        filters.add('Stated_Net_Worth__c != null');
        filters.add('Stated_HH_Income__c != null');
        filters.add('Billed_AUM__c != null');
        filters.add('Client_Type__c = \'Wealth Management\'');

        if (targetAccountIds != null && !targetAccountIds.isEmpty()) {
            // Convert Set<Id> to a quoted comma-separated string for dynamic SOQL
            List<String> idStrings = new List<String>();
            for (Id accId : targetAccountIds) {
                idStrings.add('\'' + String.valueOf(accId) + '\'');
            }
            filters.add('Id IN (' + String.join(idStrings, ',') + ')');
        }

        if (String.isNotBlank(additionalFilter)) {
            filters.add('(' + additionalFilter + ')');
        }

        if (!filters.isEmpty()) {
            baseQuery += ' WHERE ' + String.join(filters, ' AND ');
        }

        return Database.getQueryLocator(baseQuery);
    }

    /**
     * @description Processes each chunk of Account records.
     *              Delegates all scoring/segmentation logic to AccountService.
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Account> accounts = (List<Account>) scope;
        totalProcessed += accounts.size();

        // Separate locked vs. unlocked records for tracking purposes
        List<Account> eligible = new List<Account>();
        for (Account acc : accounts) {
            if (AccountService.isSegmentationLocked(acc)) {
                totalLocked++;
            } else {
                eligible.add(acc);
            }
        }

        if (!eligible.isEmpty()) {
            // Pass true → sets Quad_Meeting_Creation_Pending__c = true after segmentation
            // so the annual Quad Meeting creation job can identify records to process.
            Map<Id, String> errorMap = AccountService.processAccountsWithResult(eligible, true);
            List<Error_Log__c> errorLogs = new List<Error_Log__c>();
            for (Account acc : eligible) {
                if (errorMap.containsKey(acc.Id)) {
                    failedAccounts.add(acc);
                    String errMsg = 'Account: ' + acc.Name + ' (Id: ' + acc.Id + ') - ' + errorMap.get(acc.Id);
                    errorMessages.add(errMsg);
                    errorLogs.add(ErrorLogService.buildLog(
                        'AccountSegmentationBatch', 'execute',
                        'Segmentation failed for Account ' + acc.Name + ' (Id: ' + acc.Id + '): ' + errorMap.get(acc.Id),
                        null, ErrorLogService.SEVERITY_ERROR, ErrorLogService.TYPE_BATCH
                    ));
                } else {
                    totalUpdated++;
                }
            }
            ErrorLogService.insertLogs(errorLogs);
        }
    }

    /**
     * @description Called when all chunks are done.  Logs a summary.
     */
    public void finish(Database.BatchableContext bc) {
        ErrorLogService.logInfo('AccountSegmentationBatch', 'finish',
            'AccountSegmentationBatch complete. Processed: ' + totalProcessed +
            ' | Updated: ' + totalUpdated +
            ' | Locked (skipped): ' + totalLocked +
            ' | Failed: ' + failedAccounts.size());

        // Send summary email if there are failures
        if (!failedAccounts.isEmpty()) {
            // Recipients are stored in Custom Label: AccountSegmentationBatch_ErrorEmailRecipients
            // Multiple addresses can be comma-separated in the label value.
            List<String> recipients = Label.AccountSegmentationBatch_ErrorEmailRecipients.split(',');
            String subject = 'Account Segmentation Batch: Errors Detected';
            String body = 'The following Accounts failed segmentation re-evaluation:\n\n';
            for (String msg : errorMessages) {
                body += msg + '\n';
            }
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(recipients);
            mail.setSubject(subject);
            mail.setPlainTextBody(body);
            try {
                Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{mail});
            } catch (Exception ex) {
                ErrorLogService.logError('AccountSegmentationBatch', 'finish',
                    'Failed to send error summary email. Failed records: ' + failedAccounts.size(), ex);
            }
        }
    }
}