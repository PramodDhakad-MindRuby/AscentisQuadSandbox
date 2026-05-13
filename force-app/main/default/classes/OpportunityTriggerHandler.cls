/**
 * @class       OpportunityTriggerHandler
 * @description Handles Opportunity trigger events and delegates logic
 *              to dedicated helper classes per trigger context.
 *
 * @author      Mindruby Team
 * @date        2026-04-21
 */
public with sharing class OpportunityTriggerHandler {

    // =========================================================================
    // TRIGGER CONTEXT METHODS
    // =========================================================================

    /**
     * @description Called from the trigger's afterUpdate context.
     *              Detects Opportunities that have just transitioned to
     *              'Closed Won' and delegates segmentation logic to
     *              OpportunityTriggerHelperAfterUpdate.
     *
     * @param newList  Trigger.new  – updated Opportunity records.
     * @param oldMap   Trigger.oldMap – previous state of each Opportunity.
     */
    public static void afterUpdate(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        // Delegate Closed Won → Account Segmentation logic to the helper
        OpportunityTriggerHelperAfterUpdate.handleAfterUpdate(newList, oldMap);
    }
}