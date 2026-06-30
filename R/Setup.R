# setup.R

# 1. renv first — must exist before init/status are callable
if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")
renv::init(bare = TRUE)

# 2. Repos and pak
options(repos = c(CRAN = "https://cloud.r-project.org"))
if (!requireNamespace("pak", quietly = TRUE)) install.packages("pak")

# 3. CRAN packages
pak::pak(c(
  "CDMConnector",
  "CohortConstructor",
  "PhenotypeR",
  "CodelistGenerator",
  "CirceR",
  "FeatureExtraction",
  "DatabaseConnector",
  "duckdb",
  "DBI",
  "dplyr",
  "jsonlite",
  "rocrateR",
  "remotes",
  "rJava",
  "drat"
))

# NOTE: packages below build from source. Rtools must be installed AND on
# PATH before this step, verify with Sys.which("make") and check .Renviron
# pkgbuild::check_build_tools(debug = TRUE)

# 4. GitHub-only packages (no CRAN release exists)
pak::pak(c(
  "ohdsi/Capr",
  "ohdsi/DataQualityDashboard"
))

# 5. Java is a SYSTEM dependency — renv/pak can't lock this for you.
system("R CMD javareconf")
library(rJava)
.jinit()

# 6. Confirm everything resolved cleanly before locking it in
renv::status()

# 7. Only snapshot once status() is clean
renv::snapshot()
