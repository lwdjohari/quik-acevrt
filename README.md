# quik-acevrt

Minimal, production-hardened Docker runtime for the
[`valyriantech/ace-step-1.5-xl`](https://hub.docker.com/r/valyriantech/ace-step-1.5-xl)
image. Supports GPU (CUDA) and CPU modes via a single `.env` flag, with fully
deterministic image pinning and host-mapped persistence for all generated
content, models, and caches.

---

## Requirements

| Dependency | Notes |
|---|---|
| Docker Engine ≥ 24 | `docker compose` plugin must be available |
| NVIDIA Container Toolkit | GPU mode only — see [setup](#gpu-prerequisites) |
| `bash` ≥ 4.2 | Ships with every modern Linux distro |
| `ss` | Optional — used for port-conflict detection |

---

## Quick start

```bash
# 1. Clone / enter the project
cd quik-acevrt

# 2. Copy and edit configuration
cp .env.example .env
$EDITOR .env          # set HOST_UID, HOST_GID, ACE_PROFILE, ACE_PORT at minimum

# 3. Pull the image once
./run-ace.sh pull

# 4. Validate everything before first run
./run-ace.sh test

# 5. Start
./run-ace.sh start
```

The web UI is available at `http://127.0.0.1:<ACE_PORT>` (default `8000`).

---

## Configuration (`.env`)

Copy `.env.example` to `.env` and adjust values. The table below covers the
most important knobs.

| Variable | Default | Description |
|---|---|---|
| `ACE_PROFILE` | `gpu` | Runtime profile: `gpu` or `cpu` |
| `ACESTEP_DEVICE` | `cuda` | Torch device: `cuda` or `cpu` — must match `ACE_PROFILE` |
| `ACESTEP_OUTPUT_DIR` | `/app/outputs` | Generated audio output directory inside container |
| `ACESTEP_CONFIG_PATH` | `/app/checkpoints/acestep-v15-xl-base` | Path to XL DiT model — defaults to baked-in checkpoint |
| `ACESTEP_LM_MODEL_PATH` | `/app/checkpoints/acestep-5Hz-lm-1.7B` | Path to LM model — defaults to baked-in checkpoint |
| `ACESTEP_LM_BACKEND` | `pt` | LLM backend: `pt` (PyTorch) or `vllm` |
| `HOST_UID` / `HOST_GID` | `1000` | UID/GID used inside the container (`user:` mapping) |
| `ACE_HOST` | `0.0.0.0` | Host interface to bind the port on |
| `ACE_PORT` | `8000` | Host port exposed to the browser |
| `ACE_DATA_DIR` | `./data` | Root for all bind-mounted host directories |
| `ACE_IMAGE_REF` | `valyriantech/ace-step-1.5-xl:14042026` | Exact image reference — pin to a digest for full reproducibility |
| `RESTART_POLICY` | `unless-stopped` | Docker restart policy |
| `SHM_SIZE` | `8g` | `/dev/shm` size — increase for larger batch workloads |
| `LOG_TAIL` | `200` | Number of log lines shown by `./run-ace.sh logs` |
| `TZ` | `Asia/Jakarta` | Timezone inside the container |

> **Never commit `.env`** — it is excluded by `.gitignore`.

### GPU vs CPU

**GPU (default):**
```env
ACE_PROFILE=gpu
ACESTEP_DEVICE=cuda
```

**CPU:**
```env
ACE_PROFILE=cpu
ACESTEP_DEVICE=cpu
```

The script enforces that both variables are consistent and rejects any mismatch
at startup.

---

## Commands

```
./run-ace.sh test       Validate config, Docker access, dirs, port, and image
./run-ace.sh pull       Explicitly pull the pinned image from the registry
./run-ace.sh start      Create dirs, check port, then docker compose up -d
./run-ace.sh restart    docker compose restart (no data loss)
./run-ace.sh stop       docker compose stop   (container kept, restartable)
./run-ace.sh down       docker compose down   (container removed, data kept)
./run-ace.sh logs       Tail last $LOG_TAIL log lines (Ctrl-C to exit)
```

---

## Persistence layout

All state lives under `ACE_DATA_DIR` (default `./data/`) on the host, so
`down` and image upgrades never touch your data.

```
data/
├── output/       ← generated audio files  ($ACESTEP_OUTPUT_DIR → /app/outputs)
├── hf-cache/     ← Hugging Face cache     ($HF_HOME)
├── torch-cache/  ← Torch hub cache        ($TORCH_HOME)
└── cache/        ← XDG general cache      ($XDG_CACHE_HOME)
```

> **Models are baked into the image** (~20 GB) at `/app/checkpoints/`. You do
> not need to mount a model directory. To persist models across image rebuilds,
> uncomment the optional model volume lines in `docker-compose.yml` and
> pre-populate `data/models/config` and `data/models/lm` before first start.

---

## GPU prerequisites

1. Install NVIDIA Container Toolkit:
   ```bash
   sudo apt install -y nvidia-container-toolkit
   sudo systemctl restart docker
   ```

2. Verify the runtime works end-to-end:
   ```bash
   # Uses the actual ACE-Step image — no extra pull needed after ./run-ace.sh pull
   docker run --rm --gpus all --entrypoint "" valyriantech/ace-step-1.5-xl:14042026 \
     sh -c 'test -e /dev/nvidiactl && echo GPU OK'
   ```

3. Run `./run-ace.sh test` — it performs both the host `nvidia-smi` check and
   the Docker GPU device passthrough check and reports any missing pieces.

---

## Compose file layout

| File | Purpose |
|---|---|
| `docker-compose.yml` | Base service definition (CPU and GPU) |
| `docker-compose.gpu.yml` | GPU overlay — merged automatically when `ACE_PROFILE=gpu` |

Merging is handled transparently by `run-ace.sh`; you never need to pass `-f`
flags manually.

---

## Security

- Container runs as `HOST_UID:HOST_GID` — not root.
- `security_opt: no-new-privileges:true` is set on the service.
- `.env` is `.gitignore`d — secrets stay off version control.
- Image is pinned by tag (`ACE_IMAGE_REF`). For maximum reproducibility, pin
  to a full digest:
  ```bash
  # Get the digest after pulling
  docker image inspect valyriantech/ace-step-1.5-xl:14042026 \
    --format '{{index .RepoDigests 0}}'
  # Then set in .env:
  # ACE_IMAGE_REF=valyriantech/ace-step-1.5-xl@sha256:<DIGEST>
  ```

---

## Healthcheck

The container reports `healthy` once `http://127.0.0.1:8000/health` responds
with HTTP 200. Docker polls every 30 s with up to 10 retries and a 120 s grace
period, giving the model time to load before the first probe.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Docker daemon not accessible` | `sudo usermod -aG docker $USER && newgrp docker` |
| `Docker Compose not found` | `sudo apt install docker-compose-plugin` |
| `Docker NVIDIA runtime failed` | Install `nvidia-container-toolkit` and restart Docker |
| Port already in use | Change `ACE_PORT` in `.env` or stop the conflicting process |
| `Permission denied` on `data/` | `sudo chown -R $(id -u):$(id -g) ./data` |
| Container stays `unhealthy` | Check logs: `./run-ace.sh logs`; GPU OOM may require smaller `SHM_SIZE` |

