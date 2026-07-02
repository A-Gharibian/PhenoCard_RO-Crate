# OHDSI Cohort Construction and Feature Extraction Pipeline

Builds an OHDSI-standard case/control cohort from a MIMIC-IV OMOP CDM database using Capr, CirceR, CohortGenerator, and FeatureExtraction, targeting a DuckDB backend. The repository demonstrates an end-to-end OHDSI workflow using an atrial fibrillation (AFib) case/control example. The included cohort definitions are intended solely as a technical demonstration of the pipeline and are **not** intended to define or recommend a clinically validated phenotype.

The implementation has been validated against an independent, hand-written DuckDB SQL implementation of the same cohort construction and feature extraction logic.

## Requirements

- R packages: `DatabaseConnector`, `CohortGenerator`, `Capr`, `SqlRender` (>= 1.19.5), `jsonlite`, `dplyr`, `FeatureExtraction`, `tidyr`, `tibble`
- DuckDB database file containing an OMOP CDM (`main` schema)
- SqlRender >= 1.19.5 is required for correct DuckDB translation of `ALTER TABLE` statements and nested date expressions.

## Database Layout

A single DuckDB database containing two schemas:

| Schema | Purpose |
|--------|---------|
| `main` | OMOP CDM tables and the original SQL pipeline output (`final_ml_matrix`), preserved without modification |
| `results` | All R pipeline output, including cohort tables, row identifier mappings, FeatureExtraction working tables, and `final_ml_matrix_r` |

The `results` schema is created automatically if it does not already exist.

## Cohort Definitions

### Cohort 1 — AFib Cases

**Entry criterion:** first `condition_occurrence` of Atrial Fibrillation (concept `4068155` and descendants).

### Cohort 2 — AFib Controls

**Entry criterion:** last `visit_occurrence`.

**Attrition criterion:** excludes any individual with an AFib `condition_occurrence` anywhere in their recorded history (`eventStarts(-Inf, Inf)`), matching the original SQL pipeline's global exclusion logic:

```sql
NOT IN (SELECT person_id FROM target_patients)
```

## Pipeline Steps

1. Connect to the DuckDB CDM database and create the `results` schema if required.
2. Verify that the AFib concept resolves correctly in the OMOP vocabulary.
3. Define the AFib concept set (including descendants).
4. Define the case cohort using Capr.
5. Define the control cohort using Capr, applying the global AFib exclusion criterion.
6. Compile both cohort definitions to CIRCE JSON (`as.json()`), then translate them to OHDSI SQL using `CirceR::buildCohortQuery()`.
7. Create cohort tables and generate both cohorts using `CohortGenerator`.
8. Retrieve generated cohort assignments and construct the binary machine learning target label (`target_ecg_afib`).
9. Generate a surrogate `row_id` mapping (small sequential integer per patient) together with a remapped cohort table for FeatureExtraction, avoiding 64-bit integer precision loss in `getDbCovariateData()`.
10. Define covariate settings, replacing the SQL pipeline's `tall_features` step:
    - `useConditionOccurrenceAnyTimePrior` (analysis ID 101): binary condition flags occurring any time on or before the index date.
    - `useMeasurementValueAnyTimePrior` (analysis ID 705): most recent numeric measurement value on or before the index date.
    - Exclude the AFib concept (and descendants) from candidate covariates to prevent target leakage, matching the SQL pipeline's `concept_ancestor` exclusion join.
11. Extract covariates for both cohorts using `getDbCovariateData()`, removing any orphaned temporary tables from previous interrupted runs.
12. Pivot covariates from long to wide format, relabel features using the analysis identifiers (`condition_*` and `measurement_*`), and restore the original precision-safe `subject_id` through the row identifier mapping.
13. Retrieve demographic variables (`year_of_birth` and `gender`) directly from the `person` table.
14. Assemble `final_ml_matrix`, combining the target label, demographic variables, and extracted covariates, with missing feature values filled with `0`.
15. Perform validation checks to confirm that case counts agree across `patient_index`, `target_labels`, and the final feature matrix.
16. Persist the R pipeline output as `results.final_ml_matrix_r` using `insertTable()`. The original SQL pipeline output (`main.final_ml_matrix`) is never modified.
17. Compare `results.final_ml_matrix_r` against `main.final_ml_matrix`, including row counts, column-set differences, and per-patient target label agreement.

## Output

`results.final_ml_matrix_r` contains one row per patient.

| Column | Type | Description |
|--------|------|-------------|
| `subject_id` | character | Patient identifier (stored as character to preserve 64-bit precision) |
| `index_date` | Date | Cohort start date (AFib diagnosis or last visit) |
| `target_ecg_afib` | integer | `1` = AFib case, `0` = control |
| `year_of_birth` | integer | Retrieved from `person` |
| `gender` | character | Retrieved from `person` / `concept` |
| `condition_*` | numeric (0/1) | Binary indicators for prior conditions |
| `measurement_*` | numeric | Most recent measurement value before the index date |

## Validation

Step 17 compares the R pipeline output directly against the independently implemented SQL pipeline, verifying:

- Row counts
- Column-set parity (aside from the expected `subject_id` / `person_id` naming difference)
- Per-patient `target_ecg_afib` agreement

The current implementation demonstrates **100% agreement** for the target label across all patients.

## Implementation Notes

- `subject_id` is stored as `VARCHAR` throughout the cohort generation and feature extraction workflow. MIMIC-OMOP surrogate identifiers exceed the safe IEEE-754 integer range and may also be negative due to signed 64-bit hash overflow; therefore, they must never be coerced to numeric values.
- FeatureExtraction requires a double-safe row identifier. A temporary surrogate `row_id` mapping (`*_rowmap`) is used internally and joined back to recover the original `subject_id` before constructing the final output.
- Analysis identifiers used in `case_when()` feature relabeling are verified against the FeatureExtraction source (`101 = ConditionOccurrenceAnyTimePrior`, `705 = MeasurementValueAnyTimePrior`). These identifiers should be revalidated whenever covariate settings are modified.
- CIRCE JSON generated for each cohort is retained in `cohortDefinitionSet$json` and may be imported directly into OHDSI ATLAS or archived for reproducibility.
- SQL generated by CirceR remains dialect-neutral OHDSI SQL. DuckDB-specific translation is performed automatically within `CohortGenerator::generateCohortSet()` via SqlRender.
- The `databaseConnectorInteger64AsNumeric` option is modified only locally during the Step 17 comparison and immediately restored afterwards; it is never left as a global session setting.

---

# CIRCE-gen.R

`CIRCE-gen.R` generates fully hydrated, CIRCE-compliant cohort definition JSON files from the Capr cohort objects (`cases_def` and `controls_def`).

## What it does

1. Converts the Capr cohort definitions to raw CIRCE JSON using `as.json()`.
2. Hydrates the concept definitions by querying the local OMOP `concept` table. Capr populates only `CONCEPT_ID`; all descriptive fields (`CONCEPT_NAME`, `VOCABULARY_ID`, `DOMAIN_ID`, etc.) are completed during this step.
3. Writes the hydrated cohort definitions to `AFib_Cases_Cohort.json` and `AFib_Controls_Cohort.json`.
4. Validates the exported JSON by round-tripping it through `CirceR::cohortExpressionFromJson()` and `CirceR::buildCohortQuery()`, confirming that the generated JSON remains CIRCE compliant and translatable to OHDSI SQL.

## Why hydration is needed

Capr intentionally produces minimal but valid CIRCE JSON. Although sufficient for SQL generation, the exported JSON omits descriptive concept metadata. Hydration enriches each concept using the OMOP vocabulary, producing self-contained cohort definitions suitable for:

- OHDSI ATLAS
- study reproducibility
- long-term archival
- human inspection

## Requirements

- An active `DatabaseConnector::connect()` connection.
- An OMOP vocabulary containing the standard `concept` table.
- Previously defined `cases_def` and `controls_def`.
- Packages: `CirceR`, `SqlRender`, `DatabaseConnector`, `jsonlite`, and `dplyr`.

## Usage

Run after defining the Capr cohort objects:

```r
source("CIRCE-gen.R")
```

The script exports fully hydrated CIRCE JSON files into the working directory.

## Notes

- `querySql()` preserves SQL column names exactly as written. The hydration query aliases all returned columns using uppercase names to match the expected CIRCE JSON structure.
- If query aliases do not match the expected field names, hydration may silently produce empty metadata fields. It is good practice to verify `CONCEPT_NAME` in the exported JSON after modifying the query.
- `vocabularySchema` defaults to `"main"` and should be changed if vocabulary tables are stored elsewhere.
- Concepts not found in the OMOP vocabulary remain unhydrated and generate an R warning rather than terminating the script.
- A blank `STANDARD_CONCEPT` value may legitimately indicate a non-standard concept rather than a hydration failure.
