#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
GPU_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.gpu.yml"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

die() { echo "${RED}${BOLD}ERROR:${RESET} $*" >&2; exit 1; }
warn() { echo "${YELLOW}${BOLD}WARN:${RESET} $*" >&2; }
info() { echo "${BLUE}${BOLD}INFO:${RESET} $*"; }
ok() { echo "${GREEN}${BOLD}OK:${RESET} $*"; }

usage() {
  cat <<'EOF'
Usage:
  ./run-ace.sh test
  ./run-ace.sh pull
  ./run-ace.sh start
  ./run-ace.sh restart
  ./run-ace.sh stop
  ./run-ace.sh down
  ./run-ace.sh logs

CPU/GPU is controlled only by .env:

GPU:
  ACE_PROFILE=gpu
  ACESTEP_DEVICE=cuda

CPU:
  ACE_PROFILE=cpu
  ACESTEP_DEVICE=cpu
EOF
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die ".env not found: ${ENV_FILE}"

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  : "${PROJECT_NAME:?PROJECT_NAME is required}"
  : "${SERVICE_NAME:?SERVICE_NAME is required}"
  : "${ACE_IMAGE_REF:?ACE_IMAGE_REF is required}"
  : "${ACE_PROFILE:?ACE_PROFILE is required: gpu or cpu}"
  : "${ACE_DATA_DIR:?ACE_DATA_DIR is required}"
  : "${HOST_UID:?HOST_UID is required}"
  : "${HOST_GID:?HOST_GID is required}"
  : "${ACE_HOST:?ACE_HOST is required}"
  : "${ACE_PORT:?ACE_PORT is required}"
  : "${ACESTEP_DEVICE:?ACESTEP_DEVICE is required: cuda or cpu}"
  : "${ACESTEP_OUTPUT_DIR:?ACESTEP_OUTPUT_DIR is required}"
  : "${ACESTEP_CONFIG_PATH:?ACESTEP_CONFIG_PATH is required}"
  : "${ACESTEP_LM_MODEL_PATH:?ACESTEP_LM_MODEL_PATH is required}"
  : "${ACESTEP_LM_BACKEND:?ACESTEP_LM_BACKEND is required}"
  : "${HF_HOME:?HF_HOME is required}"
  : "${TORCH_HOME:?TORCH_HOME is required}"
  : "${XDG_CACHE_HOME:?XDG_CACHE_HOME is required}"
  : "${RESTART_POLICY:?RESTART_POLICY is required}"
  : "${SHM_SIZE:?SHM_SIZE is required}"
  : "${LOG_MAX_SIZE:?LOG_MAX_SIZE is required}"
  : "${LOG_MAX_FILE:?LOG_MAX_FILE is required}"
  : "${LOG_TAIL:?LOG_TAIL is required}"
  : "${TZ:?TZ is required}"

  case "${ACE_PROFILE}" in
    gpu|cpu) ;;
    *) die "ACE_PROFILE must be gpu or cpu, got: ${ACE_PROFILE}" ;;
  esac

  case "${ACESTEP_DEVICE}" in
    cuda|cpu) ;;
    *) die "ACESTEP_DEVICE must be cuda or cpu, got: ${ACESTEP_DEVICE}" ;;
  esac

  if [[ "${ACE_PROFILE}" == "gpu" && "${ACESTEP_DEVICE}" != "cuda" ]]; then
    die "Invalid .env: ACE_PROFILE=gpu requires ACESTEP_DEVICE=cuda"
  fi

  if [[ "${ACE_PROFILE}" == "cpu" && "${ACESTEP_DEVICE}" != "cpu" ]]; then
    die "Invalid .env: ACE_PROFILE=cpu requires ACESTEP_DEVICE=cpu"
  fi
}

detect_docker() {
  command -v docker >/dev/null 2>&1 || die "docker command not found"

  if docker info >/dev/null 2>&1; then
    DOCKER="docker"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    die "Docker daemon not accessible. Add your user to docker group or use sudo."
  fi

  if ${DOCKER} compose version >/dev/null 2>&1; then
    COMPOSE="${DOCKER} compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  else
    die "Docker Compose not found. Install docker compose plugin."
  fi

  build_compose_args
}

data_root() {
  case "${ACE_DATA_DIR}" in
    /*) printf '%s\n' "${ACE_DATA_DIR}" ;;
    ./*) printf '%s\n' "${SCRIPT_DIR}/${ACE_DATA_DIR#./}" ;;
    *) printf '%s\n' "${SCRIPT_DIR}/${ACE_DATA_DIR}" ;;
  esac
}

# Populated by build_compose_args() after load_env + detect_docker
COMPOSE_ARGS=()

build_compose_args() {
  COMPOSE_ARGS=(--env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
  if [[ "${ACE_PROFILE}" == "gpu" ]]; then
    [[ -f "${GPU_COMPOSE_FILE}" ]] || die "Missing GPU override file: ${GPU_COMPOSE_FILE}"
    COMPOSE_ARGS+=(-f "${GPU_COMPOSE_FILE}")
  fi
}

compose() {
  ${COMPOSE} "${COMPOSE_ARGS[@]}" "$@"
}

ensure_dirs() {
  local root
  root="$(data_root)"

  mkdir -p \
    "${root}/output" \
    "${root}/hf-cache" \
    "${root}/torch-cache" \
    "${root}/cache"

  if [[ "$(id -u)" == "0" ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${root}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo chown -R "${HOST_UID}:${HOST_GID}" "${root}" || \
      warn "Could not chown ${root}. Fix manually: sudo chown -R ${HOST_UID}:${HOST_GID} ${root}"
  else
    warn "sudo unavailable; skipping ownership fix for ${root}"
  fi

  ok "Persistence ready: ${root}"
}

check_port() {
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn "( sport = :${ACE_PORT} )" | grep -q ":${ACE_PORT}"; then
      warn "Port ${ACE_PORT} already appears to be in use"
    fi
  fi
}

cmd_test() {
  load_env
  detect_docker

  echo
  info "Configuration"
  echo "  project        : ${PROJECT_NAME}"
  echo "  service        : ${SERVICE_NAME}"
  echo "  image          : ${ACE_IMAGE_REF}"
  echo "  profile        : ${ACE_PROFILE}"
  echo "  device         : ${ACESTEP_DEVICE}"
  echo "  uid:gid        : ${HOST_UID}:${HOST_GID}"
  echo "  data dir       : $(data_root)"
  echo "  bind           : ${ACE_HOST}:${ACE_PORT}"
  echo "  shm            : ${SHM_SIZE}"
  echo "  output dir     : ${ACESTEP_OUTPUT_DIR}"
  echo "  config path    : ${ACESTEP_CONFIG_PATH}"
  echo "  lm model path  : ${ACESTEP_LM_MODEL_PATH}"
  echo "  lm backend     : ${ACESTEP_LM_BACKEND}"

  echo
  info "Docker access"
  ${DOCKER} version >/dev/null
  ok "Docker accessible"

  echo
  info "Compose validation"
  compose config >/dev/null
  ok "Compose config valid"

  echo
  info "Persistence check"
  ensure_dirs

  echo
  info "Port check"
  check_port

  echo
  info "Local image check"
  if ${DOCKER} image inspect "${ACE_IMAGE_REF}" >/dev/null 2>&1; then
    ok "Image exists locally: ${ACE_IMAGE_REF}"
  else
    warn "Image not found locally: ${ACE_IMAGE_REF}"
    echo "  This script does not auto-pull."
    echo "  Pull explicitly:"
    echo "    ${DOCKER} pull ${ACE_IMAGE_REF}"
  fi

  if [[ "${ACE_PROFILE}" == "gpu" ]]; then
    echo
    info "NVIDIA check"

    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
    else
      warn "nvidia-smi not found on host"
    fi

    if ${DOCKER} run --rm --gpus all --entrypoint "" "${ACE_IMAGE_REF}" \
        sh -c 'test -e /dev/nvidiactl' 2>/dev/null; then
      ok "Docker NVIDIA runtime works"
    else
      warn "Docker NVIDIA runtime failed"
      echo "  Recommended fix:"
      echo "    sudo apt install -y nvidia-container-toolkit"
      echo "    sudo systemctl restart docker"
      echo "    ${DOCKER} run --rm --gpus all --entrypoint \"\" ${ACE_IMAGE_REF} sh -c 'test -e /dev/nvidiactl'"
    fi
  fi

  ok "Test completed"
}

cmd_start() {
  load_env
  detect_docker
  ensure_dirs
  check_port

  info "Starting ACE-Step: profile=${ACE_PROFILE}, device=${ACESTEP_DEVICE}"
  compose up -d

  ok "Started"
  local display_host="${ACE_HOST}"
  [[ "${ACE_HOST}" == "0.0.0.0" ]] && display_host="127.0.0.1"
  echo "  URL: http://${display_host}:${ACE_PORT}"
}

cmd_restart() {
  load_env
  detect_docker

  info "Restarting ACE-Step"
  compose restart
  ok "Restarted"
}

cmd_stop() {
  load_env
  detect_docker

  info "Stopping ACE-Step"
  compose stop
  ok "Stopped"
}

cmd_down() {
  load_env
  detect_docker

  info "Removing container/network; persisted data is kept"
  compose down
  ok "Down complete"
}

cmd_pull() {
  load_env
  detect_docker

  info "Pulling image: ${ACE_IMAGE_REF}"
  ${DOCKER} pull "${ACE_IMAGE_REF}"
  ok "Pull complete"
}

cmd_logs() {
  load_env
  detect_docker

  compose logs -f --tail="${LOG_TAIL}"
}

main() {
  case "${1:-}" in
    test) cmd_test ;;
    pull) cmd_pull ;;
    start) cmd_start ;;
    restart) cmd_restart ;;
    stop) cmd_stop ;;
    down) cmd_down ;;
    logs) cmd_logs ;;
    ""|-h|--help|help) usage ;;
    *) usage; die "Unknown command: ${1}" ;;
  esac
}

main "$@"