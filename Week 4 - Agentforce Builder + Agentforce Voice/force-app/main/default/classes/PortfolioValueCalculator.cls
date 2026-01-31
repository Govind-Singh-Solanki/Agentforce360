public class PortfolioValueCalculator {
    /**
     * @description Invocable utility to calculate total portfolio value for FinancialAccount records.
     * Accepts optional filters for Status and Account Type.
     * - Bulkified: operates without DML/SOQL in loops
     * - Security: Queries run in user mode to respect sharing/FLS
     */
    
    // Get total portfolio value
    @InvocableMethod(label='Calculate Total Portfolio Value' 
                     description='Returns sum of financial account loan amounts. Optionally filter by status and account type.')
    public static List<ValueResult> calculatePortfolioValue(List<InputRequest> requests) {
        // Defaults
        String status = 'Active';
        String accountType;

        if (requests != null && !requests.isEmpty() && requests[0] != null) {
            InputRequest input = requests[0];
            if (input.status != null && input.status.trim() != '') {
                status = input.status.trim();
            }
            if (input.accountType != null && input.accountType.trim() != '') {
                accountType = input.accountType.trim();
            }
        }

        // Build dynamic query with optional account type filter
        String baseQuery = 'SELECT Id, Original_Loan_Amount__c FROM FinancialAccount WITH USER_MODE WHERE Status = :status';
        if (accountType != null) {
            baseQuery += ' AND Type__c = :accountType';
        }

        List<FinancialAccount> accounts = Database.query(baseQuery);

        Decimal totalValue = 0;
        for (FinancialAccount account : accounts) {
            if (account.Original_Loan_Amount__c != null) {
                totalValue += account.Original_Loan_Amount__c;
            }
        }

        ValueResult result = new ValueResult();
        result.totalValue = totalValue;

        return new List<ValueResult>{ result };
    }
    
    // Input wrapper class for agent parameters
    public class InputRequest {
        @InvocableVariable(label='Status' 
                          description='Optional: Filter by status (e.g., Active, Closed). Defaults to Active if not provided.')
        public String status;

        @InvocableVariable(label='Account Type'
                           description='Optional: Filter by account type (e.g., Mortgage, Loan, etc.).')
        public String accountType;
    }
    
    // Output wrapper class for invocable method results
    public class ValueResult {
        @InvocableVariable(label='Total Portfolio Value' 
                           description='The sum of all financial account loan amounts matching the specified filters')
        public Decimal totalValue;
    }
}
