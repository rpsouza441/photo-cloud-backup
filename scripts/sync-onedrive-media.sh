#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${RCLONE_REMOTE:?RCLONE_REMOTE is required}"
: "${RCLONE_REMOTE_BASE:?RCLONE_REMOTE_BASE is required}"

PHOTO_FOLDER="${PHOTO_FOLDER:-JPG}"
VIDEO_FOLDER="${VIDEO_FOLDER:-VIDEO}"
DESTINATION_LAYOUT="${DESTINATION_LAYOUT:-year_flat}"
YEAR_SOURCE="${YEAR_SOURCE:-mtime}"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/state}"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}"
PHOTO_EXTENSIONS="${PHOTO_EXTENSIONS:-jpg,jpeg,png,webp,heic,heif,dng,nef,cr2,arw,raf,orf,rw2,tif,tiff}"
VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,mov,m4v,avi,mkv,3gp,webm,mts,m2ts}"
RCLONE_EXTRA_ARGS="${RCLONE_EXTRA_ARGS:---ignore-existing}"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

STATE_FILE="${STATE_DIR}/processed-signatures.tsv"
CURRENT_FILE="${STATE_DIR}/current-signatures.tsv"
PENDING_FILE="${STATE_DIR}/pending-signatures.tsv"
SUCCESS_FILE="${STATE_DIR}/success-signatures.tsv"
RUN_LOG="${LOG_DIR}/sync-$(date +%Y%m%d-%H%M%S).log"

touch "${STATE_FILE}"
: > "${SUCCESS_FILE}"

log() {
  local message="$1"
  printf '%s %s\n' "$(date '+%F %T')" "${message}" | tee -a "${RUN_LOG}"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

get_extension() {
  local filename="$1"
  local extension="${filename##*.}"
  printf '%s' "${extension,,}"
}

contains_extension() {
  local extension="$1"
  local csv="$2"
  local item
  IFS=',' read -r -a items <<< "${csv}"
  for item in "${items[@]}"; do
    if [[ "${extension}" == "${item}" ]]; then
      return 0
    fi
  done
  return 1
}

detect_category() {
  local extension="$1"
  if contains_extension "${extension}" "${PHOTO_EXTENSIONS}"; then
    printf '%s' "${PHOTO_FOLDER}"
    return 0
  fi
  if contains_extension "${extension}" "${VIDEO_EXTENSIONS}"; then
    printf '%s' "${VIDEO_FOLDER}"
    return 0
  fi
  return 1
}

year_from_mtime() {
  local file="$1"
  date -d "@$(stat -c %Y "${file}")" +%Y
}

year_from_exif() {
  local file="$1"
  if ! have_command exiftool; then
    return 1
  fi

  local raw
  raw="$(exiftool -s3 -d '%Y' -DateTimeOriginal -CreateDate -MediaCreateDate "${file}" 2>/dev/null | awk 'NF { print; exit }')"
  [[ -n "${raw}" ]] || return 1
  printf '%s' "${raw}"
}

detect_year() {
  local file="$1"
  case "${YEAR_SOURCE}" in
    exif_or_mtime)
      year_from_exif "${file}" || year_from_mtime "${file}"
      ;;
    mtime)
      year_from_mtime "${file}"
      ;;
    *)
      echo "Unsupported YEAR_SOURCE=${YEAR_SOURCE}" >&2
      exit 1
      ;;
  esac
}

build_destination_path() {
  local category="$1"
  local year="$2"
  local relative_path="$3"
  local filename="$4"

  case "${DESTINATION_LAYOUT}" in
    year_flat)
      printf '%s:%s/%s/%s/%s' "${RCLONE_REMOTE}" "${RCLONE_REMOTE_BASE}" "${category}" "${year}" "${filename}"
      ;;
    year_relative)
      printf '%s:%s/%s/%s/%s' "${RCLONE_REMOTE}" "${RCLONE_REMOTE_BASE}" "${category}" "${year}" "${relative_path}"
      ;;
    *)
      echo "Unsupported DESTINATION_LAYOUT=${DESTINATION_LAYOUT}" >&2
      exit 1
      ;;
  esac
}

run_copy() {
  local source_file="$1"
  local destination_file="$2"

  local -a cmd
  cmd=(rclone copyto "${source_file}" "${destination_file}")

  # shellcheck disable=SC2206
  local -a extra_args=( ${RCLONE_EXTRA_ARGS} )
  cmd+=("${extra_args[@]}")

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    cmd+=(--dry-run)
  fi

  "${cmd[@]}"
}

generate_current_signatures() {
  find "${SOURCE_DIR}" -type f -printf '%P\t%s\t%T@\n' | sort > "${CURRENT_FILE}"
}

build_pending_signatures() {
  comm -23 "${CURRENT_FILE}" <(sort "${STATE_FILE}") > "${PENDING_FILE}"
}

process_pending() {
  local total=0
  local copied=0
  local skipped=0

  while IFS=$'\t' read -r relative_path size mtime_epoch; do
    [[ -n "${relative_path}" ]] || continue
    total=$((total + 1))

    local source_file="${SOURCE_DIR}/${relative_path}"
    local filename
    filename="$(basename "${relative_path}")"

    local extension
    extension="$(get_extension "${filename}")"

    local category
    if ! category="$(detect_category "${extension}")"; then
      skipped=$((skipped + 1))
      log "SKIP unsupported extension: ${relative_path}"
      continue
    fi

    local year
    year="$(detect_year "${source_file}")"

    local destination
    destination="$(build_destination_path "${category}" "${year}" "${relative_path}" "${filename}")"

    log "COPY ${relative_path} -> ${destination}"
    if run_copy "${source_file}" "${destination}" >> "${RUN_LOG}" 2>&1; then
      printf '%s\t%s\t%s\n' "${relative_path}" "${size}" "${mtime_epoch}" >> "${SUCCESS_FILE}"
      copied=$((copied + 1))
    else
      log "ERROR failed to copy: ${relative_path}"
    fi
  done < "${PENDING_FILE}"

  log "SUMMARY total_pending=${total} copied=${copied} skipped=${skipped} dry_run=${DRY_RUN}"
}

persist_state() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry-run enabled, state file not updated."
    return 0
  fi

  cat "${STATE_FILE}" "${SUCCESS_FILE}" | sort -u > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
  log "State updated at ${STATE_FILE}"
}

main() {
  if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "SOURCE_DIR does not exist: ${SOURCE_DIR}" >&2
    exit 1
  fi

  if ! have_command rclone; then
    echo "rclone is required but was not found in PATH." >&2
    exit 1
  fi

  log "Starting media sync from ${SOURCE_DIR} to ${RCLONE_REMOTE}:${RCLONE_REMOTE_BASE}"
  generate_current_signatures
  build_pending_signatures
  process_pending
  persist_state
  log "Finished media sync"
}

main "$@"
