global without sharing class Schedule_FPOnlyHouseHoldRemainder implements Schedulable {
    global Boolean isFinalNotice = false;
    global Schedule_FPOnlyHouseHoldRemainder() {}
    global Schedule_FPOnlyHouseHoldRemainder(Boolean isFinalNotice) {
        this.isFinalNotice = isFinalNotice;
    }
    global void execute(SchedulableContext sc) {
        FPOnlyHouseholdReminderService.sendReminders(isFinalNotice);
    }
    // Helper static methods for scheduling
    public static void scheduleFirstNotice() {
        // 1 Dec every year at 9am
        String cron = '0 0 9 1 12 ? *';
        System.schedule('FPOnlyHouseholdReminder_FirstNotice', cron, new Schedule_FPOnlyHouseHoldRemainder(false));
    }
    public static void scheduleFinalNotice() {
        // 15 Dec every year at 9am
        String cron = '0 0 9 15 12 ? *';
        System.schedule('FPOnlyHouseholdReminder_FinalNotice', cron, new Schedule_FPOnlyHouseHoldRemainder(true));
    }
}