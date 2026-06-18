/**
 * @class       QuadMeetingArchiveBatch
 * @description Schedulable Batch class that runs daily and archives Quad Meeting
 *              records whose Expiration_Date__c was yesterday (i.e., the period
 *              has just closed).
 *
 *              Archival logic is fully delegated to
 *              QuadMeetingService.archiveExpiredMeetings(), keeping this class
 *              focused solely on scoping and orchestration.
 *
 *              Per-record updates applied via the service method:
 *                - Meeting_Status__c    → 'Archived'
 *                - IncompleteReason__c  → 'Updated by Automation'
 *
 *              Excluded records (NOT archived):
 *                - Meetings already in status 'Archived' are excluded from the
 *                  query to avoid unnecessary DML.
 *
 *              Scheduling (run once via Anonymous Apex, then self-schedules):
 *                // Schedule to run every day at 1:00 AM:
 *                System.schedule(
 *                    'Quad Meeting Archive Batch - Daily',
 *                    '0 0 1 * * ?',
 *                    new QuadMeetingArchiveBatch()
 *                );
 *
 * @author      Mindruby Team
 * @date        2026-05-19
 */
public with sharing class QuadMeetingArchiveBatch
    implements Database.Batchable<SObject>, Schedulable {

    // =========================================================================
    // SCHEDULABLE INTERFACE
    // =========================================================================

    /**
     * @description Schedulable entry point.
     *              Fires the batch with a chunk size of 200 records per execution.
     *
     * @param sc  Schedulable context provided by the platform.
     */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new QuadMeetingArchiveBatch(), 200);
    }

    // =========================================================================
    // BATCHABLE INTERFACE
    // =========================================================================

    /**
     * @description Defines the batch scope.
     *              Selects all non-archived Quad Meeting records whose
     *              Expiration_Date__c equals yesterday (Date.today() - 1).
     *
     *              Meetings already 'Archived' are excluded to keep DML lean.
     *
     * @param bc  Batch context provided by the platform.
     * @return    QueryLocator over the expired, non-archived Quad Meetings.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        Date yesterday = Date.today().addDays(-1);

        return Database.getQueryLocator([
            SELECT Id
            FROM   Quad_Meeting__c
            WHERE  Expiration_Date__c  = :yesterday
            AND    Meeting_Status__c  != 'Archived'
            AND    Expiration_Date__c != null
            AND    Meeting_Status__c != 'Complete'
        ]);
    }

    /**
     * @description Processes each batch chunk.
     *              Collects Quad Meeting Ids and delegates the archival DML to
     *              QuadMeetingService.archiveExpiredMeetings().
     *
     * @param bc     Batch context provided by the platform.
     * @param scope  List of Quad_Meeting__c records in the current chunk.
     */
    public void execute(Database.BatchableContext bc, List<Quad_Meeting__c> scope) {
        if (scope == null || scope.isEmpty()) return;

        Set<Id> meetingIds = new Set<Id>();
        for (Quad_Meeting__c meeting : scope) {
            meetingIds.add(meeting.Id);
        }

        try {
            QuadMeetingService.archiveExpiredMeetings(meetingIds);
        } catch (Exception ex) {
            ErrorLogService.logError(
                'QuadMeetingArchiveBatch', 'execute',
                'Quad Meeting archival failed for batch chunk of ' + meetingIds.size() +
                ' record(s). Batch Job Id: ' + bc.getJobId(), ex
            );
        }
    }

    /**
     * @description Called after all batch chunks complete.
     *              Logs a summary of the batch job outcome via ErrorLogService.
     *
     * @param bc  Batch context provided by the platform.
     */
    public void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [
            SELECT Id, Status, NumberOfErrors, TotalJobItems, CreatedDate
            FROM   AsyncApexJob
            WHERE  Id = :bc.getJobId()
        ];

        ErrorLogService.logInfo(
            'QuadMeetingArchiveBatch', 'finish',
            'QuadMeetingArchiveBatch complete. Status: '  + job.Status        +
            ' | Total Chunks: '                           + job.TotalJobItems +
            ' | Errors: '                                 + job.NumberOfErrors +
            ' | Started: '                                + job.CreatedDate
        );
    }
}