#!/bin/sh
# Entrypoint for Dockerfile.easypanel.
#
# The producer server never deletes finished renders, so PRODUCER_RENDERS_DIR
# grows until the disk is full. This starts a background loop that removes old
# video files from it, then hands the process over to the real command.
#
#   PRODUCER_RENDERS_DIR                       directory to clean (default /renders)
#   PRODUCER_RENDERS_RETENTION_MINUTES         delete files older than this (default 60, 0 = never delete)
#   PRODUCER_RENDERS_CLEANUP_INTERVAL_SECONDS  how often to sweep (default 600)
#
# Only regular files named *.mp4 / *.webm / *.mov are removed (subdirectories
# included). Directories themselves and every other file type are never touched.

set -eu

RENDERS_DIR="${PRODUCER_RENDERS_DIR:-/renders}"
RETENTION="${PRODUCER_RENDERS_RETENTION_MINUTES:-60}"
INTERVAL="${PRODUCER_RENDERS_CLEANUP_INTERVAL_SECONDS:-600}"
# Output download tokens live 15 minutes; never delete a file that could still be fetched.
MIN_RETENTION=15

log() { echo "[renders-cleanup] $*"; }

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

cleanup_loop() {
  while :; do
    find "$RENDERS_DIR" -type f \
      \( -name '*.mp4' -o -name '*.webm' -o -name '*.mov' \) \
      -mmin "+${RETENTION}" -print -delete 2>/dev/null |
      while IFS= read -r removed; do log "removed ${removed}"; done || true
    sleep "$INTERVAL"
  done
}

start_cleanup() {
  if ! is_uint "$RETENTION" || ! is_uint "$INTERVAL" || [ "$INTERVAL" -lt 1 ]; then
    log "disabled: PRODUCER_RENDERS_RETENTION_MINUTES / PRODUCER_RENDERS_CLEANUP_INTERVAL_SECONDS must be positive integers"
    return
  fi
  if [ "$RETENTION" -eq 0 ]; then
    log "disabled (retention 0)"
    return
  fi
  case "$RENDERS_DIR" in '' | / | /.)
    log "disabled: refusing to clean '${RENDERS_DIR}'"
    return
    ;;
  esac
  if [ ! -d "$RENDERS_DIR" ]; then
    log "disabled: ${RENDERS_DIR} is not a directory"
    return
  fi
  if [ "$RETENTION" -lt "$MIN_RETENTION" ]; then
    log "retention ${RETENTION} min is below the 15 min download-link lifetime; using ${MIN_RETENTION}"
    RETENTION="$MIN_RETENTION"
  fi
  log "deleting *.mp4/*.webm/*.mov older than ${RETENTION} min in ${RENDERS_DIR} (every ${INTERVAL}s)"
  cleanup_loop &
}

start_cleanup

exec "$@"
