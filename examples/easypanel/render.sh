#!/usr/bin/env bash
# Render a composition through the HyperFrames producer API (EasyPanel deploy)
# and download the resulting MP4.
#
#   HF_RENDER_URL=http://<project>_<service>:9847 ./render.sh <project-folder> [out.mp4]
#
# <project-folder> is a folder under /projects inside the render container
# (it must contain index.html plus its assets).
#
# Requests wait in the server's FIFO queue, so this call can take a while when
# renders are already running — that is intended.

set -euo pipefail

URL="${HF_RENDER_URL:-http://localhost:9847}"
PROJECTS_DIR="${HF_PROJECTS_DIR:-/projects}" # path INSIDE the render container
RENDERS_DIR="${HF_RENDERS_DIR:-/renders}"    # path INSIDE the render container
FPS="${HF_FPS:-30}"
QUALITY="${HF_QUALITY:-standard}" # draft | standard | high

project="${1:?usage: render.sh <project-folder> [out.mp4]}"
out="${2:-./${project}.mp4}"

# Unique output name per job: the server names the file after the project
# folder by default, so two renders of the same project would overwrite.
job="${project}-$(date +%s)-$$"

# NOTE: never send a "workers" field — it overrides the server's CPU cap.
payload="$(jq -n \
  --arg dir "${PROJECTS_DIR}/${project}" \
  --arg out "${RENDERS_DIR}/${job}.mp4" \
  --argjson fps "$FPS" \
  --arg quality "$QUALITY" \
  '{projectDir: $dir, outputPath: $out, fps: $fps, quality: $quality, format: "mp4"}')"

response="$(curl -sS --max-time 7200 -X POST "${URL}/render" \
  -H 'content-type: application/json' -d "$payload")"

if [ "$(jq -r '.success' <<<"$response")" != "true" ]; then
  echo "Render failed:" >&2
  jq -r '.error // .' <<<"$response" >&2
  exit 1
fi

# The download link lives 15 minutes and only in memory: fetch it right away.
token="$(jq -r '.outputToken' <<<"$response")"
curl -sS --fail -o "$out" "${URL}/outputs/${token}"

echo "OK  ${out}  ($(jq -r '.fileSize' <<<"$response") bytes, $(jq -r '.durationMs' <<<"$response") ms)"
echo "Server-side copy: ${RENDERS_DIR}/${job}.mp4 (not auto-deleted, see README)"
