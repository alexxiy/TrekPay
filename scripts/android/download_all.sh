#!/bin/bash

set -x -e

APP="${1:-astronaut}"

mkdir -p build
. ./config.sh

wait
echo "Done"
