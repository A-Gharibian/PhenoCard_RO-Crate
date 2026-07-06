# phenocard_to_rocrate.R
# Reads a PhenoCard JSON-LD file, packages the Profiles
# and related files, and writes an RO-Crate metadata + BagIt package.
#
# Run this script from the root of the RO-Crate directory — the folder
# containing the PhenoCard JSON-LD file and all files it references
# (DQA results, aggregate profiles, cohort definitions, viewer HTML, README).
# All paths are resolved relative to the current working directory;
# override via environment variables if the filenames differ.

library(jsonlite)
library(rocrateR)

# ── Configuration ─────────────────────────────────────────────────────────────

PHENOCARD_PATH       <- getwd()
OUTPUT_DIR           <- PHENOCARD_PATH
PHENOCARD_FILENAME   <- Sys.getenv("PHENOCARD_FILENAME", "OMOP_cluster_phenotype.json")
VIEWER_HTML_FILENAME <- Sys.getenv("PHENOCARD_VIEWER_HTML", "PhenoCard_Graphology_OMOP.html")
README_FILENAME      <- Sys.getenv("PHENOCARD_README", "README.md")

PHENOCARD   <- file.path(PHENOCARD_PATH, PHENOCARD_FILENAME)
OUTPUT_PATH <- file.path(OUTPUT_DIR, "ro-crate-metadata.json")

STAGING_DIR    <- file.path(OUTPUT_DIR, "_rocrate_staging")
BAG_OUTPUT_DIR <- file.path(OUTPUT_DIR, "_rocrate_bag_output")

# ── Helpers ──────────────────────────────────────────────────────────────────

safe <- function(x) {
  if (is.null(x) || identical(x, "") || identical(x, "null")) NULL else x
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

# Normalize date strings to ISO 8601 YYYY-MM-DD
normalise_date <- function(x) {
  if (is.null(x)) return(NULL)
  # Already ISO 8601 datetime — truncate to date part
  if (grepl("^\\d{4}-\\d{2}-\\d{2}", x)) return(sub("T.*$", "", x))
  # DD.MM.YYYY → YYYY-MM-DD
  if (grepl("^\\d{2}\\.\\d{2}\\.\\d{4}$", x)) {
    parts <- strsplit(x, "\\.")[[1]]
    return(paste(parts[3], parts[2], parts[1], sep = "-"))
  }
  x
}

# Build the MINIMAR reporting markdown content for a single profile.
build_minimar_content <- function(pc, profile_id, cohort_files) {
  prof <- pc$profiles[[profile_id]]
  alg  <- prof$algorithmic_config
  gm   <- pc$global_metadata
  dm   <- pc$dataset_metadata
  
  # 1. Existence Checks
  has_circe    <- length(cohort_files) > 0
  has_semantic <- !is.null(safe(gm$semantic_summary))
  
  # 2. Extract Demographics from the inline aggregate profile
  inline_agg <- dm$inline_aggregate_profile
  age_info   <- "Not provided."
  sex_info   <- "Not provided."
  
  if (!is.null(inline_agg)) {
    # Find Age
    age_item <- Filter(function(x) identical(x$variable_name, "Age"), inline_agg)
    if (length(age_item) > 0) {
      m  <- age_item[[1]]$metric_mean_or_count
      sd <- age_item[[1]]$metric_sd_or_proportion
      age_info <- if (identical(m, 0) && identical(sd, 0)) {
        "Not available (age de-identified/obfuscated in source data)."
      } else {
        paste0("Mean: ", m, ", SD: \u00B1", sd)
      }
    }
    
    # Find Sex/Gender
    sex_items <- Filter(function(x) identical(x$variable_name, "Gender") || identical(x$variable_name, "Sex"), inline_agg)
    if (length(sex_items) > 0) {
      sex_info <- paste(sapply(sex_items, function(x) {
        paste0(x$category_value, ": N=", x$metric_mean_or_count,
               " (", round(x$metric_sd_or_proportion * 100, 1), "%)")
      }), collapse = " | ")
    }
  }
  
  # 3. Draft the Markdown Content
  c(
    paste("# MINIMAR Reporting Checklist: Profile", profile_id),
    "",
    "## 1. Study and Data Source",
    paste("- **Population:**", ifelse(has_circe, "Defined via attached Circe cohort rules.", "Not explicitly provided.")),
    paste("- **Study Setting:**", ifelse(has_semantic, gm$semantic_summary, "Not provided.")),
    paste("- **Data Source:**", ifelse(has_semantic, gm$semantic_summary, "Not provided.")),
    paste("- **Cohort Selection:**", ifelse(has_circe, "Inclusion/Exclusion defined via attached Circe cohort rules.", "Not provided.")),
    "",
    "## 2. Demographic Characteristics",
    paste("- **Age:**", age_info),
    paste("- **Sex:**", sex_info),
    "- **Race:** Not provided in this dataset.",
    "- **Ethnicity:** Not provided in this dataset.",
    "- **Socioeconomic Status:** Not provided in this dataset.",
    "",
    "## 3. Algorithmic Configuration",
    paste("- **Model Type/Architecture:**", safe(alg$base_model) %||% "Not provided."),
    paste("- **Optimization Procedure:**", safe(alg$method_family) %||% "Not provided."),
    paste("- **Confidence Threshold:**", safe(alg$confidence_threshold) %||% "Not provided."),
    paste("- **Missing Data Strategy:**", safe(alg$data_preprocessing$missing_data_strategy) %||% "Not provided."),
    paste("- **Scaling Method:**", safe(alg$data_preprocessing$scaling_method) %||% "Not provided."),
    "",
    "## 4. Performance & Validation",
    "- **Validation Approach:** [Manual entry required]",
    "- **Overall Performance Metrics:** [Manual entry required]",
    "- **Subgroup Performance Metrics:** Detailed per cluster in the PhenoCard."
  )
}


generate_minimar_md <- function(pc, profile_id, cohort_files, output_dir) {
  alg <- pc$profiles[[profile_id]]$algorithmic_config
  
  file_name <- if (!is.null(safe(alg$minimar_reference))) {
    sub("\\.json$", ".md", alg$minimar_reference, ignore.case = TRUE)
  } else {
    paste0("minimar_", profile_id, ".md")
  }
  
  out_path <- file.path(output_dir, file_name)
  md_lines <- build_minimar_content(pc, profile_id, cohort_files)
  
  writeLines(md_lines, out_path)
  message("  Generated MINIMAR markdown: ", file_name)
  
  file_name
}

# ── Load PhenoCard ───────────────────────────────────────────────────────────

pc <- jsonlite::read_json(PHENOCARD, simplifyVector = FALSE)

gm <- pc$global_metadata
dm <- pc$dataset_metadata
pv <- pc$provenance

dataset_name <- safe(dm$dataset_title) %||%
  stop("dataset_metadata.dataset_title is missing or empty — cannot build crate.")

dataset_description <- safe(gm$semantic_summary) %||%
  paste("PhenoCard dataset:", dataset_name)

# ── Normalise Dates ──────────────────────────────────────────────────────────
date_published <- normalise_date(
  safe(pv$execution_end_time) %||% safe(pv$execution_start_time)
)
start_time <- normalise_date(safe(pv$execution_start_time))
end_time   <- normalise_date(safe(pv$execution_end_time))

# ── File and URI Registration ──────────────────────────────────────────────────

file_refs <- list()
uri_refs  <- list()

add_ref <- function(ref, description, fmt = "application/json") {
  if (is.null(safe(ref))) return()
  full <- file.path(OUTPUT_DIR, ref)
  if (file.exists(full)) {
    file_refs[[length(file_refs) + 1]] <<- list(
      id          = ref,
      description = description,
      fmt         = fmt
    )
    message("  Registered file: ", ref)
  } else {
    warning("  File not found on disk, skipping: ", ref)
  }
}

add_uri <- function(uri, description) {
  if (is.null(safe(uri))) return()
  if (grepl("^http", uri)) {
    uri_refs[[length(uri_refs) + 1]] <<- list(
      id          = uri,
      description = description
    )
    message("  Registered online reference: ", uri)
  }
}

message("Registering referenced files and URIs...")

# 1. DQA
add_ref(dm$dqa_reference,
        "Data Quality Assessment results file", "application/json")

# 2. Aggregate Profile
add_ref(dm$aggregate_profile_reference,
        "External aggregate demographic profile", "application/json")

# 3. PhenoCard Source
add_ref(basename(PHENOCARD),
        "Validated PhenoCard JSON-LD source file", "application/json")

# 4. Profile Image / Visualisation
add_ref(VIEWER_HTML_FILENAME,
        "Interactive PhenoCard Viewer visualization", "text/html")

# 5. README
add_ref(README_FILENAME,
        "RO-Crate standard README describing this dataset package", "text/markdown")

# 6. Circe Cohort Rules (Scan directory for any file ending in Cohort.json)
cohort_files <- list.files(path = OUTPUT_DIR, pattern = "Cohort\\.json$", full.names = FALSE)
for (cf in cohort_files) {
  add_ref(cf, "Circe cohort definition file", "application/json")
}

# 7. Iterate Profiles for URIs, MINIMAR generation, and linking
for (profile_id in names(pc$profiles)) {
  prof <- pc$profiles[[profile_id]]
  
  # Handle base cohort reference (File or URL)
  cohort_refs <- prof$base_cohort_reference
  if (!is.null(cohort_refs) && !is.list(cohort_refs)) cohort_refs <- list(cohort_refs)
  
  for (idx in seq_along(cohort_refs)) {
    ref <- cohort_refs[[idx]]
    label <- paste0("Base cohort reference for profile ", profile_id)
    
    if (grepl("^http", safe(ref))) {
      add_uri(safe(ref), label)
    } else {
      add_ref(safe(ref), label, "application/json")
    }
  }
  
  # Generate the MINIMAR Markdown file dynamically
  alg <- prof$algorithmic_config
  if (!is.null(alg)) {
    # This creates the file on disk
    minimar_md_filename <- generate_minimar_md(
      pc = pc,
      profile_id = profile_id,
      cohort_files = cohort_files,
      output_dir = OUTPUT_DIR
    )
    
    # Now register the newly created file into the RO-Crate
    add_ref(minimar_md_filename,
            paste0("MINIMAR reporting markdown file for profile ", profile_id),
            "text/markdown")
  }
}

# ── Create Semantic Entities ───────────────────────────────────────────────────

# Author Entity
author_id <- safe(gm$author$orcid) %||%
  paste0("#", gsub("[^A-Za-z0-9]", "_", safe(gm$author$name) %||% "author"))

author_entity <- rocrateR::entity(
  id   = author_id,
  type = "Person",
  name = safe(gm$author$name)
)
if (!is.null(safe(gm$author$affiliation))) {
  author_entity$affiliation <- safe(gm$author$affiliation)
}

# Provenance (CreateAction) Entity
prov_entity <- rocrateR::entity(
  id          = "#provenance",
  type        = "CreateAction",
  name        = "Pipeline run producing this PhenoCard",
  description = "PAV provenance for the run that produced this PhenoCard.",
  startTime   = start_time,
  endTime     = end_time,
  result      = list(`@id` = "./"),
  agent       = list(`@id` = author_id)
)
if (!is.null(safe(pv$git_commit))) prov_entity$version <- safe(pv$git_commit)
if (!is.null(safe(pv$pipeline_run_id))) prov_entity$identifier <- safe(pv$pipeline_run_id)

# Convert local files and URIs to rocrateR entities
file_entities <- lapply(file_refs, function(f) {
  rocrateR::entity(
    id = f$id, type = "File", description = f$description, encodingFormat = f$fmt
  )
})

uri_entities <- lapply(uri_refs, function(u) {
  rocrateR::entity(
    id = u$id, type = "CreativeWork", description = u$description
  )
})

# ── Initialise Crate & Link Properties ─────────────────────────────────────────

all_entities <- c(list(author_entity, prov_entity), file_entities, uri_entities)
crate <- do.call(rocrateR::rocrate, all_entities)

# Root Dataset Properties
crate <- crate |>
  rocrateR::add_entity_value(id = "./", key = "name",          value = dataset_name, overwrite = TRUE) |>
  rocrateR::add_entity_value(id = "./", key = "description",   value = dataset_description, overwrite = TRUE) |>
  rocrateR::add_entity_value(id = "./", key = "license",       value = safe(gm$license), overwrite = TRUE) |>
  rocrateR::add_entity_value(id = "./", key = "datePublished", value = date_published, overwrite = TRUE) |>
  rocrateR::add_entity_value(id = "./", key = "author",        value = list(`@id` = author_id), overwrite = TRUE) |>
  rocrateR::add_entity_value(id = "./", key = "mentions",      value = list(`@id` = "#provenance"), overwrite = TRUE)

if (!is.null(safe(gm$doi))) {
  crate <- crate |> rocrateR::add_entity_value(
    id = "./", key = "identifier", value = safe(gm$doi), overwrite = TRUE
  )
}

# ── Link files and URIs to root ────────────────────────────────────────────────

# Construct the complete list of file references and add them all at once.
if (length(file_refs) > 0) {
  has_part_list <- lapply(file_refs, function(f) list(`@id` = f$id))
  
  crate <- crate |> rocrateR::add_entity_value(
    id = "./", key = "hasPart", value = has_part_list, overwrite = TRUE
  )
}

# Construct the complete list of online URIs and add them all at once.
if (length(uri_refs) > 0) {
  is_based_on_list <- lapply(uri_refs, function(u) list(`@id` = u$id))
  
  crate <- crate |> rocrateR::add_entity_value(
    id = "./", key = "isBasedOn", value = is_based_on_list, overwrite = TRUE
  )
}

# ── Stage referenced files and write RO-Crate metadata

if (dir.exists(STAGING_DIR)) unlink(STAGING_DIR, recursive = TRUE)
dir.create(STAGING_DIR, recursive = TRUE)

for (f in file_refs) {
  src <- file.path(OUTPUT_DIR, f$id)
  dst <- file.path(STAGING_DIR, f$id)
  dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
  file.copy(src, dst, overwrite = TRUE)
}

rocrateR::write_rocrate(crate, file.path(STAGING_DIR, "ro-crate-metadata.json"))

# ── Bag the staged crate ─────────────────────────────────────────────────────────

if (dir.exists(BAG_OUTPUT_DIR)) unlink(BAG_OUTPUT_DIR, recursive = TRUE)
dir.create(BAG_OUTPUT_DIR, recursive = TRUE)

bag_path <- rocrateR::bag_rocrate(STAGING_DIR, path = BAG_OUTPUT_DIR)
message("RO-Crate bagged at: ", bag_path)

# bag_rocrate bags an existing directory in place
if (dirname(bag_path) != BAG_OUTPUT_DIR) {
  final_path <- file.path(BAG_OUTPUT_DIR, basename(bag_path))
  file.copy(bag_path, final_path, overwrite = TRUE)
  message("Copied final bag to: ", final_path)
}

message("Bag validation (is_rocrate_bag): ", rocrateR::is_rocrate_bag(bag_path))
