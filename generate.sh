#!/bin/bash
# Generates the Swift protobuf types + pblite schema. Run once (and after editing Protos/).
#   brew install protobuf swift-protobuf
#   pip3 install grpcio-tools     # used only for tools/gen_schema.py
set -euo pipefail
cd "$(dirname "$0")"
python3 tools/gen_schema.py
rm -f Sources/GMessagesMac/Generated/*.pb.swift
protoc --proto_path=Protos-Swift --swift_opt=Visibility=Internal \
       --swift_out=Sources/GMessagesMac/Generated Protos-Swift/*.proto
echo "Generated: $(ls Sources/GMessagesMac/Generated | wc -l) files"
