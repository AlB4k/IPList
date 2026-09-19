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

catalog_sources=(
  Sources/IPList/CatalogModels.swift
  Sources/IPList/ServiceCatalogLoader.swift
)
swiftc -parse-as-library "${catalog_sources[@]}" Tests/CatalogChecks.swift -o .build/checks/catalog-checks
.build/checks/catalog-checks
