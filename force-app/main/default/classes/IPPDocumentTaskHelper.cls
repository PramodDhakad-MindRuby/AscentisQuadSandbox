public class IPPDocumentTaskHelper {

    public static void handleAfterInsert(List<ContentDocumentLink> newLinks) {

        Set<Id> ippFormIds = new Set<Id>();
        Map<Id, Id> docToIppMap = new Map<Id, Id>();

        // Identify files linked to IPP_CMA_Form__c
        for (ContentDocumentLink cdl : newLinks) {

            if (cdl.LinkedEntityId != null &&
                cdl.LinkedEntityId.getSObjectType() == IPP_CMA_Form__c.SObjectType) {

                ippFormIds.add(cdl.LinkedEntityId);
                docToIppMap.put(cdl.ContentDocumentId, cdl.LinkedEntityId);
            }
        }

        if (ippFormIds.isEmpty()) return;

        // Get File Titles
        Map<Id, ContentDocument> docMap = new Map<Id, ContentDocument>(
            [SELECT Id, Title, CreatedDate
             FROM ContentDocument
             WHERE Id IN :docToIppMap.keySet()]
        );

        // Get IPP Forms with Opportunity
        Map<Id, IPP_CMA_Form__c> ippMap = new Map<Id, IPP_CMA_Form__c>(
            [SELECT Id, Opportunity__c
             FROM IPP_CMA_Form__c
             WHERE Id IN :ippFormIds]
        );

        Set<Id> oppIds = new Set<Id>();
        for (IPP_CMA_Form__c ipp : ippMap.values()) {
            if (ipp.Opportunity__c != null) {
                oppIds.add(ipp.Opportunity__c);
            }
        }

        if (oppIds.isEmpty()) return;

        // Get Opportunities with CSR User and Client Activate Date
        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>(
            [SELECT Id, CRS__c, Client_Activate_Date__c
             FROM Opportunity
             WHERE Id IN :oppIds]
        );

        List<Task> tasksToInsert = new List<Task>();
        List<Opportunity> oppsToUpdate = new List<Opportunity>();

        for (Id docId : docToIppMap.keySet()) {

            ContentDocument doc = docMap.get(docId);
            Id ippId = docToIppMap.get(docId);

            if (doc == null || doc.Title == null) continue;

            IPP_CMA_Form__c ipp = ippMap.get(ippId);
            if (ipp == null || ipp.Opportunity__c == null) continue;

            Opportunity opp = oppMap.get(ipp.Opportunity__c);
            if (opp == null) continue;

            // -----------------------------
            // 1️⃣ IPP Signed Document → Create Task
            // -----------------------------
            if (doc.Title.contains('IPP Signed Document')) {

                if (opp.CRS__c != null) {

                    Task t = new Task();
                    t.Subject = 'IPP Completed';
                    t.WhatId = opp.Id;
                    t.OwnerId = opp.CRS__c;
                    t.Status = 'Not Started';
                    t.Priority = 'Normal';
                    t.ActivityDate = Date.today();

                    tasksToInsert.add(t);
                }
            }

            // -----------------------------
            // 2️⃣ CMA Signed Document → Update Client Activate Date + Create Task
            // -----------------------------
            if (doc.Title.contains('CMA Signed Document')) {

                // Update Client Activate Date (overwrite or keep blank if desired)
                Opportunity oppUpdate = new Opportunity(
                    Id = opp.Id,
                    Client_Activate_Date__c = doc.CreatedDate
                );
                oppsToUpdate.add(oppUpdate);

                // Create Task for CSR
                if (opp.CRS__c != null) {
                    Task t = new Task();
                    t.Subject = 'CMA Completed';
                    t.WhatId = opp.Id;
                    t.OwnerId = opp.CRS__c;
                    t.Status = 'Not Started';
                    t.Priority = 'Normal';
                    t.ActivityDate = Date.today();

                    tasksToInsert.add(t);
                }
            }
        }

        // Bulk insert/update
        if (!tasksToInsert.isEmpty()) {
            insert tasksToInsert;
           
        }

        if (!oppsToUpdate.isEmpty()) {
            update oppsToUpdate;
            
        }
    }
}