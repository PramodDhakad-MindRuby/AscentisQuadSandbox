/**
 * @class       QuadMeetingCreationBatch
 * @description Schedulable Batch class responsible for creating annual Quad Meeting
 *              records for qualifying Accounts by delegating to
 *              QuadMeetingService.createAnnualQuadMeetings().
 *
 *              Query Criteria (OR logic):
 *                - Client_Type__c = 'Wealth Management'
 *                - Quad_Meeting_Creation_Pending__c = true
 *
 *              Intended Execution:
 *                - Scheduled on January 1st each year via the Salesforce Scheduler.
 *                - Can also be triggered ad-hoc for accounts flagged as pending.
 *
 *              Scheduling (Anonymous Apex):
 *                // Every Jan 1st at midnight:
 *                System.schedule(
 *                    'Quad Meeting Creation Batch 2027',
 *                    '0 0 0 1 1 ? 2027',
 *                    new QuadMeetingCreationBatch()
 *                );
 *
 * @author      Mindruby Team
 * @date        2026-05-07
 */
public with sharing class QuadMeetingCreationBatch
    implements Database.Batchable<SObject>, Schedulable {

    // =========================================================================
    // SCHEDULABLE INTERFACE
    // =========================================================================

    /**
     * @description Schedulable entry point.
     *              Allows this class to be registered via System.schedule().
     */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new QuadMeetingCreationBatch(), 200);
    }

    // =========================================================================
    // BATCHABLE INTERFACE
    // =========================================================================

    /**
     * @description Defines the query scope for the batch.
     *              Fetches Accounts where:
     *                - Client_Type__c = 'Wealth Management'  OR
     *                - Quad_Meeting_Creation_Pending__c = true
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id
            FROM   Account
            WHERE  Client_Type__c = 'Wealth Management'
            OR     Quad_Meeting_Creation_Pending__c = true
        ]);
    }

    /**
     * @description Processes each batch chunk.
     *              Collects Account Ids and passes them to QuadMeetingService
     *              for Quad Meeting creation and post-creation Account field updates.
     *
     * @param bc     Batch context provided by the platform.
     * @param scope  List of Account records in the current chunk.
     */
    public void execute(Database.BatchableContext bc, List<Account> scope) {
        if (scope == null || scope.isEmpty()) return;

        Set<Id> accountIds = new Set<Id>();
        for (Account acc : scope) {
            accountIds.add(acc.Id);
        }

        try {
            QuadMeetingService.createAnnualQuadMeetings(accountIds);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                'QuadMeetingCreationBatch.execute - Unexpected error. ' +
                'Batch Job Id: ' + bc.getJobId() +
                ' | Error: '     + ex.getMessage() +
                ' | Stack: '     + ex.getStackTraceString()
            );
        }
    }

    /**
     * @description Called after all batch chunks complete.
     *              Logs a summary of the batch job outcome.
     *
     * @param bc  Batch context provided by the platform.
     */
    public void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [
            SELECT Id, Status, NumberOfErrors, TotalJobItems, CreatedDate
            FROM   AsyncApexJob
            WHERE  Id = :bc.getJobId()
        ];

        System.debug(LoggingLevel.INFO,
            'QuadMeetingCreationBatch.finish - ' +
            'Status: '          + job.Status          +
            ' | Total Chunks: ' + job.TotalJobItems    +
            ' | Errors: '       + job.NumberOfErrors   +
            ' | Started: '      + job.CreatedDate
        );
    }
}