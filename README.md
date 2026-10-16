# GPU sharing demo: two AI models on one GPU with HAMi

A demo of GPU sharing on Kubernetes with [HAMi](https://github.com/Project-HAMi/HAMi) (CNCF). Two pods (a chat
model and an image model) share one NVIDIA card. Plain Kubernetes hands the GPU out whole, so the second pod
can't start. With HAMi, each pod gets a slice of GPU memory that it can't exceed, so both run and a greedy third
pod gets refused.

## What it shows

| Step | What happens | Result |
|---|---|---|
| **Without HAMi** | Chat pod (llama.cpp + Qwen3 1.7B) and image pod (SDXL-Turbo) each ask for `nvidia.com/gpu: 1` | Chat runs using ~2.8 GB but holds the whole card; image stays **Pending**: `Insufficient nvidia.com/gpu` |
| **With HAMi** | HAMi, installed but idle, is switched on; each pod gets one extra line: `nvidia.com/gpumem` | The node offers 10 slices; both pods **Running**. `nvidia-smi` inside chat shows **4000 MiB** total, inside image **10000 MiB** |
| **The fence** | A greedy pod with a 2000 MiB slice loads a model needing ~3 GB | `HAMI-core ERROR … OOM`, refused; the other two keep working |

Not covered: compute limits. HAMi fences GPU **memory**; compute caps (`gpucores`) don't hold under the default
policy today ([HAMi-core #350](https://github.com/Project-HAMi/HAMi-core/issues/350)).

## How it works

```
one machine, one NVIDIA GPU, k3s (single node, NVIDIA as containerd's default runtime)
├── kube-system   NVIDIA device plugin       without HAMi: the card, whole (removed when switching)
├── hami-system   HAMi v2.10.0               idle until the node is labelled gpu=on
└── demo
    ├── chat      llama.cpp server + Qwen3 1.7B Q8_0   web page   NodePort 30080   with HAMi: 4000 MiB
    ├── image     sd-server + SDXL-Turbo (1 step)     web UI     NodePort 30081   with HAMi: 10000 MiB
    └── greedy    llama.cpp loading ~3 GB                                         2000 MiB
```

- **Without vs with HAMi is two lines per pod**: `chat.yaml` → `chat-hami.yaml` drops `hami.io/webhook: ignore`
  (that label tells HAMi's webhook to leave the pod alone) and adds `nvidia.com/gpumem: 4000`. Same for image.
- **HAMi is installed up front but idle**: its device plugin only runs on nodes labelled `gpu=on`, so switching
  is a `kubectl label node`, not a Helm install.
- **Image model**: [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)'s `sd-server` (the
  same ggml CUDA engine as llama.cpp), so no PyTorch: a 2.4 GB container, ~0.4 s per 512×512 image.
- **CUDA 12 in the pods**, not 13: HAMi-core's CUDA 13 support isn't in a release yet.
- **Everything pinned**: container images by digest, the Helm chart and binary by SHA-256, models by Hugging Face
  commit + SHA-256 ([versions.env](versions.env), [models.lock](models.lock)).

## Run it yourself

**Needs:**
- Linux, x86_64 (all images are amd64), a single machine or VM with the GPU passed through.
- An NVIDIA GPU with **16 GB** (12 GB may work with smaller slices, see below), a current driver (tested: 580),
  and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
- [k3s](https://k3s.io) with NVIDIA as the default runtime. Tested on **v1.35.9+k3s1**; `/etc/rancher/k3s/config.yaml`:
  ```yaml
  default-runtime: nvidia
  ```
  (k3s finds `nvidia-container-runtime` itself; install k3s after the toolkit.)
- ~25 GB free disk (8.8 GB of models + ~5 GB of images, with room to stay under the kubelet's 85% clean-up line)
  and ~12 GB RAM (the models are read into RAM so the pods load fast).
- Internet for the first run (models from Hugging Face, images from ghcr.io / docker.io / nvcr.io).

**Setup, as root:**
```bash
git clone https://github.com/techmaharaj/gpu-sharing-demo.git && cd gpu-sharing-demo
./setup.sh      # models into /srv/models, HAMi installed idle, then demo.sh reset
```
`setup.sh` also adds `alias kubectl='sudo k3s kubectl'` for new logins; in the current shell, set it yourself.

## Walkthrough

Start from `./demo.sh reset` (HAMi idle, NVIDIA plugin on, no demo pods). The pages are at
`http://<node>:30080` (chat) and `http://<node>:30081` (image).

**Without HAMi**
```bash
kubectl apply -f k8s/chat.yaml && kubectl -n demo get pod -w        # chat Running
nvidia-smi                                                            # ~2.8 GB used of the card
kubectl apply -f k8s/image.yaml
kubectl -n demo describe pod -l app=image | tail -3                   # Insufficient nvidia.com/gpu
```

**With HAMi**
```bash
kubectl -n demo delete deploy image                                   # the Pending pod goes first (see Known quirks)
kubectl -n kube-system delete ds nvidia-device-plugin-daemonset
kubectl label node --all gpu=on
kubectl get node -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu' -w   # wait for 10
kubectl -n hami-system get pods                                       # hami-device-plugin 2/2 Running
kubectl apply -f k8s/chat-hami.yaml -f k8s/image-hami.yaml && kubectl -n demo get pod -w
kubectl -n demo exec deploy/chat -- nvidia-smi                        # 4000 MiB total
kubectl -n demo exec deploy/image -- nvidia-smi                       # 10000 MiB total
```

**The fence**
```bash
kubectl apply -f k8s/greedy.yaml && kubectl -n demo logs -f greedy   # REFUSED, out of GPU memory
kubectl apply -f k8s/too-big.yaml && kubectl -n demo get pod too-big # Pending: no 4 GB slice left
```

Back to the start: `./demo.sh reset`. Remove everything: `kubectl delete ns demo`.

**Another Kubernetes version:** HAMi's scheduler runs a `kube-scheduler` image that must match your cluster.
Set `KUBE_VERSION` in [versions.env](versions.env) and the `kubeScheduler` image tag + digest in
[hami-values.yaml](hami-values.yaml); `hami.sh` stops if they don't match.

**A smaller card:** the image pod needs ~7 GB inside its slice, chat ~3 GB. For a 12 GB card, e.g. chat 3500 and
image 8000 in `k8s/*-hami.yaml` (untested; only 16 GB was run), and keep greedy's slice below the ~3 GB it tries
to load. Check a slice with `k8s/fence-test.yaml` (HAMi on). Under ~10 GB the image model doesn't fit next to chat.

**Check the GPU first:** `kubectl apply -f k8s/gpu-test.yaml` (without HAMi) runs `nvidia-smi` in a pod.

## Files

| Path | What |
|---|---|
| `setup.sh` | One-time setup: models, HAMi (idle), `kubectl` alias, then `demo.sh reset` |
| `demo.sh` | `reset` (back to the start, heals pods after a reboot), `status`, `heal`, `hammer [min]` (both pages under load) |
| `hami.sh`, `hami-values.yaml` | HAMi v2.10.0 via Helm, installed idle |
| `models.lock`, `fetch-models.sh` | Pinned models; downloads what's missing (`NIGHT_ONLY=1` for a nightly window, with `demo-fetch-models.*`) |
| `versions.env` | Pinned versions and image digests |
| `k8s/services.yaml` | Namespace `demo` + NodePorts 30080 (chat) / 30081 (image) |
| `k8s/chat.yaml`, `k8s/image.yaml` | Without HAMi: each asks for the whole GPU |
| `k8s/chat-hami.yaml`, `k8s/image-hami.yaml` | With HAMi: the same, with a memory slice |
| `k8s/greedy.yaml`, `k8s/too-big.yaml` | Refused by the fence / by the scheduler |
| `k8s/device-plugin.yaml` | NVIDIA device plugin v0.20.1 (without HAMi) |
| `k8s/gpu-test.yaml`, `k8s/fence-test.yaml` | Setup checks: GPU in a pod; HAMi's fence on your card |

## Known quirks

- **Reset between runs.** When HAMi goes idle its plugin leaves its registration on the node; stale, it lets the
  scheduler place a pod before the plugin is back, and HAMi's node lock then blocks the next pod for 5 minutes.
  `demo.sh reset` wipes it.
- **Order when switching to HAMi**: delete the Pending image deployment first (otherwise the plain scheduler
  places it on HAMi's device and the kubelet rejects it: `UnexpectedAdmissionError`), and apply the HAMi pods
  once the node shows 10 GPUs (pods created while HAMi is starting sit Pending, `node unregistered`, for up to
  5 minutes; deleting them recreates them straight away).
- **First image on a new card can take ~1.5 min**: the `sd-server` image is a CUDA 12.6 build, and newer cards
  (Blackwell) compile its kernels on first use. The compiled cache is kept on the host, so it's once.
- **`sd-server` is pinned to a `master-cuda` digest**: upstream publishes no versioned images.
- **Disk over 85%**: the kubelet deletes unused images; `demo.sh reset` re-pulls them and prints the disk use.

## Models and licences

The repo has no model weights; `fetch-models.sh` downloads them from Hugging Face at pinned commits.
[Qwen3-1.7B-GGUF](https://huggingface.co/Qwen/Qwen3-1.7B-GGUF) is Apache-2.0.
[SDXL-Turbo](https://huggingface.co/stabilityai/sdxl-turbo) comes under Stability AI's own licence: read its
model card before using it beyond a demo.

## Credits

[HAMi](https://github.com/Project-HAMi/HAMi) · [llama.cpp](https://github.com/ggml-org/llama.cpp) ·
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) ·
[NVIDIA k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) · [k3s](https://k3s.io) ·
[Qwen3](https://huggingface.co/Qwen) · [SDXL-Turbo](https://huggingface.co/stabilityai/sdxl-turbo)

## Licence

[Apache-2.0](LICENSE). The images and models it pulls have their own licences.
