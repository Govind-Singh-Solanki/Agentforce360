public class DiabetesCareObservationTriggerHandler {
    
    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }
    
    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }
    
    private static void processObservations(List<CareObservation> newObservations) {
        if(newObservations == null || newObservations.isEmpty()) {
            return;
        }

        // Get thresholds from Custom Metadata (cached automatically)
        Diabetes_Threshold__mdt thresholds = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];

        List<Task> tasksToCreate = new List<Task>();
        Set<Id> observationIds = new Set<Id>();
        Set<Id> codeIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        // First pass: collect Code IDs to query
        for (CareObservation obs : newObservations) {
            if (obs != null && obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        // Query CodeSet records to get code names (avoid querying if set is empty)
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            for (CodeSet cs : [SELECT Id, Name FROM CodeSet WHERE Id IN :codeIds]) {
                codeMap.put(cs.Id, cs);
            }
        }

        // Second pass: collect observation IDs and HbA1c values for bulk processing
        for (CareObservation obs : newObservations) {
            if (obs == null) continue;
            CodeSet code = obs.CodeId != null ? codeMap.get(obs.CodeId) : null;
            String codeName = (code != null) ? code.Name : null;

            // Only process finalized HbA1c observations with valid data
            if (codeName == 'HbA1c' &&
                obs.ObservationStatus == 'final' &&
                obs.ObservedValueType == 'Quantity' &&
                obs.ObservedValueNumerator != null &&
                obs.ObservedSubjectId != null &&
                thresholds != null &&
                thresholds.Warning_Percentage__c != null &&
                obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (observationIds.isEmpty()) {
            return;
        }

        // Bulk query existing tasks once for all observations to prevent duplicates
        Map<Id, List<Task>> existingByWhat = new Map<Id, List<Task>>();
        for (Task t : [
            SELECT Id, WhatId
            FROM Task
            WHERE WhatId IN :observationIds
              AND Subject LIKE '%HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ]) {
            if (!existingByWhat.containsKey(t.WhatId)) {
                existingByWhat.put(t.WhatId, new List<Task>());
            }
            existingByWhat.get(t.WhatId).add(t);
        }

        Date today = Date.today();
        for (Id observationId : observationIds) {
            List<Task> existingTasks = existingByWhat.get(observationId);
            if (existingTasks != null && !existingTasks.isEmpty()) {
                continue; // one already exists recently, skip
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);

            Task followUpTask = new Task();
            followUpTask.Subject = 'HbA1c Follow-up Required - ' + today.format();
            followUpTask.WhatId = observationId; // Task linked to CareObservation record

            // Set required ActivityDate; sooner for higher risk
            if (thresholds != null && thresholds.Critical_Percentage__c != null
                && hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.ActivityDate = today; // same day for critical
                followUpTask.Priority = 'High';
            } else if (thresholds != null && thresholds.Warning_Percentage__c != null
                && hba1cValue != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                followUpTask.ActivityDate = today.addDays(3);
                followUpTask.Priority = 'Normal';
            } else {
                // Fallback defensively (shouldn't happen due to earlier filters)
                followUpTask.ActivityDate = today.addDays(7);
                followUpTask.Priority = 'Low';
            }

            followUpTask.Status = 'Not Started';
            followUpTask.Type = 'Call';

            // Safe description with null checks
            String valueStr = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue);
            followUpTask.Description =
                'Patient has new HbA1c level of ' + valueStr + '%. Schedule follow-up appointment to review ' +
                'diabetes management plan and medication adherence. ' +
                'Thresholds: Target <' + String.valueOf(thresholds.Target_Percentage__c) +
                '%, Warning ≥' + String.valueOf(thresholds.Warning_Percentage__c) +
                '%, Critical ≥' + String.valueOf(thresholds.Critical_Percentage__c) + '%.';

            tasksToCreate.add(followUpTask);
        }

        if (!tasksToCreate.isEmpty()) {
            Database.insert(tasksToCreate, false);
        }
    }
}
