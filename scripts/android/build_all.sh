#!/bin/bash

set -x -e

APP="${1:-trekpay}"

mkdir -p build
. ./config.sh

wait
echo "Done building"
