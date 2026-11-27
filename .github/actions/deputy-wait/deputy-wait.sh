#!/bin/bash
# After the environment tag moved: ask each magenx-deputy-go (watch) to check now (POST <url>/check) and wait
# until GET <url>/status reports the release as deployed. Fails when a server reports the release as failed,
# or when one has not deployed it within WAIT_TIMEOUT seconds.
#
# Environment: DEPUTY_URLS (base URLs of the servers' deputy, space or comma separated, e.g.
#   http://10.1.0.4:8082), TAG_NAME (the release), TARGET (code or stack), WAIT_TIMEOUT (seconds, default 960),
#   WAIT_INTERVAL (seconds between polls, default 10).
set -euo pipefail

: "${DEPUTY_URLS:?}" "${TAG_NAME:?}" "${TARGET:?}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-960}"
WAIT_INTERVAL="${WAIT_INTERVAL:-10}"
case "${TARGET}" in code|stack) ;; *) echo "::error::TARGET must be code or stack"; exit 1 ;; esac

read -r -a urls <<< "${DEPUTY_URLS//,/ }"
[ "${#urls[@]}" -gt 0 ] || { echo "::error::DEPUTY_URLS lists no server"; exit 1; }

for url in "${urls[@]}"; do
  # 202 queued, 429 a check is queued already: both fine; deputy also checks on its own interval
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "${url%/}/check" || true)
  case "${code}" in
    202|429) echo "${url}: check requested" ;;
    *) echo "::warning::${url}: check request answered ${code:-nothing}, waiting for its own interval" ;;
  esac
done

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
pending=("${urls[@]}")
while [ "${#pending[@]}" -gt 0 ]; do
  still=()
  for url in "${pending[@]}"; do
    status=$(curl -fsS --max-time 10 "${url%/}/status" 2> /dev/null || true)
    version=$(jq -r --arg t "${TARGET}" '.[$t].version // ""' <<< "${status:-{\}}" 2> /dev/null || true)
    failed=$(jq -r --arg t "${TARGET}" '.[$t].failed_version // ""' <<< "${status:-{\}}" 2> /dev/null || true)
    if [ "${version}" = "${TAG_NAME}" ]; then
      echo "${url}: ${TARGET} ${TAG_NAME} deployed"
    elif [ "${failed}" = "${TAG_NAME}" ]; then
      error=$(jq -r --arg t "${TARGET}" '.[$t].error // ""' <<< "${status}")
      echo "::error::${url}: ${TARGET} ${TAG_NAME} failed: ${error}"
      exit 1
    else
      still+=("${url}")
    fi
  done
  pending=("${still[@]+"${still[@]}"}")
  [ "${#pending[@]}" -gt 0 ] || break
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "::error::${TARGET} ${TAG_NAME} not deployed within ${WAIT_TIMEOUT}s on: ${pending[*]}"
    exit 1
  fi
  sleep "${WAIT_INTERVAL}"
done
