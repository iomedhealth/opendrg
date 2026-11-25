# Build the bundled Prescribed Specialised Services rules from an NHS England
# "Guide to Identification Rules" workbook (published with every PSO release at
# https://digital.nhs.uk/services/national-casemix-office/downloads-groupers-and-tools).
#
# Usage: Rscript data-raw/pso-build-tables.R [workbook.xlsm] [version] [reference HRG version]

args <- commandArgs(trailingOnly = TRUE)
workbook <- if (length(args) >= 1) args[[1]] else file.path(
  "target", "Prescribed Services 2025:26 Operational Tool (PSO) - updated", "docs",
  "PSO 202526 Prescribed Services Guide to Identification Rules v1.1.xlsm"
)
version <- if (length(args) >= 2) args[[2]] else "2025-26"
reference <- if (length(args) >= 3) args[[3]] else "2025-26-lp"

pkgload::load_all(".", quiet = TRUE)

tbls <- pso_import_rules(workbook, version = version, reference = hrg_tables(reference))
print(tbls)

out_dir <- file.path("inst", "extdata", "pso")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out <- file.path(out_dir, paste0(version, ".rds"))
saveRDS(tbls, out, compress = "xz")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB )\n")
