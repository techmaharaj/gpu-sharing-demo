#!/usr/bin/env bash
# Helpers for the GPU sharing demo (the steps themselves: README "Walkthrough"). Root, on the GPU machine.
#   demo.sh reset    the starting point: HAMi installed but idle (node label gpu removed, its node notes wiped),
#                    NVIDIA device plugin on (the card, whole), no pods in demo, both images on disk, both model
#                    files in RAM (fast loads); also heals the pods a VM boot leaves behind
#   demo.sh status   pods, schedulers, slices, GPU memory
#   demo.sh heal     only the after-boot fix (reset runs it)
#   demo.sh hammer [min]   with both pods on HAMi: chat + image request together every ~3 s for N minutes (default 10)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k() { k3s kubectl "$@"; }
B=$'\e[1m'; G=$'\e[1;32m'; R=$'\e[1;31m'; N=$'\e[0m'
say() { printf '\n%s▶ %s%s\n' "$B" "$*" "$N"; }
node() { k get node -o jsonpath='{.items[0].metadata.name}'; }
slices() { k get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'; }
wait_slices() { for _ in $(seq 120); do [[ $(slices) == "$1" ]] && return; sleep 1; done; echo "${R}node allocatable nvidia.com/gpu = $(slices), wanted $1$N" >&2; return 1; }
svc() { k -n demo get svc "$1" -o jsonpath='{.spec.clusterIP}'; }

heal() {
  # HAMi's webhook must be up before any pod is (re)created, or a HAMi pod lands on default-scheduler.
  k -n hami-system rollout status deploy/hami-scheduler --timeout=180s >/dev/null
  # After a VM boot the old GPU pods fail admission (UnexpectedAdmissionError: device plugin not back yet).
  k -n demo delete pod --field-selector=status.phase=Failed --ignore-not-found --wait=false | grep -v '^$' || true
  # A replacement made before the webhook was up: no "ignore" label but on default-scheduler -> Pending forever.
  k -n demo get pod -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    m, s = p["metadata"], p["spec"]
    want = "default-scheduler" if m.get("labels", {}).get("hami.io/webhook") == "ignore" else "hami-scheduler"
    if p["status"]["phase"] == "Pending" and s.get("schedulerName") != want and "app" in m.get("labels", {}):
        print(m["name"])' | while read -r p; do echo "heal: recreating $p (wrong scheduler)"; k -n demo delete pod "$p" --wait=false; done
}

status() {
  k -n demo get pod -o custom-columns='POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,SCHEDULER:.spec.schedulerName,GPU:.spec.containers[0].resources.limits.nvidia\.com/gpu,GPUMEM_MiB:.spec.containers[0].resources.limits.nvidia\.com/gpumem' 2>/dev/null
  echo "node $(node): nvidia.com/gpu = ${B}$(slices)${N}  ($( [[ $(k get node -o jsonpath='{.items[0].metadata.labels.gpu}') == on ]] && echo 'HAMi: 10 slices' || echo 'plain device plugin: the card, whole'))"
  nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | sed 's/^/GPU: /'
}

ask_chat() {  # prints the answer + seconds
  python3 - "$(svc chat)" "$1" <<'EOF'
import json, sys, time, urllib.request
t = time.time()
r = urllib.request.urlopen(urllib.request.Request(f"http://{sys.argv[1]}/v1/chat/completions",
    json.dumps({"messages": [{"role": "user", "content": sys.argv[2]}], "max_tokens": 60}).encode(),
    {"Content-Type": "application/json"}), timeout=60)
a = json.load(r)["choices"][0]["message"]["content"].strip().replace("\n", " ")
print(f"chat  ({time.time() - t:.2f} s): {a[:90]}")
EOF
}
ask_image() {  # sd-server's OpenAI-style API; prints seconds + size
  python3 - "$(svc image)" "$1" <<'EOF'
import base64, json, sys, time, urllib.request
t = time.time()
r = urllib.request.urlopen(urllib.request.Request(f"http://{sys.argv[1]}/v1/images/generations",
    json.dumps({"prompt": sys.argv[2], "n": 1, "size": "512x512"}).encode(),
    {"Content-Type": "application/json"}), timeout=120)
png = base64.b64decode(json.load(r)["data"][0]["b64_json"])
open("/tmp/demo-image.png", "wb").write(png)
print(f"image ({time.time() - t:.2f} s): 512x512 PNG, {len(png)} bytes")
EOF
}

case ${1:-status} in
reset)
  t0=$SECONDS
  say "Reset: HAMi idle, no demo pods"
  heal
  k -n demo delete pod greedy too-big --ignore-not-found --wait=false >/dev/null
  k -n demo delete deploy chat image --ignore-not-found >/dev/null   # services stay: their NodePorts are fixed
  k -n demo wait --for=delete pod -l 'app in (chat,image)' --timeout=120s >/dev/null 2>&1 || true
  if k get node -o jsonpath='{.items[0].metadata.labels.gpu}' | grep -q on; then
    echo "HAMi to idle: node label gpu removed (its device plugin leaves; scheduler + webhook stay)"
    k label node --all gpu- >/dev/null
    k -n hami-system wait --for=delete pod -l app.kubernetes.io/component=hami-device-plugin --timeout=120s >/dev/null 2>&1 || true
  fi
  # HAMi's plugin leaves its registration (and locks) on the node. Stale, they let hami-scheduler place a
  # pod before the plugin is back: kubelet rejects it and the node lock blocks the next pod for 5 min.
  a=$(k get node "$(node)" -o json | python3 -c 'import json,sys; print(" ".join(k + "-" for k in json.load(sys.stdin)["metadata"]["annotations"] if k.startswith("hami.io/")))')
  [[ -z $a ]] || k annotate node "$(node)" $a >/dev/null
  k apply -f "$here/k8s/services.yaml" >/dev/null   # namespace + NodePorts 30080/30081
  k apply -f "$here/k8s/device-plugin.yaml" >/dev/null
  k -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=180s >/dev/null
  # If HAMi's plugin ran while NVIDIA's was up, it took over nvidia.com/gpu; when HAMi leaves, the node shows 0
  # until NVIDIA's plugin registers again, which it only does on a restart.
  if [[ $(slices) != 1 ]]; then
    for _ in $(seq 10); do [[ $(slices) == 1 ]] && break; sleep 1; done
    if [[ $(slices) != 1 ]]; then
      echo "NVIDIA device plugin not registered (node shows $(slices) GPUs): restarting it"
      k -n kube-system rollout restart ds/nvidia-device-plugin-daemonset >/dev/null
      k -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=180s >/dev/null
    fi
  fi
  wait_slices 1
  # Both images on disk (kubelet deletes unused images when the disk passes 85%; a re-pull takes minutes)
  for img in $(grep -ho 'image: [^ ]*@sha256:[0-9a-f]*' "$here/k8s/chat.yaml" "$here/k8s/image.yaml" | cut -d' ' -f2); do
    k3s crictl inspecti "$img" >/dev/null 2>&1 || { echo "pulling $img"; k3s crictl pull "$img" >/dev/null; }
  done
  cat /srv/models/*/*.safetensors /srv/models/*/*.gguf > /dev/null   # into RAM: pod loads skip the disk
  status
  df -h / | awk 'NR==2 {print "disk: " $5 " used (kubelet deletes unused images above 85%)"}'
  printf '\n%sReady: HAMi idle, no demo pods%s (%ss)\n' "$G" "$N" $((SECONDS - t0))
  ;;
status) status ;;
heal) heal ;;
hammer)
  mins=${2:-10}; end=$((SECONDS + mins * 60)); n=0; e=0
  say "Hammer: chat + image every ~3 s for $mins min"
  while (( SECONDS < end )); do
    n=$((n + 1))
    ask_chat "Count from 1 to 10." >/dev/null 2>&1 & c=$!   # both at once: the point is sharing
    ask_image "a kettle on a stove, round $n" >/dev/null 2>&1 & i=$!
    wait $c || { e=$((e + 1)); echo "chat error at round $n"; }
    wait $i || { e=$((e + 1)); echo "image error at round $n"; }
    (( n % 20 == 0 )) && echo "round $n, errors $e, $(nvidia-smi --query-gpu=memory.used --format=csv,noheader) used"
    sleep 3
  done
  echo "${B}$n rounds, $e errors${N}"; status
  ;;
*) sed -n '2,8p' "$0"; exit 1 ;;
esac
