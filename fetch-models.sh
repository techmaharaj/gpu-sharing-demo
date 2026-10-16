#!/usr/bin/env bash
# Download the models pinned in models.lock (Hugging Face commit + SHA-256) that aren't on disk yet.
# Resumes partial downloads (*.part); a file only lands under its real name after its checksum passes.
# Safe to re-run. ~8.8 GB for the two main models.
#   MODELS_DIR=<dir>   where to put them (default /srv/models; the k8s/ manifests mount /srv/models/<model>)
#   NIGHT_ONLY=1       only download between 00:00 and 06:00, otherwise list what's missing and exit
#                      (for a metered or shared line: demo-fetch-models.timer runs this at 00:15)
# Usage (root): ./fetch-models.sh
set -euo pipefail
cd "$(dirname "$0")"
DIR=${MODELS_DIR:-/srv/models}
# One fetch at a time: a second run must not resume the same .part file.
exec 9>/run/lock/demo-fetch-models.lock
flock -n 9 || { echo "another fetch-models.sh is running; skipping (files it's downloading aren't ready yet)"; exit 0; }
while read -r dest repo rev file sha; do
  [[ -z ${dest:-} || $dest == \#* ]] && continue
  out=$DIR/$dest
  [[ -f $out ]] && continue
  if [[ ${NIGHT_ONLY:-0} == 1 ]] && (( 10#$(date +%H) >= 6 )); then
    echo "missing: $dest (NIGHT_ONLY=1: downloads between 00:00 and 06:00)"
    continue
  fi
  mkdir -p "$(dirname "$out")"
  echo "fetching $dest"
  curl -fsSL --retry 5 -C - -o "$out.part" "https://huggingface.co/$repo/resolve/$rev/$file"
  if ! echo "$sha  $out.part" | sha256sum -c --quiet -; then
    rm -f "$out.part"; echo "checksum mismatch: $dest (deleted, re-run)" >&2; exit 1
  fi
  mv "$out.part" "$out"
done < models.lock
