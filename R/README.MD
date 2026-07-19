# R Pipeline

This folder contains the R port of the SQL cohort construction and feature extraction pipeline (https://github.com/A-Gharibian/PhenoCard_Portability), plus the supporting data quality and cohort export steps.

The pipeline builds an OHDSI-standard case/control cohort from a MIMIC-IV OMOP CDM database using Capr, CirceR, CohortGenerator and FeatureExtraction, targeting a DuckDB backend. The atrial fibrillation (AFib) case/control example is a technical demonstration of the workflow and is **not** intended to define or recommend a clinically validated phenotype.

The implementation is a OHDSI-native *port* of a DuckDB SQL implementation of the same cohort construction and feature extraction logic. The concepts correspond, and agreement is verified empirically at the end of the run (see [Validation](#validation)).

## Before you start

These scripts are **not** intended to run unmodified from a fresh clone. Database paths, `JAVA_HOME` and output folders are environment-specific and must be set for your own system before anything will execute. There is no bundled database and no default that resolves anywhere useful.

## Files

| File | Role |
|------|------|
| `Setup.R` | One-time environment setup: renv, CRAN and GitHub packages, Java, version checks. Run once per machine. |
| `SQL reproduction.R` | The main pipeline. Builds the cohorts, extracts covariates, writes `results.final_ml_matrix_r`, and compares it against the SQL implementation's output. |
| `Aggregate-gen.R` | Defines `generate_aggregate_profile()`, which builds the aggregate profile carried by the crate. Called from step 19; not standalone. |
| `CIRCE-gen.R` | Exports fully hydrated, CIRCE-compliant cohort definition JSON for ATLAS and for archival in the RO-Crate. |
| `DQA_gen.R` | Runs the OHDSI Data Quality Dashboard against the CDM and opens the resulting HTML report. |

`PhenoCard2Crate.R` lives at the repository root, not here, because it packages the whole crate rather than forming part of the R pipeline.

### Run order

`Setup.R` runs once. `DQA_gen.R` is independent and can run at any point. `CIRCE-gen.R` is **not** standalone: it depends on `cases_def`, `controls_def` and an open `connection` created by `SQL reproduction.R`, so it must be run after that script has reached at least step 5, in the same session.

`Aggregate-gen.R` only defines a function and touches no database, but step 19 calls it, so it must be sourced before `SQL reproduction.R` reaches that point.

`CIRCE-gen.R` writes its JSON files to the current working directory, and `PhenoCard2Crate.R` discovers cohort definitions by scanning its working directory for files matching `Cohort\.json$`. If you intend the exported cohorts to end up in the crate, run `CIRCE-gen.R` with the working directory set to the crate root rather than to this folder.

## Requirements

- R packages: `DatabaseConnector`, `CohortGenerator`, `Capr`, `CirceR`, `SqlRender` (>= 1.19.5), `FeatureExtraction`, `jsonlite`, `dplyr`, `tidyr`, `tibble`
- A JDK. `DatabaseConnector` and `CirceR` are both Java-backed; `JAVA_HOME` must be set and `R CMD javareconf` run for this R installation.
- DuckDB database file containing an OMOP CDM (`main` schema)
- SqlRender >= 1.19.5 is required for correct DuckDB translation of `ALTER TABLE` statements and nested date expressions. `Setup.R` warns if an older version resolves.

`CirceR` has no CRAN release and is installed from GitHub (`ohdsi/CirceR`) by `Setup.R`, together with `Capr` and `DataQualityDashboard`.

## Database Layout

A single DuckDB database containing two schemas:

| Schema | Purpose |
|--------|---------|
| `main` | OMOP CDM tables and the original SQL pipeline output (`final_ml_matrix`), preserved without modification |
| `results` | All R pipeline output, including cohort tables, row identifier mappings, FeatureExtraction working tables, and `final_ml_matrix_r` |

The `results` schema is created automatically if it does not already exist.

---

# SQL reproduction.R

## Cohort Definitions

### Cohort 1 — AFib Cases

**Entry criterion:** first `condition_occurrence` of Atrial Fibrillation (concept `4068155` and descendants).

### Cohort 2 — AFib Controls

**Entry criterion:** last `visit_occurrence`.

**Attrition criterion:** excludes any individual with an AFib `condition_occurrence` anywhere in their recorded history (`eventStarts(-Inf, Inf)`), matching the original SQL pipeline's global exclusion logic:

```sql
NOT IN (SELECT person_id FROM target_patients)
```

Cases and controls are anchored differently by construction — cases at first diagnosis, controls at last visit. This asymmetry is inherited deliberately from the SQL implementation, where it is documented as a known limitation.

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
18. Reproduce the SQL pipeline's `p1_05_cohort_characterization.sql` summary in R, producing `cohort_characterization`: year-of-birth mean and SD, gender counts and proportions, and target counts and proportions. This is an in-memory tibble and is not written back to the database.
19. Call `generate_aggregate_profile()` from `Aggregate-gen.R` to build the aggregate profile carried by the crate, and write it to `dataset_aggregate_profile.json`. This covers the same demographics as step 18 plus every `condition_*` and `measurement_*` feature, reported for the whole cohort and for each arm. Both metric columns are overloaded, so each record declares its own units — proportions are fractions in `[0, 1]`, never percentages. Step 18's `cohort_characterization` keeps its percentage-as-character format, which mirrors the SQL it reproduces; the two artifacts are not interchangeable.

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
- Column-set differences
- Per-patient `target_ecg_afib` agreement

The current implementation demonstrates **100% agreement** for the target label across all patients.

Column names are not expected to match one-for-one: FeatureExtraction's `covariateName` formatting differs from the raw `concept_name` used by the SQL `PIVOT`, so the `setdiff()` checks are informational rather than pass/fail. Per-patient label agreement is the correctness check.

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
3. Writes the hydrated cohort definitions to `AFib_Cases_Cohort.json` and `AFib_Controls_Cohort.json` in the current working directory.
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

Run after defining the Capr cohort objects, in the same session:

```r
source("CIRCE-gen.R")
```

The script exports the hydrated CIRCE JSON files into the working directory.

## Notes

- `querySql()` preserves SQL column names exactly as written. The hydration query aliases all returned columns using uppercase names to match the expected CIRCE JSON structure.
- If query aliases do not match the expected field names, hydration may silently produce empty metadata fields. It is good practice to verify `CONCEPT_NAME` in the exported JSON after modifying the query.
- `vocabularySchema` defaults to `"main"` and should be changed if vocabulary tables are stored elsewhere.
- Concepts not found in the OMOP vocabulary remain unhydrated and generate an R warning rather than terminating the script.
- A blank `STANDARD_CONCEPT` value may legitimately indicate a non-standard concept rather than a hydration failure.
- This script reassigns `cohortDefinitionSet`. The copy it creates carries the hydrated `json` column but no `sql` column, so if you intend to call `generateCohortSet()` afterwards, rebuild the `sql` column first (step 6 of `SQL reproduction.R`).

---

# DQA_gen.R

Runs the OHDSI [Data Quality Dashboard](https://github.com/OHDSI/DataQualityDashboard) against the CDM and opens the resulting interactive report.

DQD executes a large set of hardcoded SQL checks that target standard OMOP table names, so the CDM tables must be present under `cdmDatabaseSchema` with their canonical names.

## Parameters

| Parameter | Value in script | Purpose |
|-----------|-----------------|---------|
| `JAVA_HOME` | placeholder | JDK location required by `DatabaseConnector`. |
| `connectionDetails$server` | placeholder | Path to the DuckDB CDM file. |
| `cdmDatabaseSchema` | `"main"` | Schema holding the clinical OMOP tables. |
| `resultsDatabaseSchema` | `"main"` | Scratch space for the temporary tables DQD writes during execution. |
| `cdmSourceName` | `"MIMIC_IV_Demo_100"` | Label for the run; also used to name the output JSON. |
| `outputFolder` | placeholder | Directory for the JSON results and HTML dashboard. |

The placeholder values must be set to real local paths before the script will run.

## Output

`executeDqChecks()` returns the path to the results JSON, which is passed to `viewDqDashboard()` to open the report in a browser (requires `shiny`). That JSON is the artifact referenced by the PhenoCard as `dqa_reference` when the crate is built.

---

## Planned work

The pipeline is intended to produce two PhenoCards:

1. **OMOP demo cohort (100 patients)** — clearly defined and used as the reference. Not matched; it is the target that the second cohort is matched *to*.
2. **MIMIC-IV matched subset** — drawn from a randomly sampled 10,000-patient pool and reduced to the patients comparable to the reference cohort.

Two additions support this:

- **Aggregate profile via `FeatureExtraction`.** Produce the demographic and clinical profile from HADES aggregated covariate support rather than bespoke summarisation. This is an addition, not a replacement: the manual generator (step 18) is retained deliberately so the pipeline remains usable without the HADES dependency chain.
- **Propensity score matching via `CohortMethod`.** Selection of the comparable MIMIC subset is currently done with hand-written SQL filters. Moving it to `CohortMethod` replaces bespoke filtering with the standard OHDSI propensity score workflow, which is the point of the exercise — the matching step is the part the raw SQL implementation could not express.

Outcome cohorts apply only to the MIMIC stage, where the patient count supports them. The 100-patient demo serves as the reference cohort and is not itself matched.
