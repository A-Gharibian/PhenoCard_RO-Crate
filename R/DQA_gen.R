# --- 1. Set Java environment ---
# JDK required by DatabaseConnector.
Sys.setenv(JAVA_HOME = "/path/to/your/jdk")

# --- 2. LOAD LIBRARIES ---
library(DatabaseConnector)
library(DataQualityDashboard)

# --- 3. CONFIGURE DATABASE CONNECTION ---
# Point this to your DuckDB CDM file
connectionDetails <- createConnectionDetails(
  dbms = "duckdb",
  server = "/path/to/your/cdm.db"
)

# --- 4. DEFINE PARAMETERS ---
cdmDatabaseSchema <- "main"       # DuckDB default schema
resultsDatabaseSchema <- "main"   # Where DQD writes temporary results
cdmSourceName <- "MIMIC_IV_Demo_100"

# Folder to store the final HTML dashboard
outputFolder <- "/path/to/your/dqd_results"
dir.create(outputFolder, showWarnings = FALSE)

# --- 5. EXECUTE THE DASHBOARD CHECKS ---
dqdJsonPath <- DataQualityDashboard::executeDqChecks(
  connectionDetails = connectionDetails,
  cdmDatabaseSchema = cdmDatabaseSchema,
  resultsDatabaseSchema = resultsDatabaseSchema,
  cdmSourceName = cdmSourceName,
  outputFolder = outputFolder
)

# --- 6. VIEW THE DASHBOARD ---
# Opens the interactive DQD UI in your web browser (req. shiny)
DataQualityDashboard::viewDqDashboard(jsonPath = dqdJsonPath)
