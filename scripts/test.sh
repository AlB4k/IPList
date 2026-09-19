#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/checks
swiftc -parse-as-library \
  Sources/IPList/AddressMatcher.swift \
  Sources/IPList/ExportFormats.swift \
  Sources/IPList/Core.swift \
  Tests/CoreChecks.swift \
  -o .build/checks/core-checks
.build/checks/core-checks
