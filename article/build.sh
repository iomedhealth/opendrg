#!/bin/sh
# Build the opendrg whitepaper with Tectonic (https://tectonic-typesetting.github.io).
#   brew install tectonic   # macOS
#   ./build.sh              # writes wp_opendrg.pdf
set -e
cd "$(dirname "$0")"
tectonic wp_opendrg.tex
tectonic omop_er_schema.tex
