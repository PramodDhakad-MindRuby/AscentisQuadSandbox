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
 *
 * @author      Mindruby Team
 * @date        2026-04-21
 */
public with sharing class AccountSegmentationBatch
    implements Database.Batchable<SObject>, Database.Stateful {

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
            for (Account acc : eligible) {
                if (errorMap.containsKey(acc.Id)) {
                    failedAccounts.add(acc);
                    errorMessages.add('Account: ' + acc.Name + ' (Id: ' + acc.Id + ') - ' + errorMap.get(acc.Id));
                } else {
                    totalUpdated++;
                }
            }
        }
    }

    /**
     * @description Called when all chunks are done.  Logs a summary.
     */
    public void finish(Database.BatchableContext bc) {
        System.debug(
            LoggingLevel.INFO,
            'AccountSegmentationBatch complete. ' +
            'Processed: ' + totalProcessed + ' | ' +
            'Updated: '   + totalUpdated   + ' | ' +
            'Locked (skipped): ' + totalLocked
        );

        // Send summary email if there are failures
        if (!failedAccounts.isEmpty()) {
            // TODO: Replace with dynamic recipient list from Custom Setting/Metadata
            List<String> recipients = new List<String>{'setul.sahu@ascentisholdings.com'};
            String subject = 'Account Segmentation Batch: Errors Detected';
            String body = 'The following Accounts failed segmentation re-evaluation:\n\n';
            for (String msg : errorMessages) {
                body += msg + '\n';
            }
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(recipients);
            mail.setSubject(subject);
            mail.setPlainTextBody(body);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{mail});
        }
    }
}