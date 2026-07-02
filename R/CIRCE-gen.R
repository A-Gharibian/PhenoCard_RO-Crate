library(CirceR)
library(SqlRender)
library(DatabaseConnector)


# ----------------------------------------------------------------------------
# Hydrate Capr's bare concept stubs (CONCEPT_ID only) using the vocabulary
# already loaded in this CDM's own concept table — keeps exported cohort
# JSON self-contained and version-matched to this database, with no external
# service dependency and no manual per-concept Atlas export step.
# ----------------------------------------------------------------------------
hydrate_concept_json <- function(json_string, connection, vocabularySchema = "main") {
  
  standard_caption <- function(x) {
    dplyr::case_when(
      x == "S" ~ "Standard",
      x == "C" ~ "Classification",
      TRUE     ~ "Non-standard"
    )
  }
  
  invalid_caption <- function(x) {
    dplyr::case_when(
      is.na(x)  ~ NA_character_,   # valid concept -> null, matches ATLAS export
      x == "D"  ~ "Deprecated",
      x == "U"  ~ "Updated",
      TRUE      ~ NA_character_
    )
  }
  
  expr <- jsonlite::fromJSON(json_string, simplifyVector = FALSE)
  
  for (i in seq_along(expr$ConceptSets)) {
    items <- expr$ConceptSets[[i]]$expression$items
    
    for (j in seq_along(items)) {
      cid <- items[[j]]$concept$CONCEPT_ID
      
      # Aliased to uppercase so column names match what's read below —
      # querySql() returns columns exactly as written in the query, it
      # does not auto-uppercase plain SQL the way OHDSI-SQL translation does
      details <- querySql(connection, sprintf(
        "SELECT concept_name       AS CONCEPT_NAME,
                standard_concept   AS STANDARD_CONCEPT,
                invalid_reason     AS INVALID_REASON,
                concept_code       AS CONCEPT_CODE,
                domain_id          AS DOMAIN_ID,
                vocabulary_id      AS VOCABULARY_ID,
                concept_class_id   AS CONCEPT_CLASS_ID
         FROM %s.concept WHERE concept_id = %d;",
        vocabularySchema, cid
      ))
      
      if (nrow(details) == 1) {
        items[[j]]$concept$CONCEPT_NAME             <- details$CONCEPT_NAME
        items[[j]]$concept$STANDARD_CONCEPT          <- ifelse(is.na(details$STANDARD_CONCEPT), "", details$STANDARD_CONCEPT)
        items[[j]]$concept$STANDARD_CONCEPT_CAPTION  <- standard_caption(details$STANDARD_CONCEPT)
        items[[j]]$concept$INVALID_REASON            <- if (is.na(details$INVALID_REASON)) NA else details$INVALID_REASON
        items[[j]]$concept$INVALID_REASON_CAPTION    <- invalid_caption(details$INVALID_REASON)
        items[[j]]$concept$CONCEPT_CODE              <- details$CONCEPT_CODE
        items[[j]]$concept$DOMAIN_ID                 <- details$DOMAIN_ID
        items[[j]]$concept$VOCABULARY_ID              <- details$VOCABULARY_ID
        items[[j]]$concept$CONCEPT_CLASS_ID           <- details$CONCEPT_CLASS_ID
      } else {
        warning(sprintf("Concept ID %d not found in %s.concept — left unhydrated.", cid, vocabularySchema))
      }
    }
    
    expr$ConceptSets[[i]]$expression$items <- items
  }
  
  jsonlite::toJSON(expr, auto_unbox = TRUE, null = "null", pretty = TRUE, na = "null")
}


# ----------------------------------------------------------------------------
# 6. Compile Capr cohorts -> Circe JSON -> OHDSI-SQL
# ----------------------------------------------------------------------------
cases_json    <- as.json(cases_def)
controls_json <- as.json(controls_def)

# Hydrate concept metadata from this CDM's own vocabulary before export
cases_json    <- hydrate_concept_json(cases_json,    connection)
controls_json <- hydrate_concept_json(controls_json, connection)

writeLines(text = cases_json,    con = "AFib_Cases_Cohort.json")
writeLines(text = controls_json, con = "AFib_Controls_Cohort.json")


# ----------------------------------------------------------------------------

cohortDefinitionSet <- tibble::tibble(
  cohortId   = c(1L, 2L),
  cohortName = c("AFib_Cases", "AFib_Controls"),
  json       = c(cases_json, controls_json)
)
# ... rest of your script continues unchanged ...# ============================================================================
# 1. Import the JSON file
# ============================================================================
# Read the physical file back into R as a single string
imported_json <- readLines("AFib_Cases_Cohort.json", warn = FALSE)
imported_json_string <- paste(imported_json, collapse = "")

# ============================================================================
# 2. Validate with circe-be (CirceR)
# ============================================================================
# If this function runs without throwing an error, your JSON is 100% 
# compliant with the official OHDSI CIRCE standard.
parsed_expression <- CirceR::cohortExpressionFromJson(imported_json_string)

# ============================================================================
# 3. Compile to OHDSI-SQL
# ============================================================================
# This proves that the rules in your JSON can be successfully 
# translated into database code.
cohort_sql <- CirceR::buildCohortQuery(
  parsed_expression,
  options = CirceR::createGenerateOptions(generateStats = FALSE)
)

