/**
 * @class       AccountService
 * @description Metadata-driven client segmentation service for Household Accounts.
 *              Calculates a Segmentation Score and derives a Segment label
 *              based on three financial fields:
 *                  - Stated_Net_Worth__c
 *                  - Stated_HH_Income__c
 *                  - Billed_AUM__c
 *
 *              All thresholds, weights and segment bands are driven by Custom Metadata:
 *                  - Scoring_Benchmark__mdt  (field scores by Min_Value threshold)
 *                  - Scoring_Weight__mdt     (field weights, must sum to 100)
 *                  - Segmentation_Threshold__mdt (score → segment mapping)
 *
 *              Locking Logic:
 *              If Segmentation_Lock_Date__c is set to a date within the CURRENT
 *              calendar year the segment fields are NOT overwritten, preserving the
 *              locked value until the lock expires (i.e. rolls into the next year).
 *
 * @author      Mindruby Team
 * @date        2026-04-20
 */
public with sharing class AccountService {

    // ─────────────────────────────────────────────────────────────────────────
    // Field-type constants – must match Field_Type__c values in Custom Metadata
    // ─────────────────────────────────────────────────────────────────────────
    private static final String FIELD_TYPE_NW  = 'NW';
    private static final String FIELD_TYPE_INC = 'INC';
    private static final String FIELD_TYPE_AUM = 'AUM';

    // ─────────────────────────────────────────────────────────────────────────
    // In-memory metadata caches (loaded once per transaction)
    // ─────────────────────────────────────────────────────────────────────────
    private static Map<String, List<Scoring_Benchmark__mdt>>   benchmarkCache;
    private static Map<String, Decimal>                        weightCache;
    private static List<Segmentation_Threshold__mdt>           thresholdCache;

    // =========================================================================
    // PUBLIC ENTRY POINTS
    // =========================================================================

    /**
     * @description Process a list of Account Ids – bulk safe entry point.
     *              Called from triggers, flows, or the batch class.
     * @param       accountIds      Set of Account record Ids to process.
     * @param       setQuadPending  If true, sets Quad_Meeting_Creation_Pending__c = true
     *                              on successfully processed Accounts (use for batch).
     *                              Pass false when called from Opportunity trigger.
     */
    public static void processAccounts(Set<Id> accountIds, Boolean setQuadPending) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }

        List<Account> accounts = queryAccounts(accountIds);
        List<Account> toUpdate = new List<Account>();

        for (Account acc : accounts) {
            Account updated = calculateSegmentation(acc);
            if (updated != null) {
                if (setQuadPending == true) {
                    updated.Quad_Meeting_Creation_Pending__c = true;
                }
                toUpdate.add(updated);
            }
        }

        if (!toUpdate.isEmpty()) {
            try {
                update toUpdate; // bulkified DML
            } catch (DmlException ex) {
                ErrorLogService.logError('AccountService', 'processAccounts',
                    'DML failed while updating segmentation for ' + toUpdate.size() + ' Account(s) from Id set', ex);
                throw ex;
            }
        }
    }

    /**
     * @description Backward-compatible overload. Does NOT set Quad Pending flag.
     *              Existing callers (e.g. Opportunity trigger) remain unaffected.
     * @param       accountIds  Set of Account record Ids to process.
     */
    public static void processAccounts(Set<Id> accountIds) {
        processAccounts(accountIds, false);
    }

    /**
     * @description Overload that accepts a List of Account records already in memory.
     *              Useful when the caller already has the records (e.g. batch execute).
     * @param       accounts        List of Account records (must include required fields).
     * @param       setQuadPending  If true, sets Quad_Meeting_Creation_Pending__c = true.
     */
    public static void processAccounts(List<Account> accounts, Boolean setQuadPending) {
        if (accounts == null || accounts.isEmpty()) {
            return;
        }

        List<Account> toUpdate = new List<Account>();

        for (Account acc : accounts) {
            Account updated = calculateSegmentation(acc);
            if (updated != null) {
                if (setQuadPending == true) {
                    updated.Quad_Meeting_Creation_Pending__c = true;
                }
                toUpdate.add(updated);
            }
        }

        if (!toUpdate.isEmpty()) {
            try {
                update toUpdate;
            } catch (DmlException ex) {
                ErrorLogService.logError('AccountService', 'processAccounts',
                    'DML failed while updating segmentation for ' + toUpdate.size() + ' Account(s) from record list', ex);
                throw ex;
            }
        }
    }

    /**
     * @description Backward-compatible overload. Does NOT set Quad Pending flag.
     * @param       accounts  List of Account records (must include required fields).
     */
    public static void processAccounts(List<Account> accounts) {
        processAccounts(accounts, false);
    }


    public static void fpOnlyprocessAccounts(Set<Id> accountIds) {

        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }

        List<Account> accountsToUpdate = [
            SELECT Id, Segmentation_Lock_Date__c
            FROM Account
            WHERE Id IN :accountIds
        ];

        for (Account acc : accountsToUpdate) {
            acc.Segmentation_Lock_Date__c = Date.today();
        }

        if (!accountsToUpdate.isEmpty()) {
            update accountsToUpdate;
        }
    }

    /**
     * @description Bulk processes Accounts for segmentation with error capture.
     * @param       accounts        List of Account records (must include required fields).
     * @param       setQuadPending  If true, sets Quad_Meeting_Creation_Pending__c = true
     *                              on successfully processed Accounts.
     * @return      Map of Account Id to error message (only for failed records).
     */
    public static Map<Id, String> processAccountsWithResult(List<Account> accounts, Boolean setQuadPending) {
        Map<Id, String> errorMap = new Map<Id, String>();
        if (accounts == null || accounts.isEmpty()) {
            return errorMap;
        }

        List<Account> toUpdate = new List<Account>();
        for (Account acc : accounts) {
            try {
                Account updated = calculateSegmentation(acc);
                if (updated != null) {
                    if (setQuadPending == true) {
                        updated.Quad_Meeting_Creation_Pending__c = true;
                    }
                    toUpdate.add(updated);
                }
            } catch (Exception ex) {
                ErrorLogService.logError('AccountService', 'processAccountsWithResult',
                    'Segmentation calculation failed for Account Id: ' + acc.Id, ex);
                errorMap.put(acc.Id, ex.getMessage());
            }
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(toUpdate, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    String errs = '';
                    for (Database.Error err : results[i].getErrors()) {
                        errs += err.getMessage() + ' ';
                    }
                    errorMap.put(toUpdate[i].Id, errs.trim());
                }
            }
        }

        return errorMap;
    }

    /**
     * @description Backward-compatible overload. Does NOT set Quad Pending flag.
     * @param       accounts  List of Account records (must include required fields).
     * @return      Map of Account Id to error message (only for failed records).
     */
    public static Map<Id, String> processAccountsWithResult(List<Account> accounts) {
        return processAccountsWithResult(accounts, false);
    }

    // =========================================================================
    // CORE CALCULATION
    // =========================================================================

    /**
     * @description Orchestrates the three-step segmentation calculation for a
     *              single Account record and returns the mutated record ready for
     *              DML, or null if the record is locked.
     * @param       acc  Account record (must include financial + lock fields).
     * @return      Account with Segmentation_Score__c and Segmentation__c set,
     *              or null when the segmentation is locked for this year.
     */
    public static Account calculateSegmentation(Account acc) {
        if (isSegmentationLocked(acc)) {
            return null; // preserve the locked segment – skip this record
        }

        // Step 1 – individual field scores
        Decimal netWorthScore = getScore(FIELD_TYPE_NW,  acc.Stated_Net_Worth__c);
        Decimal incomeScore   = getScore(FIELD_TYPE_INC, acc.Stated_HH_Income__c);
        Decimal aumScore      = getScore(FIELD_TYPE_AUM, acc.Billed_AUM__c);
        // Step 2 – weighted composite score
        Decimal weightedScore = applyWeights(netWorthScore, incomeScore, aumScore);

        // Step 3 – derive segment label
        String segment = deriveSegment(weightedScore);

        acc.Segmentation_Score__c = weightedScore;
        acc.Segmentation__c       = segment;
        acc.Segmentation_Lock_Date__c = Date.today(); // set lock date to today to lock for the current year
        return acc;
    }

    // =========================================================================
    // STEP 1 – INDIVIDUAL SCORE LOOKUP
    // =========================================================================

    /**
     * @description Looks up the benchmark score for a given field type and value.
     *              The benchmark with the highest Min_Value__c that is still
     *              less than or equal to the supplied value is selected (floor match).
     * @param       fieldType  'NW', 'INC' or 'AUM'
     * @param       fieldValue The raw financial value (may be null → returns 0).
     * @return      Score between 0 and 100.
     */
    public static Decimal getScore(String fieldType, Decimal fieldValue) {
        if (fieldValue == null || fieldValue < 0) {
            return 0;
        }

        List<Scoring_Benchmark__mdt> benchmarks = getBenchmarksByFieldType(fieldType);
        // Benchmarks are sorted DESC by Min_Value__c (highest first).
        // Return the score of the first benchmark whose Min_Value__c ≤ fieldValue.
        for (Scoring_Benchmark__mdt bm : benchmarks) {
            Decimal minVal = bm.Min_Value__c != null ? bm.Min_Value__c : 0;
            if (fieldValue >= minVal) {
                return bm.Score__c != null ? bm.Score__c : 0;
            }
        }

        return 0; // below all thresholds
    }

    // =========================================================================
    // STEP 2 – APPLY WEIGHTS
    // =========================================================================

    /**
     * @description Multiplies each field score by its configured weight and sums
     *              the results.  Weights are sourced from Scoring_Weight__mdt and
     *              treated as percentages (e.g. 50 → 0.50 multiplier).
     * @param       netWorthScore  Score for Net Worth field  (0–100).
     * @param       incomeScore    Score for HH Income field  (0–100).
     * @param       aumScore       Score for Billed AUM field (0–100).
     * @return      Weighted composite score (0–100), rounded to 2 decimal places.
     */
    public static Decimal applyWeights(Decimal netWorthScore, Decimal incomeScore, Decimal aumScore) {
        Map<String, Decimal> weights = getWeightMap();

        Decimal nwWeight  = (weights.get(FIELD_TYPE_NW)  != null ? weights.get(FIELD_TYPE_NW)  : 0) / 100;
        Decimal incWeight = (weights.get(FIELD_TYPE_INC) != null ? weights.get(FIELD_TYPE_INC) : 0) / 100;
        Decimal aumWeight = (weights.get(FIELD_TYPE_AUM) != null ? weights.get(FIELD_TYPE_AUM) : 0) / 100;

        Decimal weighted =
            (netWorthScore * nwWeight) +
            (incomeScore   * incWeight) +
            (aumScore      * aumWeight);

        return weighted.setScale(2, RoundingMode.HALF_UP);
    }

    // =========================================================================
    // STEP 3 – DERIVE SEGMENT LABEL
    // =========================================================================

    /**
     * @description Maps a composite score to a segment label using the
     *              Segmentation_Threshold__mdt records.
     *              The threshold whose Min_Score__c ≤ score < Max_Score__c is selected.
     * @param       score  Composite weighted score (0–100).
     * @return      Segment label string (e.g. 'AAA', 'A', 'B', 'C').
     */
    public static String deriveSegment(Decimal score) {
        if (score == null) {
            score = 0;
        }

        List<Segmentation_Threshold__mdt> thresholds = getSegmentThresholds();

        // Thresholds sorted DESC by Min_Score__c – first match wins.
        for (Segmentation_Threshold__mdt st : thresholds) {
            Decimal minScore = st.Min_Score__c != null ? st.Min_Score__c : 0;
            Decimal maxScore = st.Max_Score__c != null ? st.Max_Score__c : 0;

            if (score >= minScore && score <= maxScore) {
                return st.Segment_Name__c;
            }
        }

        return 'C'; // fallback to lowest segment
    }

    // =========================================================================
    // LOCKING LOGIC
    // =========================================================================

    /**
     * @description Determines whether the segmentation on a given Account is
     *              locked for the current calendar year.
     *              Rule: if Segmentation_Lock_Date__c is set AND its year equals
     *              the current year, the record is considered locked.
     * @param       acc  Account record.
     * @return      true  – segmentation is locked, skip recalculation.
     *              false – segmentation can be (re)calculated.
     */
    public static Boolean isSegmentationLocked(Account acc) {
        if (acc.Segmentation_Lock_Date__c == null) {
            return false;
        }
        Integer lockYear    = acc.Segmentation_Lock_Date__c.year();
        Integer currentYear = Date.today().year();
        return lockYear == currentYear;
    }

    // =========================================================================
    // METADATA HELPERS – Cached per transaction
    // =========================================================================

    /**
     * @description Returns benchmarks for a specific field type, sorted by
     *              Min_Value__c descending (highest threshold first).
     */
    private static List<Scoring_Benchmark__mdt> getBenchmarksByFieldType(String fieldType) {
        if (benchmarkCache == null) {
            benchmarkCache = loadBenchmarks();
        }
        List<Scoring_Benchmark__mdt> result = benchmarkCache.get(fieldType);
        return result != null ? result : new List<Scoring_Benchmark__mdt>();
    }

    /**
     * @description Returns weight map keyed by field type.
     */
    private static Map<String, Decimal> getWeightMap() {
        if (weightCache == null) {
            weightCache = loadWeights();
        }
        return weightCache;
    }

    /**
     * @description Returns segmentation thresholds sorted by Min_Score__c DESC.
     */
    private static List<Segmentation_Threshold__mdt> getSegmentThresholds() {
        if (thresholdCache == null) {
            thresholdCache = loadThresholds();
        }
        return thresholdCache;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Metadata loaders
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Queries all Scoring_Benchmark__mdt records and groups them
     *              by Field_Type__c.  Each group is sorted by Min_Value__c DESC.
     */
    private static Map<String, List<Scoring_Benchmark__mdt>> loadBenchmarks() {
        Map<String, List<Scoring_Benchmark__mdt>> result = new Map<String, List<Scoring_Benchmark__mdt>>();

        List<Scoring_Benchmark__mdt> allBenchmarks = [
            SELECT Field_Type__c, Min_Value__c, Score__c
            FROM   Scoring_Benchmark__mdt
            ORDER BY Field_Type__c ASC, Min_Value__c DESC
        ];

        for (Scoring_Benchmark__mdt bm : allBenchmarks) {
            String ft = bm.Field_Type__c;
            if (!result.containsKey(ft)) {
                result.put(ft, new List<Scoring_Benchmark__mdt>());
            }
            result.get(ft).add(bm);
        }
        return result;
    }

    /**
     * @description Queries all Scoring_Weight__mdt records and returns a map of
     *              Field_Type__c → Weight_Percentage__c.
     */
    private static Map<String, Decimal> loadWeights() {
        Map<String, Decimal> result = new Map<String, Decimal>();

        List<Scoring_Weight__mdt> allWeights = [
            SELECT Field_Type__c, Weight_Percentage__c
            FROM   Scoring_Weight__mdt
        ];

        for (Scoring_Weight__mdt w : allWeights) {
            result.put(w.Field_Type__c, w.Weight_Percentage__c);
        }

        return result;
    }

    /**
     * @description Queries all Segmentation_Threshold__mdt records sorted by
     *              Min_Score__c DESC so the highest band is evaluated first.
     */
    private static List<Segmentation_Threshold__mdt> loadThresholds() {
        return [
            SELECT Segment_Name__c, Min_Score__c, Max_Score__c
            FROM Segmentation_Threshold__mdt
            ORDER BY Min_Score__c DESC
        ];
    }

    // =========================================================================
    // QUERY HELPER
    // =========================================================================

    /**
     * @description Queries Account records with all fields required for
     *              segmentation calculation.
     * @param       accountIds  Set of Account Ids.
     * @return      List of Account records.
     */
    private static List<Account> queryAccounts(Set<Id> accountIds) {
        return [
            SELECT Id,
                   Stated_Net_Worth__c,
                   Stated_HH_Income__c,
                   Billed_AUM__c,
                   Segmentation_Score__c,
                   Segmentation__c,
                   Segmentation_Lock_Date__c
            FROM   Account
            WHERE  Id IN :accountIds
        ];
    }
}