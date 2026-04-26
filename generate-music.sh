#!/usr/bin/env bash
# generate-music.sh - ACE-Step music generation CLI (bash + aria2)
# Submits a task, polls until complete, downloads via aria2.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Colours - only when connected to a terminal (clean piped/logged output)
# ---------------------------------------------------------------------------
if [[ -t 1 && -t 2 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

# printf '%b' interprets \n escape sequences in message strings
die()  { printf '%b\n' "${RED}${BOLD}ERROR:${RESET} $*" >&2; exit 1; }
warn() { printf '%b\n' "${YELLOW}${BOLD}WARN:${RESET}  $*" >&2; }
info() { printf '%b\n' "${BLUE}${BOLD}INFO:${RESET}  $*"; }
ok()   { printf '%b\n' "${GREEN}${BOLD}OK:${RESET}    $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
API_URL="http://127.0.0.1:8000"
CAPTION=""
LYRICS=""
LYRICS_FILE=""
DURATION=90
BATCH_SIZE=1
OUTPUT="output.mp3"
POLL_INTERVAL=5
TIMEOUT=600
QUIET=0
SHOW_LYRICS_HELP=0
SHOW_CAPTION_HELP=0
EFFECTIVE_LYRICS=""     # resolved in main() from --lyrics or --lyrics-file

# ---------------------------------------------------------------------------
# Help / guides
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  ./generate-music.sh [OPTIONS]

Options:
  -u, --api-url URL         API base URL (default: http://127.0.0.1:8000)
  -c, --caption TEXT        Music style description (required)
  -l, --lyrics TEXT         Song lyrics (use \n for newlines)
  -f, --lyrics-file FILE    Path to a lyrics text file
  -d, --duration SECS       Duration in seconds (default: 90)
  -b, --batch-size N        Number of variations (default: 1)
  -o, --output FILE         Output file or dir (default: output.mp3)
      --poll-interval SECS  Poll interval (default: 5)
      --timeout SECS        Max wait time (default: 600)
  -q, --quiet               Suppress progress output
      --lyrics-help         Show lyrics writing guide
      --caption-help        Show caption/style writing guide
  -h, --help                Show this help

Examples:
  ./generate-music.sh \
    --caption "Dreamy indie folk with acoustic guitar and soft female vocals" \
    --lyrics "[Verse 1]\nMidnight whispers through the trees\n\n[Chorus]\nWe are the dreamers" \
    --duration 90 \
    --output song.mp3

  ./generate-music.sh \
    --api-url http://192.168.1.10:8000 \
    --caption "Dark atmospheric electronic" \
    --lyrics-file my_lyrics.txt \
    --batch-size 3 \
    --output batch/
EOF
}

lyrics_help() {
  cat <<'EOF'
=== LYRICS STRUCTURE GUIDE ===

Use structure tags to organise your song:

  [Intro]        Instrumental opening
  [Verse 1]      First verse (use [Verse 2], [Verse 3], etc.)
  [Pre-Chorus]   Build-up before chorus
  [Chorus]       Main hook - usually repeated
  [Bridge]       Contrasting section, often before final chorus
  [Outro]        Ending section
  [Drop]         Electronic - main beat drop
  [Break]        Instrumental break
  [Hook]         Short catchy phrase

Example:
  [Verse 1]
  Walking down the empty street
  Shadows dancing at my feet

  [Chorus]
  We are the dreamers of the night
  Chasing stars until the light

  [Bridge]
  And when the morning comes around
  We'll still be here, we won't back down

  [Outro]
  Dreamers of the night...

Tips:
  - Keep verses 2–4 lines each
  - Repeat the chorus for emphasis
  - Use [Instrumental] or [Solo] for non-vocal sections
  - Leave blank lines between sections
EOF
}

caption_help() {
  cat <<'EOF'
=== CAPTION / STYLE GUIDE ===

Describe the musical style - include:

  Genre       pop, rock, folk, electronic, jazz, hip-hop, classical …
  Instruments guitar, piano, synths, drums, strings, brass …
  Mood        upbeat, melancholic, energetic, peaceful, dark, hopeful …
  Tempo       slow ballad, mid-tempo groove, fast-paced …
  Vocals      soft female, raspy male, choir, falsetto, no vocals …
  Production  lo-fi, polished, raw, atmospheric, reverb-heavy …

Examples:
  "Upbeat indie pop with jangly guitars, bright synths, and energetic female vocals"
  "Dark atmospheric electronic with deep bass, haunting pads, and whispered vocals"
  "Warm acoustic folk ballad with fingerpicked guitar and gentle strings"
  "High-energy rock anthem with distorted guitars, pounding drums, and powerful male vocals"
  "Dreamy lo-fi hip-hop beat with jazzy piano samples and vinyl crackle"
  "Epic orchestral cinematic piece with soaring strings, brass, and choir"

Tips:
  - Be specific about instruments and mood
  - Reference atmosphere (cozy, epic, intimate)
  - Time/setting helps (sunset, midnight, rainy day)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--api-url)       API_URL="${2:?--api-url requires a value}";       shift 2 ;;
      -c|--caption)       CAPTION="${2:?--caption requires a value}";        shift 2 ;;
      -l|--lyrics)        LYRICS="${2:?--lyrics requires a value}";          shift 2 ;;
      -f|--lyrics-file)   LYRICS_FILE="${2:?--lyrics-file requires a value}"; shift 2 ;;
      -d|--duration)      DURATION="${2:?--duration requires a value}";      shift 2 ;;
      -b|--batch-size)    BATCH_SIZE="${2:?--batch-size requires a value}";   shift 2 ;;
      -o|--output)        OUTPUT="${2:?--output requires a value}";           shift 2 ;;
         --poll-interval) POLL_INTERVAL="${2:?--poll-interval requires a value}"; shift 2 ;;
         --timeout)       TIMEOUT="${2:?--timeout requires a value}";         shift 2 ;;
      -q|--quiet)         QUIET=1;   shift ;;
         --lyrics-help)   SHOW_LYRICS_HELP=1;  shift ;;
         --caption-help)  SHOW_CAPTION_HELP=1; shift ;;
      -h|--help)          usage; exit 0 ;;
      *) die "Unknown option: $1\n\nRun ./generate-music.sh --help for usage." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  local missing=0

  # curl (used for POST - aria2 is download-only)
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found - required for API requests."
    echo "  Fix: sudo apt install -y curl"
    (( missing++ )) || true
  fi

  # aria2c
  if ! command -v aria2c >/dev/null 2>&1; then
    warn "aria2c not found - required for file download."
    echo "  Fix: sudo apt install -y aria2"
    (( missing++ )) || true
  fi

  # jq
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found - required for JSON parsing."
    echo "  Fix: sudo apt install -y jq"
    (( missing++ )) || true
  fi

  [[ $missing -eq 0 ]] || die "$missing required tool(s) missing. Install them and retry."

  # --caption required unless showing help
  [[ -n "${CAPTION}" ]] || die "--caption is required.\n\nRun ./generate-music.sh --caption-help for style guide."

  # Lyrics file exists if given
  if [[ -n "${LYRICS_FILE}" ]]; then
    [[ -f "${LYRICS_FILE}" ]] || die "Lyrics file not found: ${LYRICS_FILE}"
  fi

  # Validate and create output directory early - fail before waiting on generation
  local _out_dir
  if [[ "${OUTPUT}" == */ ]]; then
    _out_dir="${OUTPUT%/}"        # OUTPUT is itself the target directory
  else
    _out_dir="$(dirname "${OUTPUT}")"
  fi
  [[ -z "${_out_dir}" ]] && _out_dir="."
  mkdir -p "${_out_dir}" 2>/dev/null \
    || die "Cannot create output directory: ${_out_dir}\n  Check the path and your write permissions."
  [[ -w "${_out_dir}" ]] \
    || die "Output directory is not writable: ${_out_dir}\n  Check permissions."

  # Numeric validation
  [[ "${DURATION}"      =~ ^[0-9]+$ ]] || die "--duration must be a positive integer"
  [[ "${BATCH_SIZE}"    =~ ^[0-9]+$ ]] || die "--batch-size must be a positive integer"
  [[ "${POLL_INTERVAL}" =~ ^[0-9]+$ ]] || die "--poll-interval must be a positive integer"
  [[ "${TIMEOUT}"       =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer"
  [[ "${DURATION}"      -ge 5       ]] || die "--duration must be at least 5 seconds"
  [[ "${DURATION}"      -le 600     ]] || warn "--duration ${DURATION}s is unusually long (typical max ~300s)"
}

# ---------------------------------------------------------------------------
# HTTP helpers (curl)
# ---------------------------------------------------------------------------
api_post() {
  # api_post <url> <json-body> → response body to stdout; curl errors to stderr
  local url="$1" body="$2"
  curl --silent --show-error --fail-with-body \
    --max-time 60 \
    -H "Content-Type: application/json" \
    -H "User-Agent: ACE-Step-Bash/1.0" \
    -d "${body}" \
    "${url}"
}

api_get() {
  # api_get <url> → response body to stdout; curl errors to stderr
  local url="$1"
  curl --silent --show-error --fail-with-body \
    --max-time 60 \
    -H "User-Agent: ACE-Step-Bash/1.0" \
    "${url}"
}

# ---------------------------------------------------------------------------
# API operations
# ---------------------------------------------------------------------------
check_health() {
  local resp
  resp="$(api_get "${API_URL}/health" 2>/dev/null)" || return 1
  # status == "ok" anywhere in the json is sufficient
  echo "${resp}" | jq -e '.data.status == "ok"' >/dev/null 2>&1
}

submit_task() {
  local body
  body="$(jq -nc \
    --arg caption   "${CAPTION}" \
    --arg lyrics    "${EFFECTIVE_LYRICS}" \
    --argjson dur   "${DURATION}" \
    --argjson batch "${BATCH_SIZE}" \
    '{caption:$caption, lyrics:$lyrics, duration:$dur, batch_size:$batch}')"

  local resp
  resp="$(api_post "${API_URL}/release_task" "${body}")" \
    || die "Task submission failed.\n  URL: ${API_URL}/release_task\n  Cause: connection refused or server returned an HTTP error\n  Tip: run ./run-ace.sh logs to check server errors."

  local code
  code="$(echo "${resp}" | jq -r '.code // empty')"
  [[ "${code}" == "200" ]] \
    || die "Task submission rejected (code=${code:-unknown}).\n  Response: ${resp}\n  Tip: check --caption and --lyrics for unsupported characters."

  echo "${resp}" | jq -r '.data.task_id'
}

poll_task() {
  local task_id="$1"
  local start elapsed status resp task_json

  start=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start ))
    [[ ${elapsed} -lt ${TIMEOUT} ]] \
      || die "Timed out after ${TIMEOUT}s waiting for task ${task_id}.\n  Tip: increase --timeout or check server load with ./run-ace.sh logs."

    local body
    body="$(jq -nc --arg id "${task_id}" '{task_id_list:[$id]}')"
    resp="$(api_post "${API_URL}/query_result" "${body}")" \
      || { warn "Poll request failed (${elapsed}s) - retrying..."; sleep "${POLL_INTERVAL}"; continue; }

    local data_len
    data_len="$(echo "${resp}" | jq '.data | length' 2>/dev/null || echo 0)"

    if [[ "${data_len}" -eq 0 ]]; then
      [[ ${QUIET} -eq 1 ]] || info "Waiting for task to start... (${elapsed}s)"
      sleep "${POLL_INTERVAL}"
      continue
    fi

    task_json="$(echo "${resp}" | jq '.data[0]')"
    status="$(echo "${task_json}" | jq -r '.status // 0')"

    case "${status}" in
      1)  # success
          echo "${task_json}"
          return 0
          ;;
      2)  # failed
          local err
          err="$(echo "${task_json}" | jq -r '.error // "no detail"')"
          die "Generation failed on server: ${err}\n  Tip: check GPU memory - try a shorter --duration or restart with ./run-ace.sh restart."
          ;;
      *)  # in progress
          [[ ${QUIET} -eq 1 ]] || info "Generating... (${elapsed}s)"
          sleep "${POLL_INTERVAL}"
          ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Download via aria2
# ---------------------------------------------------------------------------
download_files() {
  local task_json="$1"
  local result_json file_url full_url output_path
  local -a downloaded=()

  result_json="$(echo "${task_json}" | jq -r '.result // empty')"
  [[ -n "${result_json}" && "${result_json}" != "null" ]] \
    || die "Server returned an empty result for the completed task.\n  Tip: run ./run-ace.sh logs to investigate."

  local count
  count="$(echo "${result_json}" | jq 'length' 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]] \
    || die "No audio files found in server result.\n  Tip: run ./run-ace.sh logs to investigate."

  [[ ${QUIET} -eq 1 ]] || info "Downloading ${count} audio file(s) via aria2..."

  # Common aria2c options (built once)
  local -a aria2_args=(
    --continue=true
    --max-connection-per-server=4
    --split=4
    --min-split-size=1M
    --file-allocation=none
    --console-log-level=warn
    --summary-interval=0
  )

  local i=0
  while IFS= read -r file_url; do
    [[ -n "${file_url}" ]] || continue

    full_url="${API_URL}${file_url}"

    # Determine output path
    if [[ "${OUTPUT}" == */ ]]; then
      # OUTPUT is a directory - derive filename from the API's file URL
      local api_stem api_ext
      api_stem="$(basename "${file_url%.*}")"
      api_ext="${file_url##*.}"
      [[ ${count} -eq 1 ]] \
        && output_path="${OUTPUT%/}/${api_stem}.${api_ext}" \
        || output_path="${OUTPUT%/}/${api_stem}_$((i+1)).${api_ext}"
    elif [[ ${count} -eq 1 ]]; then
      output_path="${OUTPUT}"
    else
      local stem ext
      stem="${OUTPUT%.*}"
      ext="${OUTPUT##*.}"
      [[ "${ext}" == "${OUTPUT}" ]] && ext="mp3"  # no extension given
      output_path="${stem}_$((i+1)).${ext}"
    fi

    # Ensure directory exists
    local out_dir out_file
    out_dir="$(dirname "${output_path}")"
    out_file="$(basename "${output_path}")"
    mkdir -p "${out_dir}"

    [[ ${QUIET} -eq 1 ]] || info "  → ${output_path}"

    local -a aria2_cmd=(aria2c --out="${out_file}" --dir="${out_dir}" "${aria2_args[@]}" "${full_url}")
    if [[ ${QUIET} -eq 1 ]]; then
      "${aria2_cmd[@]}" >/dev/null 2>&1
    else
      "${aria2_cmd[@]}"
    fi || die "Download failed for ${full_url}\n  Tip: check that the API is still running (./run-ace.sh logs)."

    downloaded+=("${output_path}")
    (( i++ )) || true
  done < <(echo "${result_json}" | jq -r '.[].file // empty')

  [[ ${QUIET} -eq 1 ]] || ok "Downloaded ${#downloaded[@]} file(s)."

  # Print absolute paths for scripting / piping
  for f in "${downloaded[@]}"; do
    echo "$(cd "$(dirname "${f}")" && pwd)/$(basename "${f}")"
  done
}

# ---------------------------------------------------------------------------
# Generation info (BPM, key, time)
# ---------------------------------------------------------------------------
print_generation_info() {
  local task_json="$1"
  local gen_info
  gen_info="$(echo "${task_json}" | jq -r '.result | fromjson | .[0].generation_info // empty' 2>/dev/null)" || true
  [[ -n "${gen_info}" ]] || return 0

  echo
  info "Generation info:"
  echo "${gen_info}" | grep -E 'BPM:|Key Scale:|Total Time:' \
    | sed 's/\*\*//g; s/^- /  /' \
    || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Show help guides and exit
  [[ ${SHOW_LYRICS_HELP}  -eq 0 ]] || { lyrics_help;  exit 0; }
  [[ ${SHOW_CAPTION_HELP} -eq 0 ]] || { caption_help; exit 0; }

  preflight

  # Resolve lyrics
  if [[ -n "${LYRICS_FILE}" ]]; then
    EFFECTIVE_LYRICS="$(<"${LYRICS_FILE}")"
  else
    # Expand \n escape sequences from command-line argument
    EFFECTIVE_LYRICS="${LYRICS//$'\\n'/$'\n'}"
  fi

  # Strip trailing slash from URL
  API_URL="${API_URL%/}"

  # Health check
  [[ ${QUIET} -eq 1 ]] || info "Connecting to ${API_URL}..."
  if ! check_health; then
    die "API is not responding at ${API_URL}/health\n\n  Recommendations:\n  1. Is the container running?  ./run-ace.sh start\n  2. Is it healthy?             ./run-ace.sh logs\n  3. Wrong port?                check ACE_PORT in .env\n  4. Remote host?               verify firewall / VPN"
  fi
  [[ ${QUIET} -eq 1 ]] || ok "API healthy."

  # Show task summary
  if [[ ${QUIET} -eq 0 ]]; then
    echo
    info "Submitting task:"
    echo "  Caption   : ${CAPTION:0:72}$( [[ ${#CAPTION} -gt 72 ]] && echo '...' )"
    echo "  Duration  : ${DURATION}s"
    echo "  Batch     : ${BATCH_SIZE}"
    [[ -z "${LYRICS_FILE}" ]] || echo "  Lyrics    : ${LYRICS_FILE}"
  fi

  # Submit
  local task_id
  task_id="$(submit_task)"
  [[ ${QUIET} -eq 1 ]] || echo "  Task ID   : ${task_id}"

  # Poll
  [[ ${QUIET} -eq 1 ]] || { echo; info "Waiting for generation (may take 30–120+ seconds)..."; }
  local task_json
  task_json="$(poll_task "${task_id}")"
  [[ ${QUIET} -eq 1 ]] || ok "Generation complete."

  # Download
  echo
  download_files "${task_json}"

  # Show metadata
  [[ ${QUIET} -eq 1 ]] || print_generation_info "${task_json}"
}

main "$@"
