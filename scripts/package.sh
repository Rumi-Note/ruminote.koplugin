#!/usr/bin/env bash
# 打包 KOReader 插件发布包：dist/ruminote.koplugin-v<version>.zip
# zip 内顶层为 ruminote.koplugin/，解压后直接放入 KOReader 的 plugins/ 目录。
set -euo pipefail

cd "$(dirname "$0")/.."
version="$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' _meta.lua | head -1)"
[ -n "$version" ] || { echo "cannot read version from _meta.lua" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/ruminote.koplugin" dist

cp _meta.lua main.lua fingerprint.lua README.md README.en.md LICENSE "$stage/ruminote.koplugin/"

out="$PWD/dist/ruminote.koplugin-v${version}.zip"
rm -f "$out"
( cd "$stage" && zip -r -X -q "$out" ruminote.koplugin )

echo "Built: $out"
unzip -l "$out"
