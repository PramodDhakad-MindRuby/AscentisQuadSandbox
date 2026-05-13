@IsTest
public class IPPDocumentTaskHelperTest {

    @IsTest
    static void testIPPAndCMADocumentLogic() {

        // -----------------------------
        // 1️ Create test user (CSR)
        // -----------------------------
        User csrUser = [SELECT Id FROM User WHERE IsActive = TRUE LIMIT 1];

        // -----------------------------
        // 2️ Create test Opportunity
        // -----------------------------
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            CRS__c = csrUser.Id
        );
        insert opp;

        // -----------------------------
        //️⃣ Create IPP_CMA_Form__c record
        // -----------------------------
        IPP_CMA_Form__c ippForm = new IPP_CMA_Form__c(
            Opportunity__c = opp.Id
        );
        insert ippForm;

        // -----------------------------
        // 4️ Create ContentDocument records
        // -----------------------------
        ContentVersion cv1 = new ContentVersion(
            Title = 'IPP Signed Document',
            PathOnClient = 'IPP_File.pdf',
            VersionData = Blob.valueOf('Test file content')
        );
        insert cv1;

        ContentVersion cv2 = new ContentVersion(
            Title = 'CMA Signed Document',
            PathOnClient = 'CMA_File.pdf',
            VersionData = Blob.valueOf('Test CMA content')
        );
        insert cv2;

        // Get ContentDocument Ids
        Id ippDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv1.Id].ContentDocumentId;
        Id cmaDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv2.Id].ContentDocumentId;

        // -----------------------------
        // ️⃣ Create ContentDocumentLink records
        // -----------------------------
        List<ContentDocumentLink> links = new List<ContentDocumentLink>{
            new ContentDocumentLink(
                ContentDocumentId = ippDocId,
                LinkedEntityId = ippForm.Id,
                ShareType = 'V'
            ),
            new ContentDocumentLink(
                ContentDocumentId = cmaDocId,
                LinkedEntityId = ippForm.Id,
                ShareType = 'V'
            )
        };

        Test.startTest();
        insert links;
        Test.stopTest();

        // -----------------------------
        // 6️ Verify Tasks created
        // -----------------------------
        List<Task> tasks = [SELECT Subject, WhatId, OwnerId FROM Task WHERE WhatId = :opp.Id];
        System.assertEquals(2, tasks.size(), 'Two tasks should be created');

        Set<String> subjects = new Set<String>();
        for (Task t : tasks) subjects.add(t.Subject);

        System.assert(subjects.contains('IPP Completed'), 'IPP task should be created');
        System.assert(subjects.contains('CMA Completed'), 'CMA task should be created');

        // -----------------------------
        // 7️ Verify Client Activate Date updated
        // -----------------------------
        Opportunity updatedOpp = [SELECT Client_Activate_Date__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertNotEquals(null, updatedOpp.Client_Activate_Date__c, 'Client Activate Date should be populated');
    }

   
}