public class DiabetesCareObservationTriggerHandler {
    
    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }
    
    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }
    
    private static void processObservations(List<CareObservation> newObservations) {
        // Get thresholds from Custom Metadata (cached automatically)
        Diabetes_Threshold__mdt thresholds = [SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
                                              FROM Diabetes_Threshold__mdt
                                              WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
                                              LIMIT 1];

        List<Task> tasksToCreate = new List<Task>();
        Set<Id> observationIds = new Set<Id>();
        Set<Id> codeIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        // First pass: collect Code IDs to query
        for(CareObservation obs : newObservations) {
            if(obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        // Query CodeSet records to get code names
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>(
            [SELECT Id, Name FROM CodeSet WHERE Id IN :codeIds]
        );

        // Second pass: collect observation IDs and HbA1c values for bulk processing
        for(CareObservation obs : newObservations) {
            CodeSet code = codeMap.get(obs.CodeId);
            String codeName = code != null ? code.Name : null;

            System.debug('Code Name: ' + codeName);
            // Only process finalized HbA1c observations with valid data
            // Use metadata threshold instead of hardcoded 8.0
            if(codeName == 'HbA1c' &&
               obs.ObservationStatus == 'final' &&
               obs.ObservedValueType == 'Quantity' &&
               obs.ObservedValueNumerator != null &&
               obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c && // Dynamic threshold!
               obs.ObservedSubjectId != null) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if(!observationIds.isEmpty()) {
            // Bug 1: SOQL query inside loop - should be outside loop for bulk processing
            for(Id observationId : observationIds) {
                List<Task> existingTasks = [SELECT Id, WhatId FROM Task
                                           WHERE WhatId = :observationId
                                           AND Subject LIKE '%HbA1c Follow-up%'
                                           AND Status != 'Completed'
                                           AND CreatedDate = LAST_N_DAYS:30];

                if(existingTasks.isEmpty()) {
                    Decimal hba1cValue = observationHbA1cMap.get(observationId);

                    Task followUpTask = new Task();
                    followUpTask.Subject = 'HbA1c Follow-up Required - ' + Date.today().format();
                    followUpTask.WhatId = observationId; // Task linked to CareObservation record
                    // Bug 2: Missing required ActivityDate field

                    // Use metadata thresholds for priority and due dates
                    if(hba1cValue >= thresholds.Critical_Percentage__c) {
                        followUpTask.Priority = 'High';
                    } else if(hba1cValue >= thresholds.Warning_Percentage__c) {
                        followUpTask.Priority = 'Normal';
                    } else {
                        followUpTask.Priority = 'Low';
                    }

                    followUpTask.Status = 'Not Started';
                    followUpTask.Type = 'Call';

                    // Bug 3: No null check on hba1cValue in string concatenation
                    followUpTask.Description = 'Patient has new HbA1c level of ' +
                                             hba1cValue + '%. Schedule follow-up appointment to review ' +
                                             'diabetes management plan and medication adherence. ' +
                                             'Thresholds: Target <' + thresholds.Target_Percentage__c +
                                             '%, Warning ≥' + thresholds.Warning_Percentage__c +
                                             '%, Critical ≥' + thresholds.Critical_Percentage__c + '%.';

                    // Bug 4: DML inside loop instead of adding to collection for bulk insert
                    insert followUpTask;
                }
            }
        }
    }
}

