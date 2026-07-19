# Aggregate-gen.R
#
# Builds the aggregate profile that travels in the RO-Crate: a marginal
# summary of every patient and feature that entered the ML matrix, in a form
# a receiving site can compute weights from.
#
# Marginals only. Covariance is not produced here.
#
# Both metric columns are overloaded, so every record declares what it holds:
#
#   metric_mean_or_count      metric_mean_or_count_unit       "count" | "mean"
#   metric_sd_or_proportion   metric_sd_or_proportion_unit    "fraction" | "sd"
#
# Proportions are fractions in [0, 1], never percentages. Step 18's
# cohort_characterization is a different artifact with a different contract:
# it mirrors p1_05_cohort_characterization.sql and emits percentages as
# character, so the two cannot be concatenated without rescaling.
#
# Not standalone. Call after step 14 of "SQL reproduction.R", which produces
# the three inputs:
#
#   final_ml_matrix   step 14 — one row per patient; absent features are 0
#   covariates_df     step 12 — long form, before the pivot and the 0 fill
#   covariate_ref     step 12 — collected covariateRef, carries conceptId
#
# The profile describes exactly the rows that went into the ML run. Nothing
# here re-queries the CDM.

library(dplyr)
library(tidyr)
library(jsonlite)

generate_aggregate_profile <- function(final_ml_matrix,
                                       covariates_df,
                                       covariate_ref,
                                       output_file = "dataset_aggregate_profile.json") {

  # Feature name -> concept_id. Mirrors the relabeling in step 12 of
  # "SQL reproduction.R"; if the covariate settings change, both move together.
  fe_feature_name <- function(analysis_id, covariate_name) {
    case_when(
      analysis_id %in% c(101) ~ paste0("condition_", covariate_name),
      analysis_id %in% c(705) ~ paste0("measurement_", covariate_name),
      TRUE ~ covariate_name
    )
  }

  # Every metric is reported for the whole cohort and for each arm. The CIRCE
  # rules already separate cases from controls, so the split costs nothing,
  # and a guest matching on pooled marginals alone could reproduce them while
  # holding a different joint structure.
  stratify <- function(df) {
    bind_rows(
      df %>% mutate(stratum = "overall"),
      df %>% filter(target_ecg_afib == 1) %>% mutate(stratum = "case"),
      df %>% filter(target_ecg_afib == 0) %>% mutate(stratum = "control")
    )
  }

  feature_ref <- covariate_ref %>%
    transmute(
      variable_name = fe_feature_name(analysisId, covariateName),
      concept_id    = conceptId
    ) %>%
    distinct(variable_name, .keep_all = TRUE)

  # --- Demographics ---------------------------------------------------------
  # No concept_id: these come from the person table, not from covariateRef.
  yob_profile <- stratify(final_ml_matrix) %>%
    group_by(stratum) %>%
    summarize(
      n                       = sum(!is.na(year_of_birth)),
      metric_mean_or_count    = mean(year_of_birth, na.rm = TRUE),
      metric_sd_or_proportion = sd(year_of_birth, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      variable_role                = "Demographics",
      variable_name                = "Year of Birth",
      concept_id                   = NA_integer_,
      data_type                    = "Continuous",
      category_value               = NA_character_,
      metric_mean_or_count_unit    = "mean",
      metric_sd_or_proportion_unit = "sd"
    )

  gender_profile <- stratify(final_ml_matrix) %>%
    count(stratum, gender, name = "count") %>%
    group_by(stratum) %>%
    mutate(n = sum(count)) %>%
    ungroup() %>%
    mutate(
      variable_role                = "Demographics",
      variable_name                = "Gender",
      concept_id                   = NA_integer_,
      data_type                    = "Categorical",
      category_value               = as.character(gender),
      metric_mean_or_count         = count,
      metric_sd_or_proportion      = count / n,
      metric_mean_or_count_unit    = "count",
      metric_sd_or_proportion_unit = "fraction"
    )

  # --- Target prevalence ----------------------------------------------------
  # Overall only; within an arm the label is constant by construction.
  target_profile <- final_ml_matrix %>%
    count(target_ecg_afib, name = "count") %>%
    mutate(
      stratum                      = "overall",
      n                            = nrow(final_ml_matrix),
      variable_role                = "Target / Outcome",
      variable_name                = "Atrial Fibrillation (Target)",
      concept_id                   = NA_integer_,
      data_type                    = "Categorical",
      category_value               = as.character(target_ecg_afib),
      metric_mean_or_count         = count,
      metric_sd_or_proportion      = count / n,
      metric_mean_or_count_unit    = "count",
      metric_sd_or_proportion_unit = "fraction"
    )

  # --- Condition flags ------------------------------------------------------
  # Binary, and a 0 here is a genuine absence, so the full cohort is the
  # correct denominator.
  condition_profile <- final_ml_matrix %>%
    select(subject_id, target_ecg_afib, starts_with("condition_")) %>%
    stratify() %>%
    pivot_longer(
      cols      = starts_with("condition_"),
      names_to  = "variable_name",
      values_to = "value"
    ) %>%
    group_by(stratum, variable_name) %>%
    summarize(
      n     = n(),
      count = sum(value > 0, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      variable_role                = "Condition",
      data_type                    = "Categorical",
      category_value               = "1",
      metric_mean_or_count         = count,
      metric_sd_or_proportion      = count / n,
      metric_mean_or_count_unit    = "count",
      metric_sd_or_proportion_unit = "fraction"
    )

  # --- Measurement values ---------------------------------------------------
  # Taken from covariates_df rather than final_ml_matrix: step 14 fills absent
  # measurements with 0, which is right for condition flags but conflates "not
  # measured" with "measured as 0". covariates_df holds only the covariates
  # FeatureExtraction actually returned, so it defines the measured set and n
  # is the number of patients measured, not the size of the stratum.
  measurement_profile <- covariates_df %>%
    filter(grepl("^measurement_", feature_name)) %>%
    inner_join(
      final_ml_matrix %>% select(subject_id, target_ecg_afib),
      by = "subject_id"
    ) %>%
    stratify() %>%
    group_by(stratum, variable_name = feature_name) %>%
    summarize(
      n                       = n_distinct(subject_id),
      metric_mean_or_count    = mean(feature_value, na.rm = TRUE),
      metric_sd_or_proportion = sd(feature_value, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      variable_role                = "Measurement",
      data_type                    = "Continuous",
      category_value               = NA_character_,
      metric_mean_or_count_unit    = "mean",
      metric_sd_or_proportion_unit = "sd"
    )

  # --- Assemble -------------------------------------------------------------
  # Proportions are fractions in [0, 1] and every metric is numeric, unlike
  # step 18's cohort_characterization, which emits percentages as character.
  aggregate_profile <- bind_rows(
    yob_profile,
    gender_profile,
    target_profile,
    condition_profile,
    measurement_profile
  ) %>%
    left_join(feature_ref, by = "variable_name") %>%
    mutate(concept_id = coalesce(concept_id.x, concept_id.y)) %>%
    select(
      stratum, variable_role, variable_name, concept_id, data_type,
      category_value, n,
      metric_mean_or_count, metric_mean_or_count_unit,
      metric_sd_or_proportion, metric_sd_or_proportion_unit
    ) %>%
    arrange(stratum, variable_role, variable_name, category_value)

  # Written to the working directory, as CIRCE-gen.R does. Run from the crate
  # root if this is to be picked up by PhenoCard2Crate.R. Pass output_file =
  # NULL to return the profile without writing anything.
  if (!is.null(output_file)) {
    write_json(
      aggregate_profile, output_file,
      pretty = TRUE, auto_unbox = TRUE, na = "null", digits = NA
    )
    message("Wrote aggregate profile: ", output_file)
  }

  aggregate_profile
}
