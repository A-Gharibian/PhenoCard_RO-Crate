# PhenoCard_RO-Crate

### Overview
This repository contains R scripts to create the RO-crate of a cluster PhenoCard: To evaluate the data quality of a dataset that has been mapped to the OMOP Common Data Model (CDM), to define the Circe-Be rules of exporting the dataset, and to package everything in an RO-crate using a PhenoCard JSON.

### Database
The target database is a local DuckDB file (`MIMIC-omop.db`) and the default `main` schema contains tables of the demo dataset (e.g., `person`, `condition_occurrence`, `visit_occurrence`). The DQD package evaluates data by executing hardcoded SQL queries that specifically target standard OMOP table names.

### Prerequisites
To run this script, ensure the following are installed and configured:
* **R / RStudio**
* **Java Development Kit (JDK):** The OHDSI `DatabaseConnector` relies on Java.
* **Target Database:** Ensure the database file is accessible.

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

The script depends on the [OHDSI DataQualityDashboard (DQD)](https://github.com/OHDSI/DataQualityDashboard) package.
