# PhenoCard_RO-Crate

### Overview
This repository contains R scripts to create the RO-crate of a cluster PhenoCard: To evaluate the data quality of a dataset that has been mapped to the OMOP Common Data Model (CDM), to define the CIRCE rules of exporting the dataset, and to package everything in an RO-crate using a PhenoCard JSON.

### Database
The target database is a local DuckDB file and the default `main` schema contains tables of the demo dataset (e.g., `person`, `condition_occurrence`, `visit_occurrence`). The DQD package evaluates data by executing hardcoded SQL queries that specifically target standard OMOP table names.

### Prerequisites
To run this script, ensure the following are installed and configured:
* **R / RStudio**
* **Java Development Kit (JDK):** The OHDSI `DatabaseConnector` relies on Java. Ensure `JAVA_HOME` is set and `R CMD javareconf` has been run for this R installation.
* **Rtools (Windows only):** Several packages (`Capr`, `DataQualityDashboard`, `rJava`) build from source and require a C/C++ compiler toolchain.
  * Install the version matching your R release from [cran.r-project.org/bin/windows/Rtools](https://cran.r-project.org/bin/windows/Rtools/).
  * **If installed to the default path**, no further action is needed.
  * **If installed to a non-default path** (e.g. `C:\Apps\rtools45` instead of `C:\rtools45`), add it manually via `usethis::edit_r_environ()`.
  * Restart R fully after editing, then verify with `Sys.which("make")`.
  * Verify the full toolchain is detected with `pkgbuild::check_build_tools(debug = TRUE)`.
* **Target Database:** Ensure the database file is accessible.

### Environment Setup
Package installation and version locking are handled by `setup.R`, which uses [`renv`](https://rstudio.github.io/renv/) for reproducibility. To set up the environment from a fresh clone:
```r
source("setup.R")
```
This installs all required CRAN and GitHub-only packages (see script comments for which is which) and produces `renv.lock`. On subsequent runs / other machines, use `renv::restore()` instead of rerunning `setup.R`, to install the exact locked versions rather than the latest ones.

### Script Breakdown

#### Parameter Definition
* **`cdmDatabaseSchema`**: Set to `"main"`, directing the tool to the schema containing the clinical OMOP tables.
* **`vocabDatabaseSchema`**: Defaults to the `cdmDatabaseSchema` (`"main"`), where the OMOP concept tables are also stored.
* **`resultsDatabaseSchema`**: Set to `"main"`, acting as the scratchpad for any temporary tables the DQD needs to write during execution.
* **`cdmSourceName`**: Set to `"MIMIC_IV_Demo_100"`. This string is used to name the final output JSON file.
* **`outputFolder`**: Defines the local directory where the final JSON results will be saved.

### How to Use
1. Verify that the file paths for `JAVA_HOME`, `connectionDetails`, and `outputFolder` match your current local environment.
2. Run the script from top to bottom.
3. Wait for the execution to finish (time will vary depending on dataset size). The interactive dashboard will automatically open in your default web browser once completed.

The script depends on the following [OHDSI](https://www.ohdsi.org/) HADES packages:

- [DatabaseConnector](https://github.com/OHDSI/DatabaseConnector)
- [SqlRender](https://github.com/OHDSI/SqlRender)
- [Capr](https://github.com/OHDSI/Capr)
- [CirceR](https://github.com/OHDSI/CirceR)
- [CohortGenerator](https://github.com/OHDSI/CohortGenerator)
- [FeatureExtraction](https://github.com/OHDSI/FeatureExtraction)
- [DataQualityDashboard (DQD)](https://github.com/OHDSI/DataQualityDashboard)
