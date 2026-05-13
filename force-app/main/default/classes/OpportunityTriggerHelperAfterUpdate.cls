/**
 * @class       OpportunityTriggerHelperAfterUpdate
 * @description Contains all After Update logic for the Opportunity trigger.
 *              On AFTER UPDATE: when an Opportunity transitions to 'Client Activated',
 *              - For 'Wealth Management': recalculates Account segmentation then creates Quad Meeting.
 *              - For 'FP Only': directly creates Quad Meeting (segmentation set manually).
 *
 * @author      Mindruby Team
 * @date        2026-04-21
 */
public with sharing class OpportunityTriggerHelperAfterUpdate {

    // =========================================================================
    // ENTRY POINT
    // =========================================================================

    public static void handleAfterUpdate(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {

        Set<Id> wealthManagementAccountIds = new Set<Id>();
        Set<Id> fpOnlyAccountIds           = new Set<Id>();

        Map<Id, Account> accountMap = getAccountMap(newList);

        for (Opportunity opp : newList) {
            Opportunity oldOpp = oldMap.get(opp.Id);

            Boolean isNowClientActivated  = opp.StageName == 'Client Activated';
            Boolean wasNotClientActivated = oldOpp.StageName != 'Client Activated';
            Boolean hasAccount            = opp.AccountId != null;

            if (!isNowClientActivated || !wasNotClientActivated || !hasAccount) continue;

            Account acc = accountMap.get(opp.AccountId);
            if (acc == null) continue;

            if (acc.Client_Type__c == 'Wealth Management') {
                wealthManagementAccountIds.add(opp.AccountId);
            } else if (acc.Client_Type__c == 'FP Only') {
                fpOnlyAccountIds.add(opp.AccountId);
            }
        }

        // Process Wealth Management: recalculate segmentation then create Quad Meetings
        // Pass false → Quad_Meeting_Creation_Pending__c is NOT set here because
        // Quad Meetings are created immediately after via QuadMeetingService.
        if (!wealthManagementAccountIds.isEmpty()) {
            AccountService.processAccounts(wealthManagementAccountIds, false);
            QuadMeetingService.createMidYearQuadMeetings(wealthManagementAccountIds);
        }

        // Process FP Only: directly create Quad Meetings (no segmentation recalculation)
        if (!fpOnlyAccountIds.isEmpty()) {
            QuadMeetingService.createMidYearQuadMeetings(fpOnlyAccountIds);
        }
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    /**
     * @description Queries and returns a map of Accounts for the given Opportunities.
     */
    @TestVisible
    private static Map<Id, Account> getAccountMap(List<Opportunity> opportunities) {
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opportunities) {
            if (opp.AccountId != null) accountIds.add(opp.AccountId);
        }

        Map<Id, Account> accountMap = new Map<Id, Account>();
        if (!accountIds.isEmpty()) {
            for (Account acc : [
                SELECT Id, Client_Type__c
                FROM   Account
                WHERE  Id IN :accountIds
            ]) {
                accountMap.put(acc.Id, acc);
            }
        }
        return accountMap;
    }
}