#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh
spatial_select_xcode
out="$PWD/build/research"
mkdir -p "$out"
xcrun swiftc -I Stubs -L Stubs -lAlchemistBase Research/Reframe/BaseProbe.swift -o "$out/BaseProbe"
xcrun swiftc -parse-as-library -I Stubs -L Stubs -lAlchemistService Research/Reframe/ServiceProbe.swift -o "$out/ServiceProbe"
xcrun clang -fobjc-arc -framework Foundation Research/Reframe/AssetProbe.m -o "$out/AssetProbe"
xcrun swiftc Research/Cleanup/InspectModels.swift -o "$out/InspectModels"
xcrun swiftc -Onone -I Stubs -L Stubs -lPhotosGenerativeServices Research/Cleanup/LinkCheck.swift -o "$out/LinkCheck"
xcrun clang -fobjc-arc -framework Foundation Research/Cleanup/DumpRegistry.m -o "$out/DumpRegistry"
xcrun clang -fobjc-arc -framework Foundation Research/Cleanup/RuntimeProbe.m -o "$out/RuntimeProbe"
printf 'Built probes in %s; none were executed.\n' "$out"
