#!/usr/bin/env bash

set -euo pipefail

mkdir -p ./out

sources=(
  ./src/*.c
  ./tests/tests.c
  ./vendor/cjson/cjson.c
)

clang \
  -std=c17 \
  -Wall \
  -Wextra \
  -I./src \
  -I./vendor/cjson \
  "${sources[@]}" \
  -o ./out/tests

./out/tests
