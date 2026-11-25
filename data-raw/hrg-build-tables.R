# Build the bundled HRG4+ logic tables from an NHS England "Code to Group"
# workbook (published with every grouper release at
# https://digital.nhs.uk/services/national-casemix-office/downloads-groupers-and-tools).
#
# Usage: Rscript data-raw/hrg-build-tables.R [workbook.xlsx] [version]

args <- commandArgs(trailingOnly = TRUE)
workbook <- if (length(args) >= 1) args[[1]] else file.path(
  "target", "HRG4+ 202425 National Costs Grouper", "docs",
  "HRG4 202425 National Costs Grouper Code To Group v1.0.xlsx"
)
version <- if (length(args) >= 2) args[[2]] else "2024-25-nc"

pkgload::load_all(".", quiet = TRUE)

tbls <- hrg_import_code_to_group(workbook, version = version)

# Keep classification *codes* (needed by the logic) but not the ICD-10 / OPCS-4
# descriptions, which are licensed separately (WHO / Crown copyright via TRUD).
tbls$opcs$description <- NULL
tbls$icd10$description <- NULL
tbls$lists$description <- NULL
tbls$code_to_group$description <- NULL
tbls$combination_codes$description <- NULL

# Logic that NHS England publishes only in the Chapter Summaries PDF
# (transcribed in data-raw/hrg/): the emergency medicine investigation and
# treatment hierarchies.
tbls$em_hierarchy <- tibble::as_tibble(utils::read.csv("data-raw/hrg/em-hierarchy.csv",
  colClasses = c("character", "character", "integer")))
print(tbls)

out_dir <- file.path("inst", "extdata", "hrg")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out <- file.path(out_dir, paste0(version, ".rds"))
saveRDS(tbls, out, compress = "xz")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB )\n")
