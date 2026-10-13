#!/bin/bash

set -x -e

APP="${1:-astronaut}"

mkdir -p build
./build_secure_storage_deps.sh

./build_secp256k1.sh

wait
echo "Done"
