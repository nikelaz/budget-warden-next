#!/usr/bin/env bash

set -euo pipefail

mkdir -p ./out

sources=(./src/*.c)

gcc "${sources[@]}" -o ./out/tests
./out/tests
