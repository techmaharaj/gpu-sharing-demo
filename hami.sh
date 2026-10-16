#!/usr/bin/env bash
# HAMi v2.10.0 installed but idle (Helm, hami-values.yaml): scheduler + webhook up, device plugin waiting for
# the node label gpu=on. Pinned: Helm binary + chart by SHA-256, images by digest.
# Safe to re-run. Usage (root, in the cloned repo): ./hami.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.env"
k() { k3s kubectl "$@"; }
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cache=/var/cache/gpu-sharing-demo; mkdir -p $cache

server=$(k version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')
[[ $server == "$KUBE_VERSION"+* ]] || { echo "hami.sh: cluster is $server, hami-values.yaml's kube-scheduler is $KUBE_VERSION: update both" >&2; exit 1; }

if [[ $(helm version --template '{{.Version}}' 2>/dev/null) != "$HELM_VERSION" ]]; then
  t=$cache/helm.tgz; curl -fsSLo $t "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz"
  echo "$HELM_SHA256  $t" | sha256sum -c --quiet && tar -xzf $t -C /usr/local/bin --strip-components=1 linux-amd64/helm
fi
chart=$cache/$(basename "$HAMI_CHART_URL")
[[ -f $chart ]] || curl -fsSLo "$chart" "$HAMI_CHART_URL"
echo "$HAMI_CHART_SHA256  $chart" | sha256sum -c --quiet

# Installed idle: its device plugin runs only on nodes labelled gpu=on, and the without-HAMi pods carry
# hami.io/webhook=ignore, so nothing changes until the node is labelled.
helm upgrade --install hami "$chart" -n hami-system --create-namespace -f "$here/hami-values.yaml" --wait --timeout 10m
k -n hami-system get pod
