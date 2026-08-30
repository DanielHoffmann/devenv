# Qwen3.5-9B (MTP) on llama.cpp with Podman — 10 GB VRAM

Local setup for **Qwen3.5-9B** (Alibaba, Feb 2026) served by `llama-server` in a Podman
container, with the built-in chat web UI, **thinking mode on**, listening on **port 8111**,
reachable from the local network. The model is downloaded to the host once and mounted in
from `~/models`.

This uses the **MTP (multi-token prediction) build** for self-speculative decoding —
roughly 1.5–2x faster inference with no accuracy loss.

Two things to know up front:

- MTP does **not** support `--mmproj` or `-np > 1`. So this is a **single-user, text-only**
  setup: no image input, one request at a time. That is the right trade for a personal chat
  UI, but if you need vision or concurrency, use the plain `unsloth/Qwen3.5-9B-GGUF` repo
  with its `mmproj-F16.gguf` and drop the MTP flags.
- For the small Qwen3.5 models (0.8B / 2B / 4B / 9B), **reasoning is disabled by default**.
  It has to be switched on explicitly, which this config does.

---

## 1. Prerequisites

- Podman, rootless is fine
- NVIDIA driver + `nvidia-container-toolkit` installed on the host
- ~7 GB free disk in `~/models`
- 10 GB VRAM (RTX 3080 class)

### Give Podman access to the GPU

Podman uses CDI, not Docker's `--gpus all`:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list          # should list nvidia.com/gpu=all
```

Verify the GPU is visible inside a container:

```bash
podman run --rm \
  --device nvidia.com/gpu=all \
  --security-opt=label=disable \
  ghcr.io/ggml-org/llama.cpp:server-cuda nvidia-smi
```

`--security-opt=label=disable` is required on SELinux systems (Fedora, RHEL, Bazzite).
On Ubuntu/Debian you can drop it — but then add `:Z` to the volume mount so the model
directory gets relabelled, i.e. `-v "$HOME/models:$HOME/models:ro,Z"`.

---

## 2. Download the model to `~/models`

Install the Hugging Face CLI once:

```bash
pip install -U huggingface_hub hf_transfer
```

Then pull the MTP GGUF. No `mmproj` is fetched, since MTP can't use it:

```bash
mkdir -p ~/models

hf download unsloth/Qwen3.5-9B-MTP-GGUF \
  --local-dir ~/models/Qwen3.5-9B-MTP-GGUF \
  --include "*UD-Q4_K_XL*"
```

Confirm the exact filename before wiring it into the run command — it's referenced verbatim below:

```bash
ls -lh ~/models/Qwen3.5-9B-MTP-GGUF/
# expected: Qwen3.5-9B-MTP-UD-Q4_K_XL.gguf   (~6 GB)
```

If a download stalls, `HF_HUB_ENABLE_HF_TRANSFER=0 hf download ...` is the usual fix.

### Why Q4 on 10 GB

Unsloth's memory table for the 9B (weights + overhead): 3-bit 5.5 GB, 4-bit 6.5 GB,
6-bit 9 GB, 8-bit 13 GB.

| Quant           | Fits 10 GB?    | Notes                                                  |
| --------------- | -------------- | ------------------------------------------------------ |
| `UD-Q4_K_XL`    | ✅ recommended | ~3 GB left for context, MTP draft head, compute buffers |
| `UD-Q5_K_XL`    | ⚠️ tight       | workable text-only at ≤ 32k context                     |
| `UD-Q6_K_XL`    | ❌             | ~9 GB of weights alone, no room to run                  |
| `Q8_0` / `BF16` | ❌             | 13 GB / 19 GB                                           |

Qwen3.5 is a hybrid of Gated DeltaNet and full-attention layers, so only a minority of
layers keep a context-scaled KV cache. Long context costs much less VRAM here than on a
conventional dense 9B. Skipping the vision projector frees roughly another gigabyte.

---

## 3. The run command, annotated

Save as `start-qwen.sh`, `chmod +x start-qwen.sh`, run it. The array form is used so every
flag can carry its own comment and still be copy-pasteable (a `#` comment cannot follow a
`\` line-continuation in shell).

```bash
#!/usr/bin/env bash
set -euo pipefail

# Same path on host and inside the container, so nothing has to be translated.
MODEL_DIR="$HOME/models"
MODEL="$MODEL_DIR/Qwen3.5-9B-MTP-GGUF/Qwen3.5-9B-MTP-UD-Q4_K_XL.gguf"

# ---------------------------------------------------------------------------
# Podman-level options: how the container itself is wired up
# ---------------------------------------------------------------------------
podman_args=(
  -d                                   # detached; use `podman logs -f llama-qwen35` to watch
  --name llama-qwen35                  # stable name for start/stop/logs
  --device nvidia.com/gpu=all          # CDI GPU passthrough (Podman's answer to --gpus all)
  --security-opt=label=disable         # SELinux: let the container touch /dev/nvidia*; drop on Ubuntu
  -p 8111:8111                         # publish on ALL host interfaces -> reachable from the LAN
                                       #   (use -p 127.0.0.1:8111:8111 to keep it local-only)
  -v "$MODEL_DIR:$MODEL_DIR:ro"        # mount ~/models read-only at the same path in the container.
                                       #   Rootless Podman maps container-root to your host user,
                                       #   so the files are readable as-is. Read-only because
                                       #   llama-server never needs to write here.
)

# ---------------------------------------------------------------------------
# llama-server options: everything after the image name is passed to the server
# ---------------------------------------------------------------------------
server_args=(
  -m "$MODEL"                          # load from the mounted volume — no Hugging Face access at runtime
  --alias qwen3.5-9b                   # the model id reported at GET /v1/models
  --host 0.0.0.0                       # bind inside the container to all interfaces.
                                       #   Without this the published port hits nothing.
  --port 8111                          # matches the -p mapping above
  -ngl 99                              # offload every layer to the GPU (99 = "all of them")
  -c 32768                             # context window. Native max is 262144 — leaving this
                                       #   unset would try to allocate the whole thing.
  -fa on                               # flash attention: faster, smaller KV cache
  --jinja                              # use the GGUF's own chat template; required for
                                       #   thinking mode and tool calling to parse correctly
  --chat-template-kwargs '{"--reasoning": "on"}'
                                       # THINKING MODE ON. Qwen3.5 Small disables it by default.
  -np 1                                # one slot. MTP does not support -np > 1.
  --spec-type draft-mtp                # use the model's built-in multi-token-prediction head
                                       #   as the draft model for speculative decoding
  --spec-draft-n-max 6                 # tokens drafted per step; 6 is Unsloth's figure for the 9B.
                                       #   Lower it if acceptance is poor on your workload.
  --temp 0.6                           # \
  --top-p 0.95                         #  | Qwen's recommended thinking-mode samplers
  --top-k 20                           #  | (precise / coding profile). See §5 for the
  --min-p 0.0                          # /  general-chat variant.
)

podman run "${podman_args[@]}" \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
  "${server_args[@]}"
```

Plain one-liner equivalent, if you'd rather paste directly into a shell:

```bash
podman run -d --name llama-qwen35 \
  --device nvidia.com/gpu=all \
  --security-opt=label=disable \
  -p 8111:8111 \
  -v "$HOME/models:$HOME/models:ro" \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -m "$HOME/models/Qwen3.5-9B-MTP-UD-Q4_K_XL.gguf" \
    --alias qwen3.5-9b \
    --host 0.0.0.0 --port 8111 \
    -ngl 99 -c 32768 -fa on --jinja \
    --chat-template-kwargs '{"--reasoning": "on"}' \
    -np 1 --spec-type draft-mtp --spec-draft-n-max 6 \
    --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0
```

Check it came up:

```bash
podman logs -f llama-qwen35     # look for "server is listening on http://0.0.0.0:8111"
```

A `failed to open` error here almost always means the path inside the container doesn't
match — verify with `podman exec llama-qwen35 ls ~/models/Qwen3.5-9B-MTP-GGUF/`.

---

## 4. Reaching it from the local network

**Open the firewall** on the host:

```bash
# firewalld (Fedora, RHEL)
sudo firewall-cmd --add-port=8111/tcp --permanent && sudo firewall-cmd --reload

# ufw (Ubuntu, Debian)
sudo ufw allow 8111/tcp
```

**Find your LAN address:**

```bash
hostname -I | awk '{print $1}'
```

Then browse to `http://<that-ip>:8111` from any device on the network. The chat UI is served
at the root and is on by default — no flag needed. (The toggle is `--ui` / `--no-ui`; the
older `--webui` / `--no-webui` names still work as deprecated aliases.)

**Add a key**, since the server is now exposed beyond localhost:

```
    --api-key <some-long-random-string>
```

The web UI prompts for it and stores it in the browser; API clients send it as a bearer
token. This is not a substitute for keeping port 8111 off the public internet.

---

## 5. Tuning

### Sampler profiles

Thinking mode is on, so use one of these. `presence_penalty` is optional — raise it only if
you see repetition, since higher values cost a little quality.

| Profile                  | temp | top-p | top-k | min-p |
| ------------------------ | ---- | ----- | ----- | ----- |
| Thinking, coding/precise | 0.6  | 0.95  | 20    | 0.0   |
| Thinking, general chat   | 1.0  | 0.95  | 20    | 0.0   |

To turn thinking **off** again, flip the flag to
`--chat-template-kwargs '{"--reasoning": "on"}'` and switch to temp 0.7 / top-p 0.8.

### Gotcha: the web UI overrides your samplers

The chat UI sends its own sampler values with each request, and those take precedence over
the `--temp` etc. set on the command line. Set them in the UI's settings panel too, or the
CLI values won't be the ones in effect. The CLI values still apply to raw API clients.

### MTP tuning

Speculative decoding only pays off when drafts get accepted. Watch the acceptance rate in
the server log; if it's low, lower `--spec-draft-n-max` to 4 or 3. Highly repetitive or
templated output accepts well, high-temperature creative writing accepts poorly. Since
`-np 1` is forced, a second concurrent request queues rather than running in parallel.

### Context size

32k is comfortable at Q4 with no vision projector loaded. You can push to 65536 or beyond.
Check the `KV cache` and `compute buffer` lines in `podman logs llama-qwen35` against
`nvidia-smi` and back off if you're near the ceiling — leave ~1 GB free if this GPU also
drives your desktop.

If output turns to gibberish, context is usually set too low for what's being fed in;
`--cache-type-k bf16 --cache-type-v bf16` is the other thing to try.

### Other backends

- **AMD:** `ghcr.io/ggml-org/llama.cpp:server-rocm` (or `:server-vulkan`), and replace the
  CDI device with `--device /dev/kfd --device /dev/dri`.
- **CUDA 13 host:** `:server-cuda13`.
- **Pinning:** llama.cpp has no semantic versions, just incrementing build tags — use
  something like `:server-cuda12-b9603` instead of tracking the rolling tag. MTP support is
  recent, so don't pin to anything old.

---

## 6. Everyday commands

```bash
podman logs -f llama-qwen35            # follow server output
podman stop llama-qwen35               # stop
podman start llama-qwen35              # start again
podman rm -f llama-qwen35              # remove the container (~/models is untouched)
podman pull ghcr.io/ggml-org/llama.cpp:server-cuda   # update image, then rm -f and re-run
```

Smoke-test the API:

```bash
curl http://localhost:8111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-9b","messages":[{"role":"user","content":"What is 2+2?"}]}'
```

With thinking on, the chain of thought comes back in `message.reasoning_content` and the
answer in `message.content`.