/**
 * @class       Schedule_FPOnlyHouseHoldRemainderTest
 * @description Tests for the schedulable FP Only reminder wrapper.
 *              The class is a thin delegate over FPOnlyHouseholdReminderService,
 *              so these tests focus on the scheduler plumbing and the delegate
 *              entry point not throwing in test context.
 *
 * @author      Mindruby Team
 * @date        2026-06-02
 */
@isTest
private class Schedule_FPOnlyHouseHoldRemainderTest {

    @isTest
    static void testExecute_firstNotice_doesNotThrow() {
        Test.startTest();
        new Schedule_FPOnlyHouseHoldRemainder(false).execute(null);
        Test.stopTest();

        System.assert(true, 'First notice execute path should complete without throwing');
    }

    @isTest
    static void testExecute_finalNotice_doesNotThrow() {
        Test.startTest();
        new Schedule_FPOnlyHouseHoldRemainder(true).execute(null);
        Test.stopTest();

        System.assert(true, 'Final notice execute path should complete without throwing');
    }

    @isTest
    static void testScheduleFirstNotice_registersExpectedCron() {
        Test.startTest();
        Schedule_FPOnlyHouseHoldRemainder.scheduleFirstNotice();
        Test.stopTest();

        CronTrigger job = [
            SELECT CronExpression, CronJobDetail.Name, TimesTriggered, State
            FROM   CronTrigger
            WHERE  CronJobDetail.Name = 'FPOnlyHouseholdReminder_FirstNotice'
            LIMIT  1
        ];

        System.assertEquals('0 0 9 1 12 ? *', job.CronExpression,
            'First notice must be scheduled for 1 Dec at 9 AM every year');
        System.assertEquals('FPOnlyHouseholdReminder_FirstNotice', job.CronJobDetail.Name,
            'Scheduled job name must match the helper method');
        System.assertEquals(0, job.TimesTriggered,
            'Newly scheduled jobs must not have run yet');
    }

    @isTest
    static void testScheduleFinalNotice_registersExpectedCron() {
        Test.startTest();
        Schedule_FPOnlyHouseHoldRemainder.scheduleFinalNotice();
        Test.stopTest();

        CronTrigger job = [
            SELECT CronExpression, CronJobDetail.Name, TimesTriggered, State
            FROM   CronTrigger
            WHERE  CronJobDetail.Name = 'FPOnlyHouseholdReminder_FinalNotice'
            LIMIT  1
        ];

        System.assertEquals('0 0 9 15 12 ? *', job.CronExpression,
            'Final notice must be scheduled for 15 Dec at 9 AM every year');
        System.assertEquals('FPOnlyHouseholdReminder_FinalNotice', job.CronJobDetail.Name,
            'Scheduled job name must match the helper method');
        System.assertEquals(0, job.TimesTriggered,
            'Newly scheduled jobs must not have run yet');
    }
}