#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/checks
swiftc -parse-as-library -D TASK7_CHECKS \
  Sources/IPList/AddressMatcher.swift \
  Sources/IPList/ExportFormats.swift \
  Sources/IPList/CatalogModels.swift \
  Sources/IPList/ServiceCatalogLoader.swift \
  Sources/IPList/EnrichmentLoader.swift \
  Sources/IPList/AmneziaWGConfig.swift \
  Sources/IPList/Core.swift \
  Sources/IPList/App.swift \
  Tests/Task7Checks.swift \
  -o .build/checks/task7-checks
.build/checks/task7-checks
