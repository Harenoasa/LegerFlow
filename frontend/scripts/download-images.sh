#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p public/images

for i in $(seq -w 1 20); do
  echo "Downloading product-${i}.jpg"
  curl -fL --retry 3 -sS "https://picsum.photos/seed/ledgerflow${i}/800/600" \
    -o "public/images/product-${i}.jpg"
done

echo "Done. $(ls -1 public/images | wc -l) images in public/images"
