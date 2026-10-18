#!/bin/bash
# Fetches LFW funneled (figshare 5976015) into bench/data/lfw_funneled and checks its sha256.
# LFW_TGZ=/path/to/lfw-funneled.tgz uses a copy you already have.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
data="$here/data"
sha=b47c8422c8cded889dc5a13418c4bc2abbda121092b3533a83306f90d900100a
tgz="${LFW_TGZ:-$data/lfw-funneled.tgz}"
mkdir -p "$data"
if [[ -d "$data/lfw_funneled" ]]; then
  echo "bench/data/lfw_funneled is already there"
  exit 0
fi
if [[ ! -f "$tgz" ]]; then
  curl -fL --retry 3 -o "$tgz" https://ndownloader.figshare.com/files/5976015
fi
got=$(shasum -a 256 "$tgz" | cut -d' ' -f1)
if [[ "$got" != "$sha" ]]; then
  echo "lfw-funneled.tgz sha256 is $got, expected $sha" >&2
  exit 1
fi
tar -xzf "$tgz" -C "$data"
echo "LFW funneled ready in bench/data/lfw_funneled"
