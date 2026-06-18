public without sharing class GuestRecordUpdater implements System.Callable {
    
    public Object call(String action, Map<String, Object> args) {
        Map<String, Object> input = (Map<String, Object>)args.get('input');
        Map<String, Object> output = (Map<String, Object>)args.get('output');
        
        // 1. The OmniScript tells the class which method to run!
        if (action == 'updateQuadMeeting') {
            return updateQuadMeeting(input, output);
        } else if (action == 'updateEstatePlanning') {
            return updateEstatePlanning(input, output); 
        }
        return false;
    }

    // --- YOUR EXISTING METHOD (Updated for OmniScript Routing) ---
    private Boolean updateQuadMeeting(Map<String, Object> input, Map<String, Object> output) {
        try {
            String recordIdStr = (String)input.get('RecordId');
            String c1 = (String)input.get('C1');
            String c2 = (String)input.get('C2');
            String c3 = (String)input.get('C3');

            if (String.isBlank(recordIdStr)) {
                output.put('error', 'RecordId parameter missing');
                output.put('errorCode', 'INVOKE-500'); // ADDED THIS
                return false;
            }

            Quad_Meeting_Update_Event__e updateEvent = new Quad_Meeting_Update_Event__e(
                RecordId__c = recordIdStr,
                C1__c = c1,
                C2__c = c2,
                C3__c = c3
            );

            Database.SaveResult sr = EventBus.publish(updateEvent);
            
            // ADDED THIS: Check if the event published successfully
            if (sr.isSuccess()) {
                output.put('error', 'OK');
                output.put('errorCode', 'INVOKE-200');
                return true;
            } else {
                // If the event failed to publish, grab the exact error
                output.put('error', sr.getErrors()[0].getMessage());
                output.put('errorCode', 'INVOKE-500');
                return false;
            }
            
        } catch (Exception e) {
            output.put('error', e.getMessage());
            output.put('errorCode', 'INVOKE-500'); // ADDED THIS
            return false;
        }
    }

    // --- YOUR NEW METHOD (Updated for OmniScript Routing) ---
    private Boolean updateEstatePlanning(Map<String, Object> input, Map<String, Object> output) {
        try {
            String recordIdStr = (String)input.get('RecordId');
            
            // 1. Grab the raw text from the OmniScript Radio Buttons
            String ep1Text = String.valueOf(input.get('EP1'));
            String ep3Text = String.valueOf(input.get('EP3'));
            
            // 2. THE TRANSLATOR: If the text says 'Yes', make the checkbox True. Otherwise, False.
            Boolean ep1 = (ep1Text == 'Yes'); 
            String  ep2 = (String)input.get('EP2'); 
            Boolean ep3 = (ep3Text == 'Yes');

            if (String.isBlank(recordIdStr)) {
                output.put('error', 'RecordId parameter missing');
                output.put('errorCode', 'INVOKE-500'); // ADDED THIS
                return false;
            }

            // 3. Publish to the Platform Event
            Quad_Meeting_Update_Event__e updateEvent = new Quad_Meeting_Update_Event__e(
                RecordId__c = recordIdStr,
                EP_01__c = ep1,  
                EP_02__c = ep2,    
                EP_03__c = ep3   
            );

            Database.SaveResult sr = EventBus.publish(updateEvent);
            
            // ADDED THIS: Explicit mapping for your IP logic
            if (sr.isSuccess()) {
                output.put('error', 'OK');
                output.put('errorCode', 'INVOKE-200');
                output.put('success', true);
                return true;
            } else {
                output.put('error', sr.getErrors()[0].getMessage());
                output.put('errorCode', 'INVOKE-500');
                output.put('success', false);
                return false;
            }
            
        } catch (Exception e) {
            output.put('error', e.getMessage());
            output.put('errorCode', 'INVOKE-500'); // ADDED THIS
            return false;
        }
    }

    // --- NEW METHOD: SILENT FILE CLEANUP (Unchanged) ---
    @AuraEnabled
    public static void deleteExtraFiles(List<String> documentIds) {
        try {
            // 1. Convert the list of IDs into a comma-separated text string
            String idsString = String.join(documentIds, ',');

            // 2. Publish to the Platform Event to bypass Guest User restrictions!
            Quad_Meeting_Update_Event__e deleteEvent = new Quad_Meeting_Update_Event__e(
                Files_To_Delete__c = idsString
            );
            
            EventBus.publish(deleteEvent);  
            
        } catch (Exception e) {
            System.debug('Error publishing delete event: ' + e.getMessage());
        }
    }
}