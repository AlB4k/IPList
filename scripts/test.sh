#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/checks
production_sources=(
  Sources/IPList/AddressMatcher.swift
  Sources/IPList/ExportFormats.swift
  Sources/IPList/CatalogModels.swift
  Sources/IPList/ServiceCatalogLoader.swift
  Sources/IPList/EnrichmentLoader.swift
  Sources/IPList/AmneziaWGConfig.swift
  Sources/IPList/Core.swift
)
available_sources=()
for source in "${production_sources[@]}"; do
  [[ -f "$source" ]] && available_sources+=("$source")
done
swiftc -parse-as-library "${available_sources[@]}" Tests/CoreChecks.swift -o .build/checks/core-checks
.build/checks/core-checks

swiftc -parse-as-library "${available_sources[@]}" Tests/StateChecks.swift -o .build/checks/state-checks
.build/checks/state-checks

if [[ -f Tests/RefreshChecks.swift ]]; then
  swiftc -parse-as-library "${available_sources[@]}" Tests/RefreshChecks.swift -o .build/checks/refresh-checks
  .build/checks/refresh-checks
fi

catalog_sources=(
  Sources/IPList/CatalogModels.swift
  Sources/IPList/ServiceCatalogLoader.swift
)
swiftc -parse-as-library "${catalog_sources[@]}" Tests/CatalogChecks.swift -o .build/checks/catalog-checks
.build/checks/catalog-checks

if [[ -f Tests/EnrichmentChecks.swift ]]; then
  swiftc -parse-as-library \
    Sources/IPList/AddressMatcher.swift \
    Sources/IPList/CatalogModels.swift \
    Sources/IPList/EnrichmentLoader.swift \
    Tests/EnrichmentChecks.swift \
    -o .build/checks/enrichment-checks
  .build/checks/enrichment-checks
fi
