# ============================================================================
# AFib Case/Control Cohort Pipeline (R reimplementation)
# OHDSI Capr -> Circe JSON -> OHDSI-SQL -> CohortGenerator -> FeatureExtraction
# Output: results.final_ml_matrix_r (SQL script's own output, main.final_ml_matrix,
#         is left completely untouched for comparison in step 17)
# ============================================================================

library(DatabaseConnector)
library(CohortGenerator)
library(Capr)
library(SqlRender)
library(jsonlite)
library(dplyr)
library(FeatureExtraction)

# ----------------------------------------------------------------------------
# 1. Connection
# ----------------------------------------------------------------------------
connectionDetails <- createConnectionDetails(
  dbms   = "duckdb",
  server = "D:/MIMIC/MIMIC-omop.db"
)
connection <- connect(connectionDetails)

executeSql(connection, "CREATE SCHEMA IF NOT EXISTS results;")

cdmDatabaseSchema    <- "main"
cohortDatabaseSchema <- "results"
cohortTable          <- "afib_study_cohorts"

# ----------------------------------------------------------------------------
# 2. Verify target concept
# ----------------------------------------------------------------------------
querySql(connection,
         "SELECT concept_id, concept_name, domain_id, standard_concept
   FROM main.concept
   WHERE concept_id = 4068155;"
)

# ----------------------------------------------------------------------------
# 3. Concept set
# ----------------------------------------------------------------------------
afib_concept <- cs(descendants(4068155), name = "Atrial Fibrillation")

# ----------------------------------------------------------------------------
# 4. Cohort 1: Cases (first AFib condition occurrence)
# ----------------------------------------------------------------------------
cases_def <- cohort(
  entry = entry(
    conditionOccurrence(afib_concept),
    primaryCriteriaLimit = "First"
  )
)

# ----------------------------------------------------------------------------
# 5. Cohort 2: Controls (last visit, no AFib history ever - global exclusion,
#    matches SQL's "NOT IN (SELECT person_id FROM target_patients)")
# ----------------------------------------------------------------------------
controls_def <- cohort(
  entry = entry(
    visit(conceptSet = NULL),
    primaryCriteriaLimit = "Last"
  ),
  attrition = attrition(
    "No History of AFib" = withAll(
      exactly(
        0,
        conditionOccurrence(afib_concept),
        duringInterval(eventStarts(-Inf, Inf))
      )
    )
  )
)

# ----------------------------------------------------------------------------
# 6. Compile Capr cohorts -> Circe JSON -> OHDSI-SQL
# ----------------------------------------------------------------------------
cases_json    <- as.json(cases_def)
controls_json <- as.json(controls_def)

cohortDefinitionSet <- tibble::tibble(
  cohortId   = c(1L, 2L),
  cohortName = c("AFib_Cases", "AFib_Controls"),
  json       = c(cases_json, controls_json)
)

cohortDefinitionSet$sql <- vapply(
  cohortDefinitionSet$json,
  function(x) {
    CirceR::buildCohortQuery(
      CirceR::cohortExpressionFromJson(x),
      options = CirceR::createGenerateOptions(generateStats = FALSE)
    )
  },
  character(1)
)

# ----------------------------------------------------------------------------
# 7. Create cohort tables and generate cohorts
# ----------------------------------------------------------------------------
cohortTableNames <- getCohortTableNames(cohortTable = cohortTable)

createCohortTables(
  connection = connection,
  cohortDatabaseSchema = cohortDatabaseSchema,
  cohortTableNames = cohortTableNames
)

generateCohortSet(
  connection = connection,
  cdmDatabaseSchema = cdmDatabaseSchema,
  cohortDatabaseSchema = cohortDatabaseSchema,
  cohortTableNames = cohortTableNames,
  cohortDefinitionSet = cohortDefinitionSet
)

# ----------------------------------------------------------------------------
# 8. Pull generated cohort and build ML target labels
#    subject_id cast to VARCHAR to preserve exact precision (surrogate keys
#    exceed 2^53 and can be negative due to signed 64-bit hash overflow)
# ----------------------------------------------------------------------------
sql <- "SELECT cohort_definition_id, CAST(subject_id AS VARCHAR) AS subject_id,
               CAST(cohort_start_date AS DATE) AS cohort_start_date
        FROM @results_schema.@cohort_table;"

sql <- render(sql,
              results_schema = cohortDatabaseSchema,
              cohort_table = cohortTableNames$cohortTable)
sql <- translate(sql, targetDialect = connectionDetails$dbms)

patient_index <- querySql(connection, sql)

target_labels <- patient_index %>%
  mutate(
    target_ecg_afib = ifelse(cohort_definition_id == 1, 1, 0),
    index_date = cohort_start_date
  ) %>%
  select(subject_id, index_date, target_ecg_afib)

# ----------------------------------------------------------------------------
# 9. Surrogate row_id mapping — sidesteps int64 precision loss in
#    getDbCovariateData by giving FeatureExtraction a small, sequential,
#    double-safe id instead of the raw hashed subject_id. Mapped back
#    afterward via our own VARCHAR cast (step 12).
# ----------------------------------------------------------------------------
mapTable <- paste0(cohortTableNames$cohortTable, "_rowmap")

executeSql(connection, sprintf("
  CREATE OR REPLACE TABLE %s.%s AS
  SELECT subject_id, ROW_NUMBER() OVER (ORDER BY subject_id) AS row_id
  FROM (SELECT DISTINCT subject_id FROM %s.%s);
", cohortDatabaseSchema, mapTable, cohortDatabaseSchema, cohortTableNames$cohortTable))

# Clone of the cohort table with row_id swapped in for subject_id.
# Column is still literally named "subject_id" so FeatureExtraction's
# default rowIdField assumption ("subject_id") still applies unchanged.
feCohortTable <- paste0(cohortTableNames$cohortTable, "_fe")

executeSql(connection, sprintf("
  CREATE OR REPLACE TABLE %s.%s AS
  SELECT c.cohort_definition_id, m.row_id AS subject_id,
         c.cohort_start_date, c.cohort_end_date
  FROM %s.%s AS c
  INNER JOIN %s.%s AS m ON c.subject_id = m.subject_id;
", cohortDatabaseSchema, feCohortTable,
                               cohortDatabaseSchema, cohortTableNames$cohortTable,
                               cohortDatabaseSchema, mapTable))

# ----------------------------------------------------------------------------
# 10. Covariate settings — replaces 03_tall_features (conditions + measurements)
#     - useConditionOccurrenceAnyTimePrior: binary flag, any condition any time
#       on/before cohort_start_date (mirrors "co.condition_start_date <= idx.index_date")
#     - useMeasurementValueAnyTimePrior: numeric value, any time on/before
#       cohort_start_date
#     - excludedCovariateConceptIds + addDescendantsToExclude: drops AFib and
#       all its descendants from the candidate covariate set, matching the
#       "LEFT JOIN concept_ancestor ... WHERE ca.ancestor_concept_id IS NULL"
#       leakage guard in the SQL version
# ----------------------------------------------------------------------------
covariateSettings <- createCovariateSettings(
  useConditionOccurrenceAnyTimePrior = TRUE,
  useMeasurementValueAnyTimePrior    = TRUE,
  excludedCovariateConceptIds        = 4068155,
  addDescendantsToExclude            = TRUE
)

# ----------------------------------------------------------------------------
# 11. Extract covariates for both cohorts (cases=1, controls=2)
#     Clears any orphaned temp tables (id_set_*, cov_*, ref_*) left behind by
#     a previously interrupted/errored call before retrying — DuckDB doesn't
#     always roll these back automatically the way Postgres/SQL Server do.
# ----------------------------------------------------------------------------
orphans <- querySql(connection, "
  SELECT table_name FROM duckdb_tables()
  WHERE temporary = TRUE
    AND (table_name LIKE 'id_set_%' OR table_name LIKE 'cov_%' OR table_name LIKE 'ref_%');
")
for (tbl in orphans$table_name) {
  executeSql(connection, sprintf('DROP TABLE IF EXISTS "%s";', tbl))
}

covariateData <- getDbCovariateData(
  connection           = connection,
  cdmDatabaseSchema    = cdmDatabaseSchema,
  cohortDatabaseSchema = cohortDatabaseSchema,
  cohortTable          = feCohortTable,     # remapped table, small ints
  cohortIds            = c(1, 2),
  rowIdField           = "subject_id",      # = surrogate row_id, safe as double
  covariateSettings    = covariateSettings,
  aggregated           = FALSE
)

# ----------------------------------------------------------------------------
# 12. Pivot long -> wide (FeatureExtraction analog of the DuckDB
#     "PIVOT tall_features ON feature_name USING MAX(feature_value)" step).
#     Joins back through row_map to recover the true (precision-safe) subject_id.
#
#     Analysis IDs (per FeatureExtraction::createCovariateSettings):
#       101 = ConditionOccurrenceAnyTimePrior
#       705 = MeasurementValueAnyTimePrior   (NOT 464 - verified against
#             package source; 464 falls in the unrelated DrugGroupEra range
#             and would silently fall through to the default case_when branch,
#             producing unprefixed measurement feature names)
# ----------------------------------------------------------------------------
row_map <- querySql(connection, sprintf(
  "SELECT row_id, CAST(subject_id AS VARCHAR) AS subject_id FROM %s.%s;",
  cohortDatabaseSchema, mapTable
))
row_map <- row_map %>%
  mutate(row_id = as.integer(row_id))
covariate_ref <- collect(covariateData$covariateRef)

covariates_df <- covariateData$covariates %>%
  collect() %>%
  inner_join(covariate_ref, by = "covariateId") %>%
  inner_join(row_map, by = c("rowId" = "row_id")) %>%
  transmute(
    subject_id,
    feature_name = case_when(
      analysisId %in% c(101) ~ paste0("condition_", covariateName),   # ConditionOccurrenceAnyTimePrior
      analysisId %in% c(705) ~ paste0("measurement_", covariateName), # MeasurementValueAnyTimePrior
      TRUE ~ covariateName
    ),
    feature_value = covariateValue
  )

feature_matrix <- covariates_df %>%
  tidyr::pivot_wider(
    id_cols     = subject_id,
    names_from  = feature_name,
    values_from = feature_value,
    values_fill = 0
  )

# ----------------------------------------------------------------------------
# 13. Demographics (year_of_birth, gender) — direct pull from `person`,
#     same as the SQL final_ml_matrix step: plain joined columns, not part
#     of covariateData.
# ----------------------------------------------------------------------------
sql_demo <- "SELECT CAST(p.person_id AS VARCHAR) AS subject_id,
                     p.year_of_birth,
                     c.concept_name AS gender
              FROM main.person AS p
              LEFT JOIN main.concept AS c
                ON p.gender_concept_id = c.concept_id
               AND c.invalid_reason IS NULL;"

demographics <- querySql(connection, sql_demo)

# ----------------------------------------------------------------------------
# 14. Assemble final_ml_matrix  ★ MAIN OUTPUT OF PHASE 1 ★
# ----------------------------------------------------------------------------
final_ml_matrix <- target_labels %>%
  mutate(subject_id = as.character(subject_id)) %>%
  left_join(demographics, by = "subject_id") %>%
  left_join(feature_matrix, by = "subject_id") %>%
  mutate(across(starts_with("condition_") | starts_with("measurement_"),
                ~ tidyr::replace_na(.x, 0)))

# ----------------------------------------------------------------------------
# 15. Sanity check — case counts should agree across every stage, mirroring
#     the final SELECT in the SQL script
# ----------------------------------------------------------------------------
tibble::tibble(
  cases_in_patient_index = sum(patient_index$cohort_definition_id == 1),
  cases_in_labels        = sum(target_labels$target_ecg_afib == 1),
  cases_in_matrix        = sum(final_ml_matrix$target_ecg_afib == 1)
)

# ----------------------------------------------------------------------------
# 16. Persist R output under its own name — never touches final_ml_matrix,
#     so the unmodified SQL script's output stays intact for comparison.
#     insertTable is the DatabaseConnector-native way to do this (dbWriteTable's
#     DBI::Id schema handling isn't guaranteed to work against this connection type).
# ----------------------------------------------------------------------------
insertTable(
  connection        = connection,
  databaseSchema    = "results",
  tableName         = "final_ml_matrix_r",
  data              = final_ml_matrix,
  dropTableIfExists = TRUE,
  createTable       = TRUE,
  tempTable         = FALSE
)

querySql(connection, "
  SELECT table_schema, table_name
  FROM information_schema.tables
  WHERE table_name = 'final_ml_matrix_r';
")

# ----------------------------------------------------------------------------
# 17. Compare against the SQL script's untouched output (main.final_ml_matrix)
# ----------------------------------------------------------------------------
sql_schema <- "main"  # confirm via information_schema.tables if unsure

# int64 option is scoped tightly to this one fetch, then restored — leaving
# it global would silently change how every later query in the session
# handles big integers.
old_opt <- getOption("databaseConnectorInteger64AsNumeric")
options(databaseConnectorInteger64AsNumeric = FALSE)
sql_out <- querySql(connection, sprintf("SELECT * FROM %s.final_ml_matrix;", sql_schema))
options(databaseConnectorInteger64AsNumeric = if (is.null(old_opt)) TRUE else old_opt)

sql_out <- sql_out %>%
  mutate(person_id = as.character(person_id))  # bit64::integer64 -> character, no precision loss

r_out <- querySql(connection, "SELECT * FROM results.final_ml_matrix_r;")

# Row counts
nrow(sql_out); nrow(r_out)

# Column set differences (FeatureExtraction's covariateName formatting vs.
# raw concept_name from the SQL PIVOT may not match 1:1 even after relabeling)
setdiff(names(sql_out), names(r_out))
setdiff(names(r_out), names(sql_out))

# Per-patient label agreement — the core correctness check
comparison <- sql_out %>%
  select(subject_id = person_id, target_sql = target_ecg_afib) %>%
  inner_join(
    r_out %>% select(subject_id, target_r = target_ecg_afib),
    by = "subject_id"
  )

mean(comparison$target_sql == comparison$target_r)  # should be 1.0
comparison %>% filter(target_sql != target_r)         # inspect any mismatches


# Replicating p1_05_cohort_characterization.sql using your final_ml_matrix

# 1. Continuous Metrics (Year of Birth)
yob_metrics <- final_ml_matrix %>%
  summarize(
    variable_role = "Demographics",
    variable_name = "Year of Birth",
    data_type = "Continuous",
    category_value = "N/A",
    metric_mean_or_count = as.character(round(mean(year_of_birth, na.rm = TRUE), 2)),
    metric_sd_or_proportion = as.character(round(sd(year_of_birth, na.rm = TRUE), 2))
  )
# 2. Categorical Metrics (Gender)
total_n <- nrow(final_ml_matrix)

gender_metrics <- final_ml_matrix %>%
  group_by(gender) %>%
  summarize(
    group_count = n(),
    .groups = "drop"
  ) %>%
  mutate(
    variable_role = "Demographics",
    variable_name = "Gender",
    data_type = "Categorical",
    category_value = as.character(gender),
    metric_mean_or_count = as.character(group_count),
    metric_sd_or_proportion = as.character(round((group_count / total_n) * 100, 1))
  ) %>%
  select(variable_role, variable_name, data_type, category_value, 
         metric_mean_or_count, metric_sd_or_proportion)

# 3. Target Metrics (AFib)
target_metrics <- final_ml_matrix %>%
  group_by(target_ecg_afib) %>%
  summarize(
    group_count = n(),
    .groups = "drop"
  ) %>%
  mutate(
    variable_role = "Target / Outcome",
    variable_name = "Atrial Fibrillation (Target)",
    data_type = "Categorical",
    category_value = as.character(target_ecg_afib),
    metric_mean_or_count = as.character(group_count),
    metric_sd_or_proportion = as.character(round((group_count / total_n) * 100, 1))
  ) %>%
  select(variable_role, variable_name, data_type, category_value, 
         metric_mean_or_count, metric_sd_or_proportion)

# Combine them all together (assuming yob_metrics from the previous step is still there)
cohort_characterization <- bind_rows(yob_metrics, gender_metrics, target_metrics)

