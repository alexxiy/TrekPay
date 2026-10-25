#!/bin/bash

set -x -e

APP="${1:-trekpay}"

mkdir -p build

./build_secp256k1_wsl.sh

wait
echo "Done building"
