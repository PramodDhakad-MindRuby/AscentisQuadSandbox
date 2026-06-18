/**
 * @class       ErrorLogServiceTest
 * @description Comprehensive unit tests for ErrorLogService covering every
 *              public method:
 *
 *              Convenience loggers
 *              ─────────────────────────────────────────────────────────────
 *              • logError(className, methodName, message, ex)
 *              • logError(className, methodName, message, ex, errorType)
 *              • logWarning(className, methodName, message, errorType)
 *              • logInfo(className, methodName, message)
 *
 *              Bulk / builder helpers
 *              ─────────────────────────────────────────────────────────────
 *              • buildLog(className, methodName, message, ex, severity, errorType)
 *              • insertLogs(logs)
 *
 *              Status update helpers
 *              ─────────────────────────────────────────────────────────────
 *              • markResolved(logIds)
 *              • markIgnored(logIds)
 *              • markInProgress(logIds)
 *
 *              Query helpers
 *              ─────────────────────────────────────────────────────────────
 *              • getOpenLogsByClass(className)
 *              • getLogsBySeverity(severity)
 *              • getRecentLogs(days)
 *
 * @author      Mindruby Team
 * @date        2026-06-01
 */
@isTest
private class ErrorLogServiceTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Helper – build a real exception with a message and stack trace
    // ─────────────────────────────────────────────────────────────────────────
    private static Exception makeException(String msg) {
        try {
            throw new IllegalArgumentException(msg);
        } catch (Exception ex) {
            return ex;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper – insert a pre-built log and return its Id
    // ─────────────────────────────────────────────────────────────────────────
    private static Id seedLog(String className, String severity, String status) {
        Error_Log__c log = new Error_Log__c(
            Class_Name__c  = className,
            Method_Name__c = 'seedMethod',
            Message__c     = 'Seeded log',
            Severity__c    = severity,
            Status__c      = status,
            Error_Type__c  = ErrorLogService.TYPE_APEX
        );
        insert log;
        return log.Id;
    }

    // =========================================================================
    // logError – exception auto-type-resolution
    // =========================================================================

    @isTest
    static void testLogError_withException_createsErrorSeverityRecord() {
        Exception ex = makeException('DML exploded');

        Test.startTest();
        ErrorLogService.logError('TestClass', 'testMethod', 'Something blew up', ex);
        Test.stopTest();

        List<Error_Log__c> logs = [
            SELECT Severity__c, Class_Name__c, Method_Name__c,
                   Message__c, Stack_Trace__c, Status__c, Error_Type__c
            FROM   Error_Log__c
            WHERE  Class_Name__c = 'TestClass'
        ];
        System.assertEquals(1, logs.size(), 'Exactly one log must be created');
        Error_Log__c log = logs[0];
        System.assertEquals(ErrorLogService.SEVERITY_ERROR, log.Severity__c,
            'Severity must be Error');
        System.assertEquals('TestClass',   log.Class_Name__c,   'Class name mismatch');
        System.assertEquals('testMethod',  log.Method_Name__c,  'Method name mismatch');
        System.assertEquals('Something blew up', log.Message__c, 'Message mismatch');
        System.assertEquals(ErrorLogService.STATUS_NEW, log.Status__c, 'Status must default to New');
        System.assertNotEquals(null, log.Stack_Trace__c, 'Stack trace must be captured from exception');
        System.assertNotEquals(null, log.Error_Type__c,  'Error_Type__c must be resolved from exception');
    }

    @isTest
    static void testLogError_withDmlException_setsApexType() {
        // DmlException → resolveErrorType returns TYPE_APEX
        Exception ex = makeException('DmlException simulation');

        Test.startTest();
        ErrorLogService.logError('SvcClass', 'updateMethod', 'DML failed', ex);
        Test.stopTest();

        Error_Log__c log = [SELECT Error_Type__c FROM Error_Log__c WHERE Class_Name__c = 'SvcClass' LIMIT 1];
        System.assertEquals(ErrorLogService.TYPE_APEX, log.Error_Type__c,
            'DmlException must resolve to TYPE_APEX');
    }

    // =========================================================================
    // logError – explicit errorType overload
    // =========================================================================

    @isTest
    static void testLogError_withExplicitType_usesProvidedType() {
        Exception ex = makeException('Callout failed');

        Test.startTest();
        ErrorLogService.logError('IntClass', 'callout', 'HTTP 500', ex, ErrorLogService.TYPE_INTEGRATION);
        Test.stopTest();

        Error_Log__c log = [SELECT Error_Type__c, Severity__c FROM Error_Log__c WHERE Class_Name__c = 'IntClass' LIMIT 1];
        System.assertEquals(ErrorLogService.TYPE_INTEGRATION, log.Error_Type__c,
            'Explicitly supplied errorType must override auto-resolved type');
        System.assertEquals(ErrorLogService.SEVERITY_ERROR, log.Severity__c,
            'Severity must still be Error');
    }

    // =========================================================================
    // logWarning
    // =========================================================================

    @isTest
    static void testLogWarning_createsWarningSeverityRecord() {
        Test.startTest();
        ErrorLogService.logWarning('WarnClass', 'warnMethod', 'No benchmarks found', ErrorLogService.TYPE_APEX);
        Test.stopTest();

        List<Error_Log__c> logs = [SELECT Severity__c, Message__c, Error_Type__c, Stack_Trace__c
                                   FROM Error_Log__c WHERE Class_Name__c = 'WarnClass'];
        System.assertEquals(1, logs.size(), 'Exactly one warning log must be created');
        Error_Log__c log = logs[0];
        System.assertEquals(ErrorLogService.SEVERITY_WARNING, log.Severity__c, 'Severity must be Warning');
        System.assertEquals('No benchmarks found', log.Message__c, 'Message must match');
        System.assertEquals(ErrorLogService.TYPE_APEX, log.Error_Type__c, 'Error type must match');
        System.assertEquals(null, log.Stack_Trace__c, 'Stack trace must be null for non-exception log');
    }

    // =========================================================================
    // logInfo
    // =========================================================================

    @isTest
    static void testLogInfo_createsInfoSeverityRecord() {
        Test.startTest();
        ErrorLogService.logInfo('BatchClass', 'finish', 'Processed: 42');
        Test.stopTest();

        List<Error_Log__c> logs = [SELECT Severity__c, Message__c, Error_Type__c, Stack_Trace__c
                                   FROM Error_Log__c WHERE Class_Name__c = 'BatchClass'];
        System.assertEquals(1, logs.size(), 'Exactly one info log must be created');
        Error_Log__c log = logs[0];
        System.assertEquals(ErrorLogService.SEVERITY_INFO, log.Severity__c, 'Severity must be Info');
        System.assertEquals('Processed: 42', log.Message__c, 'Message must match');
        System.assertEquals(null, log.Error_Type__c,  'Error type must be null for info log');
        System.assertEquals(null, log.Stack_Trace__c, 'Stack trace must be null for info log');
    }

    // =========================================================================
    // buildLog – factory method
    // =========================================================================

    @isTest
    static void testBuildLog_withException_populatesAllFields() {
        Exception ex = makeException('Score calc failed');

        Test.startTest();
        Error_Log__c log = ErrorLogService.buildLog(
            'AccountService', 'calculateSegmentation',
            'Score calc failed for Account 001xx',
            ex, ErrorLogService.SEVERITY_ERROR, ErrorLogService.TYPE_APEX
        );
        Test.stopTest();

        // buildLog must NOT insert – verify no records exist yet
        System.assertEquals(0, [SELECT COUNT() FROM Error_Log__c], 'buildLog must not insert the record');

        System.assertEquals('AccountService',  log.Class_Name__c,  'Class name mismatch');
        System.assertEquals('calculateSegmentation', log.Method_Name__c, 'Method name mismatch');
        System.assertEquals('Score calc failed for Account 001xx', log.Message__c, 'Message mismatch');
        System.assertEquals(ErrorLogService.SEVERITY_ERROR, log.Severity__c, 'Severity mismatch');
        System.assertEquals(ErrorLogService.TYPE_APEX,      log.Error_Type__c, 'Error type mismatch');
        System.assertEquals(ErrorLogService.STATUS_NEW,     log.Status__c,     'Status must default to New');
        System.assertNotEquals(null, log.Stack_Trace__c, 'Stack trace must be set from exception');
    }

    @isTest
    static void testBuildLog_withNullException_leaveStackTraceBlank() {
        Test.startTest();
        Error_Log__c log = ErrorLogService.buildLog(
            'FlowHandler', 'run', 'Flow skipped record', null,
            ErrorLogService.SEVERITY_WARNING, ErrorLogService.TYPE_FLOW
        );
        Test.stopTest();

        System.assertEquals(null, log.Stack_Trace__c, 'Stack trace must be null when no exception is supplied');
        System.assertEquals(ErrorLogService.TYPE_FLOW, log.Error_Type__c, 'Error type must be set from parameter');
    }

    @isTest
    static void testBuildLog_withNullErrorType_doesNotSetField() {
        Test.startTest();
        Error_Log__c log = ErrorLogService.buildLog(
            'InfoClass', 'doWork', 'Milestone reached', null,
            ErrorLogService.SEVERITY_INFO, null
        );
        Test.stopTest();

        System.assertEquals(null, log.Error_Type__c, 'Error_Type__c must be null when null is passed');
    }

    @isTest
    static void testBuildLog_withNullExceptionAndBlankType_autoResolvesNullType() {
        // When ex=null and errorType=blank, resolveErrorType(null) = TYPE_OTHER
        // but buildLog only calls resolveErrorType when ex != null.
        // So Error_Type__c must remain null (not set at all).
        Test.startTest();
        Error_Log__c log = ErrorLogService.buildLog(
            'OtherClass', 'run', 'msg', null,
            ErrorLogService.SEVERITY_INFO, ''
        );
        Test.stopTest();

        System.assertEquals(null, log.Error_Type__c,
            'Blank errorType with null exception must leave Error_Type__c unset');
    }

    // =========================================================================
    // insertLogs – bulk insert
    // =========================================================================

    @isTest
    static void testInsertLogs_bulkInsertsPersistAllRecords() {
        List<Error_Log__c> logs = new List<Error_Log__c>();
        for (Integer i = 0; i < 5; i++) {
            logs.add(ErrorLogService.buildLog(
                'BulkClass', 'loop',
                'Bulk log ' + i, null,
                ErrorLogService.SEVERITY_ERROR, ErrorLogService.TYPE_BATCH
            ));
        }

        Test.startTest();
        ErrorLogService.insertLogs(logs);
        Test.stopTest();

        System.assertEquals(5, [SELECT COUNT() FROM Error_Log__c WHERE Class_Name__c = 'BulkClass'],
            'All 5 bulk log records must be inserted');
    }

    @isTest
    static void testInsertLogs_withNullList_doesNotThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            ErrorLogService.insertLogs(null);
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'insertLogs(null) must not throw');
        System.assertEquals(0, [SELECT COUNT() FROM Error_Log__c], 'No records must be inserted');
    }

    @isTest
    static void testInsertLogs_withEmptyList_doesNotThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            ErrorLogService.insertLogs(new List<Error_Log__c>());
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'insertLogs([]) must not throw');
        System.assertEquals(0, [SELECT COUNT() FROM Error_Log__c], 'No records must be inserted');
    }

    // =========================================================================
    // markResolved
    // =========================================================================

    @isTest
    static void testMarkResolved_updatesStatusToResolved() {
        Id logId = seedLog('ResolveClass', ErrorLogService.SEVERITY_ERROR, ErrorLogService.STATUS_NEW);

        Test.startTest();
        ErrorLogService.markResolved(new Set<Id>{ logId });
        Test.stopTest();

        Error_Log__c log = [SELECT Status__c FROM Error_Log__c WHERE Id = :logId];
        System.assertEquals(ErrorLogService.STATUS_RESOLVED, log.Status__c,
            'Status must be updated to Resolved');
    }

    @isTest
    static void testMarkResolved_withNullSet_doesNotThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            ErrorLogService.markResolved(null);
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'markResolved(null) must not throw');
    }

    @isTest
    static void testMarkResolved_withEmptySet_doesNotThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            ErrorLogService.markResolved(new Set<Id>());
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'markResolved(empty) must not throw');
    }

    // =========================================================================
    // markIgnored
    // =========================================================================

    @isTest
    static void testMarkIgnored_updatesStatusToIgnored() {
        Id logId = seedLog('IgnoreClass', ErrorLogService.SEVERITY_WARNING, ErrorLogService.STATUS_NEW);

        Test.startTest();
        ErrorLogService.markIgnored(new Set<Id>{ logId });
        Test.stopTest();

        Error_Log__c log = [SELECT Status__c FROM Error_Log__c WHERE Id = :logId];
        System.assertEquals(ErrorLogService.STATUS_IGNORED, log.Status__c,
            'Status must be updated to Ignored');
    }

    @isTest
    static void testMarkIgnored_withNullSet_doesNotThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            ErrorLogService.markIgnored(null);
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'markIgnored(null) must not throw');
    }

    // =========================================================================
    // markInProgress
    // =========================================================================

    @isTest
    static void testMarkInProgress_updatesStatusToInProgress() {
        Id logId = seedLog('WIPClass', ErrorLogService.SEVERITY_ERROR, ErrorLogService.STATUS_NEW);

        Test.startTest();
        ErrorLogService.markInProgress(new Set<Id>{ logId });
        Test.stopTest();

        Error_Log__c log = [SELECT Status__c FROM Error_Log__c WHERE Id = :logId];
        System.assertEquals(ErrorLogService.STATUS_IN_PROGRESS, log.Status__c,
            'Status must be updated to In Progress');
    }

    @isTest
    static void testMarkInProgress_withNullSet_doesNotThrow() {
        Boolean threw = false;
        Test.startTest();
        try {
            ErrorLogService.markInProgress(null);
        } catch (Exception ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'markInProgress(null) must not throw');
    }

    // =========================================================================
    // getOpenLogsByClass
    // =========================================================================

    @isTest
    static void testGetOpenLogsByClass_returnsOnlyOpenLogsForClass() {
        // One open log, one resolved log for the target class, one open for another class
        seedLog('TargetClass', ErrorLogService.SEVERITY_ERROR, ErrorLogService.STATUS_NEW);
        Id resolvedId = seedLog('TargetClass', ErrorLogService.SEVERITY_WARNING, ErrorLogService.STATUS_NEW);
        seedLog('OtherClass',  ErrorLogService.SEVERITY_ERROR, ErrorLogService.STATUS_NEW);
        ErrorLogService.markResolved(new Set<Id>{ resolvedId });

        Test.startTest();
        List<Error_Log__c> results = ErrorLogService.getOpenLogsByClass('TargetClass');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Only the one non-resolved TargetClass log must be returned');
        System.assertNotEquals(ErrorLogService.STATUS_RESOLVED, results[0].Status__c,
            'Resolved log must be excluded');
    }

    @isTest
    static void testGetOpenLogsByClass_noLogs_returnsEmptyList() {
        Test.startTest();
        List<Error_Log__c> results = ErrorLogService.getOpenLogsByClass('NoSuchClass');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty list must be returned when no logs exist');
    }

    // =========================================================================
    // getLogsBySeverity
    // =========================================================================

    @isTest
    static void testGetLogsBySeverity_returnsOnlyMatchingSeverity() {
        seedLog('SevClass', ErrorLogService.SEVERITY_ERROR,   ErrorLogService.STATUS_NEW);
        seedLog('SevClass', ErrorLogService.SEVERITY_ERROR,   ErrorLogService.STATUS_NEW);
        seedLog('SevClass', ErrorLogService.SEVERITY_WARNING, ErrorLogService.STATUS_NEW);

        Test.startTest();
        List<Error_Log__c> errors   = ErrorLogService.getLogsBySeverity(ErrorLogService.SEVERITY_ERROR);
        List<Error_Log__c> warnings = ErrorLogService.getLogsBySeverity(ErrorLogService.SEVERITY_WARNING);
        List<Error_Log__c> infos    = ErrorLogService.getLogsBySeverity(ErrorLogService.SEVERITY_INFO);
        Test.stopTest();

        System.assertEquals(2, errors.size(),   '2 Error-severity logs must be returned');
        System.assertEquals(1, warnings.size(),  '1 Warning-severity log must be returned');
        System.assertEquals(0, infos.size(),     'No Info-severity logs must be returned');
    }

    // =========================================================================
    // getRecentLogs
    // =========================================================================

    @isTest
    static void testGetRecentLogs_returnsLogsCreatedToday() {
        seedLog('RecentClass', ErrorLogService.SEVERITY_INFO, ErrorLogService.STATUS_NEW);
        seedLog('RecentClass', ErrorLogService.SEVERITY_ERROR, ErrorLogService.STATUS_NEW);

        Test.startTest();
        List<Error_Log__c> results = ErrorLogService.getRecentLogs(1);
        Test.stopTest();

        System.assertEquals(2, results.size(),
            'Both logs created within the last 1 day must be returned');
    }

    @isTest
    static void testGetRecentLogs_zeroDays_returnsLogsFromToday() {
        seedLog('TodayClass', ErrorLogService.SEVERITY_INFO, ErrorLogService.STATUS_NEW);

        Test.startTest();
        List<Error_Log__c> results = ErrorLogService.getRecentLogs(0);
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Log created today must be returned when days=0');
    }

    // =========================================================================
    // Constants – quick smoke test to guard against accidental value changes
    // =========================================================================

    @isTest
    static void testConstants_haveExpectedValues() {
        System.assertEquals('Error',       ErrorLogService.SEVERITY_ERROR);
        System.assertEquals('Warning',     ErrorLogService.SEVERITY_WARNING);
        System.assertEquals('Info',        ErrorLogService.SEVERITY_INFO);

        System.assertEquals('Apex',        ErrorLogService.TYPE_APEX);
        System.assertEquals('Flow',        ErrorLogService.TYPE_FLOW);
        System.assertEquals('Integration', ErrorLogService.TYPE_INTEGRATION);
        System.assertEquals('Validation',  ErrorLogService.TYPE_VALIDATION);
        System.assertEquals('LWC',         ErrorLogService.TYPE_LWC);
        System.assertEquals('API',         ErrorLogService.TYPE_API);
        System.assertEquals('Batch',       ErrorLogService.TYPE_BATCH);
        System.assertEquals('Other',       ErrorLogService.TYPE_OTHER);

        System.assertEquals('New',         ErrorLogService.STATUS_NEW);
        System.assertEquals('In Progress', ErrorLogService.STATUS_IN_PROGRESS);
        System.assertEquals('Resolved',    ErrorLogService.STATUS_RESOLVED);
        System.assertEquals('Ignored',     ErrorLogService.STATUS_IGNORED);
    }
}