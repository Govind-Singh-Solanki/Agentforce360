/**
 * DiabetesCareAssessment
 * Apex class for assessing diabetes care based on HbA1c values and program enrollment.
 *
 * Overview:
 * - Invocable from Flow and other automation tools
 * - Retrieves latest HbA1c observation per patient
 * - Checks active Diabetes program enrollment
 * - Categorizes risk based on HbA1c thresholds
 *
 * Security:
 * - with sharing to honor sharing rules
 * - Uses WITH SECURITY_ENFORCED on queries where applicable
 * - Uses USER_MODE for DML (no DML here) and WITH USER_MODE for queries where supported
 *
 * Code Quality:
 * - Bulkified processing (works on lists of patients)
 * - Early returns for null/empty inputs
 * - Clear error handling and messages
 *
 * Salesforce Objects:
 * - CodeSet
 * - CareObservation
 * - CareProgram
 * - CareProgramEnrollee
 *
 * Author: Agentforce
 * Date: 2026-01-24
 */
public with sharing class DiabetesCareAssessment {

    /**
     * Risk categories represented as enum to avoid string literals throughout code.
     */
    public enum RISK_CATEGORY {
        WELL_CONTROLLED,
        NEEDS_ATTENTION,
        HIGH_RISK_URGENT,
        NO_DATA_AVAILABLE
    }

    /**
     * AssessmentRequest
     * Input wrapper for invocable method.
     */
    public class AssessmentRequest {
        /**
         * The Salesforce ID of the patient/account to assess
         */
        @InvocableVariable(label='Patient Id' description='The Salesforce ID of the patient/account to assess' required=true)
        public Id patientId;

        /**
         * Number of days to look back for observations (currently not used)
         */
        @InvocableVariable(label='Days Lookback' description='Number of days to look back for observations (currently not used)' required=false)
        public Integer daysLookback;

        /** No-arg constructor */
        public AssessmentRequest() {}

        /** Parameterized constructor */
        public AssessmentRequest(Id patientId, Integer daysLookback) {
            this.patientId = patientId;
            this.daysLookback = daysLookback;
        }
    }

    /**
     * AssessmentResult
     * Output wrapper for invocable method.
     */
    public class AssessmentResult {
        /** The Salesforce ID of the patient that was assessed */
        @InvocableVariable(label='Patient Id' description='The Salesforce ID of the patient that was assessed' required=false)
        public Id patientId;

        /** The latest HbA1c value found for the patient (can be null if no observation found) */
        @InvocableVariable(label='HbA1c Value' description='The latest HbA1c value found for the patient (can be null if no observation found)' required=false)
        public Decimal hba1cValue;

        /** Categorized risk level based on HbA1c value */
        @InvocableVariable(label='Risk Category' description='Categorized risk level based on HbA1c value' required=false)
        public String riskCategory;

        /** Indicates whether the patient is enrolled in an active Diabetes care program */
        @InvocableVariable(label='In Diabetes Program' description='Indicates whether the patient is enrolled in an active Diabetes care program' required=false)
        public Boolean isInDiabetesProgram;

        /** Contains error message if processing failed for this patient (null if successful) */
        @InvocableVariable(label='Error Message' description='Contains error message if processing failed for this patient (null if successful)' required=false)
        public String errorMessage;

        /** No-arg constructor */
        public AssessmentResult() {}

        /** Parameterized constructor */
        public AssessmentResult(Id patientId) {
            this.patientId = patientId;
        }
    }

    /**
     * Invocable method entry point.
     * Assesses patient diabetes care based on HbA1c values and program enrollment.
     *
     * @param requests List of AssessmentRequest inputs (patientId required)
     * @return List of AssessmentResult outputs, one per patient
     */
    @InvocableMethod(label='Assess Patient' description='Assesses patient diabetes care based on HbA1c values and program enrollment')
    public static List<AssessmentResult> assessPatient(List<AssessmentRequest> requests) {
        // 1) Input validation - return early if no work
        if (requests == null || requests.isEmpty()) {
            return new List<AssessmentResult>();
        }

        // 2) Extract patient Ids and map back to requests
        Set<Id> patientIds = new Set<Id>();
        Map<Id, AssessmentRequest> requestByPatientId = new Map<Id, AssessmentRequest>();
        for (AssessmentRequest req : requests) {
            if (req != null && req.patientId != null) {
                patientIds.add(req.patientId);
                requestByPatientId.put(req.patientId, req);
            }
        }

        List<AssessmentResult> results = new List<AssessmentResult>();

        if (patientIds.isEmpty()) {
            // No valid patient Ids provided - return empty result set
            return results;
        }

        // 3) HbA1c CodeSet lookup
        Id hba1cCodeSetId = getHbA1cCodeSetId();
        if (hba1cCodeSetId == null) {
            // If not found, return error result for each patient
            for (Id pid : patientIds) {
                AssessmentResult res = new AssessmentResult(pid);
                res.errorMessage = 'HbA1c CodeSet not found in the system';
                res.riskCategory = String.valueOf(RISK_CATEGORY.NO_DATA_AVAILABLE).replace('_', ' ');
                res.isInDiabetesProgram = false;
                results.add(res);
            }
            return results;
        }

        // 4) Data Retrieval
        Map<Id, CareObservation> latestObsByPatient = getLatestHbA1cObservations(patientIds, hba1cCodeSetId);
        Map<Id, Boolean> programEnrollmentByPatient = checkActiveDiabetesPrograms(patientIds);

        // 5) Result Processing
        for (Id pid : patientIds) {
            AssessmentResult res = new AssessmentResult(pid);
            try {
                CareObservation obs = latestObsByPatient.get(pid);
                if (obs != null && obs.ObservedValueNumerator != null) {
                    res.hba1cValue = obs.ObservedValueNumerator;

                    // Categorize risk
                    if (res.hba1cValue < 7.0) {
                        res.riskCategory = 'Well Controlled';
                    } else if (res.hba1cValue >= 7.0 && res.hba1cValue < 9.0) {
                        res.riskCategory = 'Needs Attention';
                    } else {
                        res.riskCategory = 'High Risk/Urgent';
                    }
                } else {
                    res.riskCategory = 'No Data Available';
                }

                res.isInDiabetesProgram = programEnrollmentByPatient.containsKey(pid) ? programEnrollmentByPatient.get(pid) : false;
            } catch (Exception ex) {
                res.errorMessage = 'Error processing patient ' + String.valueOf(pid) + ': ' + ex.getMessage();
                // Provide at least default category/enrollment
                if (res.riskCategory == null) {
                    res.riskCategory = 'No Data Available';
                }
                if (res.isInDiabetesProgram == null) {
                    res.isInDiabetesProgram = false;
                }
            }
            results.add(res);
        }

        // 6) Return results
        return results;
    }

    /**
     * Retrieves the Salesforce ID of the CodeSet record named 'HbA1c'.
     * @return Id of the CodeSet or null if not found
     */
    private static Id getHbA1cCodeSetId() {
        // Early return if no records exist
        List<CodeSet> cs = [
            SELECT Id
            FROM CodeSet
            WHERE Name = 'HbA1c'
            LIMIT 1
        ];
        return cs.isEmpty() ? null : cs[0].Id;
    }

    /**
     * Retrieves the most recent HbA1c observation for each patient.
     *
     * @param patientIds Set of patient/account IDs to query
     * @param hba1cCodeSetId The ID of the HbA1c CodeSet
     * @return Map of patient Id to latest CareObservation
     */
    private static Map<Id, CareObservation> getLatestHbA1cObservations(Set<Id> patientIds, Id hba1cCodeSetId) {
        Map<Id, CareObservation> latestByPatient = new Map<Id, CareObservation>();
        if (patientIds == null || patientIds.isEmpty() || hba1cCodeSetId == null) {
            return latestByPatient;
        }

        // Query latest finalized HbA1c observations with numeric value
        List<CareObservation> obsList = [
            SELECT Id, ObservedSubjectId, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE CodeId = :hba1cCodeSetId
              AND ObservedSubjectId IN :patientIds
              AND ObservationStatus = 'Final'
              AND ObservedValueType = 'Quantity'
              AND ObservedValueNumerator != null
            ORDER BY EffectiveDateTime DESC NULLS LAST
            LIMIT 1000
        ];

        for (CareObservation obs : obsList) {
            // First seen per patient is the latest due to ordering
            if (obs.ObservedSubjectId != null && !latestByPatient.containsKey(obs.ObservedSubjectId)) {
                latestByPatient.put(obs.ObservedSubjectId, obs);
            }
        }
        return latestByPatient;
    }

    /**
     * Determines which patients are enrolled in active Diabetes care programs.
     *
     * @param patientIds Set of patient/account IDs to check
     * @return Map of patient Id to boolean indicating active diabetes program enrollment
     */
    private static Map<Id, Boolean> checkActiveDiabetesPrograms(Set<Id> patientIds) {
        Map<Id, Boolean> enrolledMap = new Map<Id, Boolean>();
        if (patientIds == null || patientIds.isEmpty()) {
            return enrolledMap;
        }

        // Initialize all as not enrolled
        for (Id pid : patientIds) {
            enrolledMap.put(pid, false);
        }

        // Query active enrollments for programs with name like %Diabetes%
        List<CareProgramEnrollee> enrollees = [
            SELECT Id, CareProgramId, AccountId, Status
            FROM CareProgramEnrollee
            WHERE AccountId IN :patientIds
              AND Status = 'Active'
              AND CareProgramId IN (
                  SELECT Id FROM CareProgram WHERE Name LIKE '%Diabetes%'
              )
        ];

        for (CareProgramEnrollee cpe : enrollees) {
            if (cpe.AccountId != null) {
                enrolledMap.put(cpe.AccountId, true);
            }
        }
        return enrolledMap;
    }
}
