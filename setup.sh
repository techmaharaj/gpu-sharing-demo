#!/usr/bin/env bash
# One-time setup on the GPU machine (see README "Run it yourself": Linux, NVIDIA driver + Container Toolkit,
# k3s with the NVIDIA runtime as default). Safe to re-run:
#   - models: downloads what's missing from models.lock into /srv/models (~8.8 GB)
#             NIGHT_ONLY=1 ./setup.sh: only lists them, and a timer downloads them at 00:15
#   - HAMi installed but idle (hami.sh), a `kubectl` alias for k3s, then demo.sh reset (HAMi idle, no demo pods)
# Usage (root, in the cloned repo): ./setup.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p /srv/models
if [[ ${NIGHT_ONLY:-0} == 1 ]]; then
  sed "s#^ExecStart=.*#ExecStart=$here/fetch-models.sh#" "$here/demo-fetch-models.service" > /etc/systemd/system/demo-fetch-models.service
  install -m 644 "$here/demo-fetch-models.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable demo-fetch-models.timer && systemctl restart demo-fetch-models.timer   # restart: picks up a changed schedule
  systemctl list-timers demo-fetch-models.timer --no-pager
fi
MODELS_DIR=/srv/models "$here/fetch-models.sh"

command -v k3s >/dev/null || { echo "setup.sh: k3s isn't installed yet (README \"Run it yourself\"); models only"; exit 0; }
echo "alias kubectl='sudo k3s kubectl'" > /etc/profile.d/gpu-demo.sh   # plain kubectl in every new login
"$here/hami.sh"                 # HAMi installed, idle
"$here/demo.sh" reset           # HAMi idle, NVIDIA plugin on, no demo pods
