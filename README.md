# PhenoCard_RO-Crate

### Overview
This repository contains R scripts to create the RO-Crate of a cluster PhenoCard: to evaluate the data quality of a dataset that has been mapped to the OMOP Common Data Model (CDM), to define the CIRCE rules of exporting the dataset, and to package everything in an RO-Crate using a PhenoCard JSON.

> **These scripts are not intended to run unmodified from a fresh clone or a downloaded archive.**
> Database paths, `JAVA_HOME` and output folders are environment-specific and must be configured for your own system first. No database is bundled, and no default path resolves anywhere useful.

### Repository Layout

| Path | Purpose |
|------|---------|
| `R/Setup.R` | One-time environment setup: `renv`, CRAN and GitHub packages, Java, version checks. |
| `R/SQL reproduction.R` | Main cohort construction and feature extraction pipeline (Capr → CirceR → CohortGenerator → FeatureExtraction). |
| `R/Aggregate-gen.R` | Builds the aggregate profile carried by the crate: marginal summaries of every patient and feature. |
| `R/CIRCE-gen.R` | Exports CIRCE-compliant cohort definition JSON. |
| `R/DQA_gen.R` | Runs the OHDSI Data Quality Dashboard against the exported cohort. |
| `PhenoCard2Crate.R` | Reads a PhenoCard JSON-LD file, generates MINIMAR reporting markdown, and writes the RO-Crate metadata and packages it. |

See [`R/README.md`](R/README.md) for detailed documentation of the four pipeline scripts, including run order and inter-script dependencies.

### Database
The target database is a local DuckDB file whose default `main` schema contains the tables of the demo dataset (e.g. `person`, `condition_occurrence`, `visit_occurrence`). The DQD package evaluates data by executing hardcoded SQL queries that specifically target standard OMOP table names.

### Prerequisites
To run these scripts, ensure the following are installed and configured:
* **R / RStudio**
* **Java Development Kit (JDK):** The OHDSI `DatabaseConnector` and `CirceR` both rely on Java. Ensure `JAVA_HOME` is set and `R CMD javareconf` has been run for this R installation.
* **Rtools (Windows only):** Several packages (`Capr`, `CirceR`, `DataQualityDashboard`, `rJava`) build from source and require a C/C++ compiler toolchain.
  * Install the version matching your R release from [cran.r-project.org/bin/windows/Rtools](https://cran.r-project.org/bin/windows/Rtools/).
  * **If installed to the default path**, no further action is needed.
  * **If installed to a non-default path** (e.g. `D:\rtools45` instead of `C:\rtools45`), add it manually via `usethis::edit_r_environ()`.
  * Restart R fully after editing, then verify with `Sys.which("make")`.
  * Verify the full toolchain is detected with `pkgbuild::check_build_tools(debug = TRUE)`.
* **Target Database:** Ensure the database file is accessible.

### Environment Setup
Package installation and version locking are handled by `R/Setup.R`, which uses [`renv`](https://rstudio.github.io/renv/) for reproducibility. To set up the environment from a fresh clone:
```r
source("R/Setup.R")
```
This installs the required CRAN packages and the OHDSI packages that have no CRAN release (`CirceR`, `Capr`, `DataQualityDashboard`, installed from GitHub). The `renv.lock` it produces is local to your machine and is not distributed with this repository.

Note that `renv::init()` restarts the R session under RStudio. If that happens, re-source the file — it resumes from the package installation step.

### Data Quality Assessment — `R/DQA_gen.R`

#### Parameter Definition
* **`JAVA_HOME`**: JDK location required by `DatabaseConnector`. Placeholder — set to your local JDK.
* **`connectionDetails$server`**: Path to the DuckDB CDM file. Placeholder — set to your local database.
* **`cdmDatabaseSchema`**: Set to `"main"`, directing the tool to the schema containing the clinical OMOP tables.
* **`resultsDatabaseSchema`**: Set to `"main"`, acting as the scratchpad for any temporary tables the DQD needs to write during execution.
* **`cdmSourceName`**: Set to `"MIMIC_IV_Demo_100"`. This string is used to name the final output JSON file.
* **`outputFolder`**: Defines the local directory where the final JSON results will be saved. Placeholder.

#### How to Use
1. Set the placeholder paths for `JAVA_HOME`, `connectionDetails` and `outputFolder` to match your local environment.
2. Run the script from top to bottom.
3. Wait for the execution to finish (time will vary depending on dataset size). The interactive dashboard will open in your default web browser once completed.

The resulting JSON is the artifact referenced by the PhenoCard as `dqa_reference` when the crate is built.

### Building the Crate — `PhenoCard2Crate.R`

Run from the root of the RO-Crate directory — the folder containing the PhenoCard JSON-LD file and every file it references (DQA results, aggregate profiles, cohort definitions, viewer HTML, README). All paths resolve relative to the current working directory; filenames can be overridden through the `PHENOCARD_FILENAME`, `PHENOCARD_VIEWER_HTML` and `PHENOCARD_README` environment variables.

The script registers referenced files, generates a MINIMAR reporting checklist in markdown for each profile, writes `ro-crate-metadata.json`, and produces a BagIt package. Cohort definitions are discovered by scanning the working directory for filenames ending in `Cohort.json`, so `R/CIRCE-gen.R` must have been run with its working directory set to the crate root for its exports to be picked up.

### Planned work

The pipeline is intended to produce two PhenoCards: the OMOP demo cohort, which acts as the clearly defined reference, and a MIMIC-IV subset matched to it from a randomly sampled 10,000-patient pool.

Supporting this are an aggregate profile built from `FeatureExtraction`'s aggregated covariate support, added alongside the existing manual generator rather than replacing it, and propensity score matching via `CohortMethod` in place of the hand-written SQL filters currently used to select the comparable subset. See [`R/README.md`](R/README.md) for detail.

### Dependencies

The scripts depend on the following [OHDSI](https://www.ohdsi.org/) HADES packages:

- [DatabaseConnector](https://github.com/OHDSI/DatabaseConnector)
- [SqlRender](https://github.com/OHDSI/SqlRender)
- [Capr](https://github.com/OHDSI/Capr)
- [CirceR](https://github.com/OHDSI/CirceR)
- [CohortGenerator](https://github.com/OHDSI/CohortGenerator)
- [FeatureExtraction](https://github.com/OHDSI/FeatureExtraction)
- [DataQualityDashboard (DQD)](https://github.com/OHDSI/DataQualityDashboard)
