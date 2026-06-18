/**
 * @class       ErrorLogService
 * @description Centralised service for creating Error_Log__c records across the org.
 *              Provides typed, reusable methods for every severity level and supports
 *              both single-record and bulk logging patterns.
 *
 *              Severity picklist  : Error | Warning | Info
 *              Status picklist    : New | In Progress | Resolved | Ignored
 *              Error_Type picklist: Apex | Flow | Integration | Validation |
 *                                   LWC | API | Batch | Other
 *
 * Usage examples:
 *
 *   // Log an exception with full context
 *   ErrorLogService.logError('AccountService', 'processAccounts',
 *       'DML failed for ' + accounts.size() + ' Accounts', ex);
 *
 *   // Log a warning without an exception
 *   ErrorLogService.logWarning('AccountService', 'calculateSegmentation',
 *       'No benchmarks found for field type: ' + fieldType, 'Apex');
 *
 *   // Log an informational milestone
 *   ErrorLogService.logInfo('AccountSegmentationBatch', 'finish',
 *       'Batch complete. Processed: ' + total);
 *
 *   // Bulk log – collect entries across a loop then insert once
 *   List<Error_Log__c> logs = new List<Error_Log__c>();
 *   logs.add(ErrorLogService.buildLog('AccountService', 'processAccounts',
 *       'Failed for Account ' + acc.Id, ex, 'Error', 'Apex'));
 *   ErrorLogService.insertLogs(logs);
 *
 * @author      Mindruby Team
 * @date        2026-05-19
 */
public with sharing class ErrorLogService {

    // ─────────────────────────────────────────────────────────────────────────
    // Severity constants
    // ─────────────────────────────────────────────────────────────────────────
    public static final String SEVERITY_ERROR   = 'Error';
    public static final String SEVERITY_WARNING = 'Warning';
    public static final String SEVERITY_INFO    = 'Info';

    // ─────────────────────────────────────────────────────────────────────────
    // Error Type constants
    // ─────────────────────────────────────────────────────────────────────────
    public static final String TYPE_APEX        = 'Apex';
    public static final String TYPE_FLOW        = 'Flow';
    public static final String TYPE_INTEGRATION = 'Integration';
    public static final String TYPE_VALIDATION  = 'Validation';
    public static final String TYPE_LWC         = 'LWC';
    public static final String TYPE_API         = 'API';
    public static final String TYPE_BATCH       = 'Batch';
    public static final String TYPE_OTHER       = 'Other';

    // ─────────────────────────────────────────────────────────────────────────
    // Status constants
    // ─────────────────────────────────────────────────────────────────────────
    public static final String STATUS_NEW         = 'New';
    public static final String STATUS_IN_PROGRESS = 'In Progress';
    public static final String STATUS_RESOLVED    = 'Resolved';
    public static final String STATUS_IGNORED     = 'Ignored';

    // =========================================================================
    // ERROR – with exception (full stack trace captured)
    // =========================================================================

    /**
     * @description Logs an exception as an Error severity record.
     *              Error_Type__c is derived from the exception type name.
     * @param       className   Apex class where the error occurred.
     * @param       methodName  Method where the error occurred.
     * @param       message     Business-context message describing the failure.
     * @param       ex          Caught exception – stack trace extracted automatically.
     */
    public static void logError(String className, String methodName,
                                String message, Exception ex) {
        Error_Log__c log = buildLog(className, methodName, message,
                                    ex, SEVERITY_ERROR, resolveErrorType(ex));
        insertLogs(new List<Error_Log__c>{ log });
    }

    /**
     * @description Logs an exception as an Error severity record with an explicit
     *              Error_Type__c value (use the TYPE_* constants).
     * @param       className   Apex class where the error occurred.
     * @param       methodName  Method where the error occurred.
     * @param       message     Business-context message describing the failure.
     * @param       ex          Caught exception – stack trace extracted automatically.
     * @param       errorType   Explicit Error_Type__c picklist value.
     */
    public static void logError(String className, String methodName,
                                String message, Exception ex, String errorType) {
        Error_Log__c log = buildLog(className, methodName, message,
                                    ex, SEVERITY_ERROR, errorType);
        insertLogs(new List<Error_Log__c>{ log });
    }

    // =========================================================================
    // WARNING – without exception
    // =========================================================================

    /**
     * @description Logs a warning message without an associated exception.
     * @param       className   Apex class where the warning originated.
     * @param       methodName  Method where the warning originated.
     * @param       message     Descriptive warning message.
     * @param       errorType   Error_Type__c picklist value (use TYPE_* constants).
     */
    public static void logWarning(String className, String methodName,
                                  String message, String errorType) {
        Error_Log__c log = buildLog(className, methodName, message,
                                    null, SEVERITY_WARNING, errorType);
        insertLogs(new List<Error_Log__c>{ log });
    }

    // =========================================================================
    // INFO – informational milestone
    // =========================================================================

    /**
     * @description Logs an informational message (e.g. batch completion summary).
     * @param       className   Apex class originating the log entry.
     * @param       methodName  Method originating the log entry.
     * @param       message     Descriptive informational message.
     */
    public static void logInfo(String className, String methodName, String message) {
        Error_Log__c log = buildLog(className, methodName, message,
                                    null, SEVERITY_INFO, null);
        insertLogs(new List<Error_Log__c>{ log });
    }

    // =========================================================================
    // BULK INSERT
    // =========================================================================

    /**
     * @description Inserts a list of pre-built Error_Log__c records.
     *              Uses allOrNone=false so a logging failure never masks
     *              the caller's business logic.
     * @param       logs  List of Error_Log__c records to persist.
     */
    public static void insertLogs(List<Error_Log__c> logs) {
        if (logs == null || logs.isEmpty()) {
            return;
        }
        Database.insert(logs, false);
    }

    // =========================================================================
    // RECORD BUILDER – reusable factory method
    // =========================================================================

    /**
     * @description Builds (but does NOT insert) a single Error_Log__c record.
     *              Use this when collecting multiple log entries inside a loop
     *              before calling insertLogs() once at the end.
     * @param       className   Apex class name.
     * @param       methodName  Method name.
     * @param       message     Log message.
     * @param       ex          Exception (nullable – pass null for non-exception logs).
     * @param       severity    Severity__c picklist value (use SEVERITY_* constants).
     * @param       errorType   Error_Type__c picklist value (use TYPE_* constants, nullable).
     * @return      Unsaved Error_Log__c record ready for bulk insert.
     */
    public static Error_Log__c buildLog(String className, String methodName,
                                        String message, Exception ex,
                                        String severity, String errorType) {
        Error_Log__c log = new Error_Log__c(
            Class_Name__c  = className,
            Method_Name__c = methodName,
            Message__c     = message,
            Severity__c    = severity,
            Status__c      = STATUS_NEW
        );

        if (String.isNotBlank(errorType)) {
            log.Error_Type__c = errorType;
        }

        if (ex != null) {
            log.Stack_Trace__c = ex.getStackTraceString();
            // Only set Error_Type__c from exception if not already provided
            if (String.isBlank(errorType)) {
                log.Error_Type__c = resolveErrorType(ex);
            }
        }

        return log;
    }

    // =========================================================================
    // STATUS UPDATE HELPERS
    // =========================================================================

    /**
     * @description Marks a list of Error_Log__c records as Resolved.
     * @param       logIds  Set of Error_Log__c record Ids to update.
     */
    public static void markResolved(Set<Id> logIds) {
        updateStatus(logIds, STATUS_RESOLVED);
    }

    /**
     * @description Marks a list of Error_Log__c records as Ignored.
     * @param       logIds  Set of Error_Log__c record Ids to update.
     */
    public static void markIgnored(Set<Id> logIds) {
        updateStatus(logIds, STATUS_IGNORED);
    }

    /**
     * @description Marks a list of Error_Log__c records as In Progress.
     * @param       logIds  Set of Error_Log__c record Ids to update.
     */
    public static void markInProgress(Set<Id> logIds) {
        updateStatus(logIds, STATUS_IN_PROGRESS);
    }

    // =========================================================================
    // QUERY HELPERS
    // =========================================================================

    /**
     * @description Returns all unresolved Error_Log__c records for a given class.
     * @param       className  The Apex class name to filter by.
     * @return      List of Error_Log__c records with Status != 'Resolved'.
     */
    public static List<Error_Log__c> getOpenLogsByClass(String className) {
        return [
            SELECT Id, Class_Name__c, Method_Name__c, Message__c,
                   Error_Type__c, Stack_Trace__c, Severity__c, Status__c,
                   CreatedDate
            FROM   Error_Log__c
            WHERE  Class_Name__c = :className
            AND    Status__c    != :STATUS_RESOLVED
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * @description Returns Error_Log__c records filtered by severity level.
     * @param       severity  Severity__c picklist value (use SEVERITY_* constants).
     * @return      List of matching Error_Log__c records ordered by CreatedDate DESC.
     */
    public static List<Error_Log__c> getLogsBySeverity(String severity) {
        return [
            SELECT Id, Class_Name__c, Method_Name__c, Message__c,
                   Error_Type__c, Stack_Trace__c, Severity__c, Status__c,
                   CreatedDate
            FROM   Error_Log__c
            WHERE  Severity__c = :severity
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * @description Returns Error_Log__c records created within the last N days.
     * @param       days  Number of past days to include.
     * @return      List of Error_Log__c records ordered by CreatedDate DESC.
     */
    public static List<Error_Log__c> getRecentLogs(Integer days) {
        Date fromDate = Date.today().addDays(-days);
        return [
            SELECT Id, Class_Name__c, Method_Name__c, Message__c,
                   Error_Type__c, Stack_Trace__c, Severity__c, Status__c,
                   CreatedDate
            FROM   Error_Log__c
            WHERE  CreatedDate >= :fromDate
            ORDER BY CreatedDate DESC
        ];
    }

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    /**
     * @description Maps the runtime exception type to an Error_Type__c picklist value.
     *              DmlException → Apex, CalloutException → Integration, etc.
     * @param       ex  The caught exception.
     * @return      Matching Error_Type__c picklist value or 'Other' as fallback.
     */
    private static String resolveErrorType(Exception ex) {
        if (ex == null) {
            return TYPE_OTHER;
        }
        String typeName = ex.getTypeName();
        if (typeName.containsIgnoreCase('Dml') ||
            typeName.containsIgnoreCase('Soql') ||
            typeName.containsIgnoreCase('QueryException') ||
            typeName.containsIgnoreCase('Apex')) {
            return TYPE_APEX;
        }
        if (typeName.containsIgnoreCase('Callout') ||
            typeName.containsIgnoreCase('Http')) {
            return TYPE_INTEGRATION;
        }
        return TYPE_APEX; // default for unrecognised Apex exceptions
    }

    /**
     * @description Bulk-updates the Status__c field on the given log record Ids.
     * @param       logIds  Set of Error_Log__c Ids to update.
     * @param       status  New Status__c value to apply.
     */
    private static void updateStatus(Set<Id> logIds, String status) {
        if (logIds == null || logIds.isEmpty()) {
            return;
        }
        List<Error_Log__c> toUpdate = new List<Error_Log__c>();
        for (Id logId : logIds) {
            toUpdate.add(new Error_Log__c(Id = logId, Status__c = status));
        }
        Database.update(toUpdate, false);
    }
}