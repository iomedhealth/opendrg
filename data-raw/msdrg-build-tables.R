# Build the bundled MS-DRG logic tables from a CMS mainframe release.
#
# Source: "MS-DRG Grouper Software and Medicare Code Editor (MCE) MAINFRAME
# Software" zip from
# https://www.cms.gov/medicare/payment/prospective-payment-systems/acute-inpatient-pps/ms-drg-classifications-and-software
# Unzip it, then unzip the inner MS-DRG package; the flat files live in
# `<package>/CMSDRGvvv_MF_Java_Misc/`.
#
# Usage: Rscript data-raw/msdrg-build-tables.R [misc_dir] [version]

args <- commandArgs(trailingOnly = TRUE)
misc_dir <- if (length(args) >= 1) args[[1]] else file.path(
  "target", "MS-DRG V44 FY2027 (CMS)", "_extract", "mainframe", "msdrg",
  "MS-DRG440.R0.MF.Java.GenRel.Software_package", "CMSDRG440_MF_Java_Misc"
)
version <- if (length(args) >= 2) args[[2]] else "44.0"

pkgload::load_all(".", quiet = TRUE)

# The HAC formulas are not part of the flat files: they only exist in the
# grouper's binary data buffer and were dumped from it with the Java access
# layer (see dev/oracle/). Keep one CSV per version here.
hac_file <- file.path("data-raw", paste0("msdrg-hac-formulas-v", gsub(".", "", version, fixed = TRUE), ".csv"))
hac_formulas <- utils::read.csv(hac_file, colClasses = c("integer", "character"), strip.white = TRUE)

tbls <- msdrg_import_cms(misc_dir, version = version, hac_formulas = hac_formulas)
print(tbls)

out_dir <- file.path("inst", "extdata", "msdrg")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out <- file.path(out_dir, paste0("v", gsub(".", "", version, fixed = TRUE), ".rds"))
saveRDS(tbls, out, compress = "xz")
cat("Wrote", out, "(", round(file.size(out) / 1024), "KB )\n")
