#!/bin/sh
# smoke.sh — exercise the CLI surface end-to-end on a real machine.
# Read-only + dry-run paths only; never touches the keyboard/mouse.
set -eu

cd "$(dirname "$0")/.."
S1="${S1:-.build/debug/s1}"

echo "== build =="
swift build --product s1

echo "== version =="
"$S1" --version

echo "== preflight =="
"$S1" preflight || true   # exits 1 when TCC grants are missing — still informative

echo "== tasks =="
"$S1" tasks

echo "== config =="
"$S1" config || true      # endpoints may be unreachable — that's the report

echo "== status =="
"$S1" status

echo "== dry-run demo (touches nothing) =="
"$S1" demo --dry-run

echo "== scripted dry-run =="
"$S1" run --task open-app --policy ax --dry-run

echo "smoke done — artifacts in ~/.s1/artifacts/"
