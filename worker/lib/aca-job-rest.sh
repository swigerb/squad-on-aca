#!/usr/bin/env bash

SQUAD_ACA_ARM_API_VERSION="${SQUAD_ACA_ARM_API_VERSION:-2026-01-01}"
SQUAD_PROMPT_UTF8_BYTE_CAP="${SQUAD_PROMPT_UTF8_BYTE_CAP:-100000}"

squad_aca_job_rest_js() {
  if [[ -n "${SQUAD_ACA_JOB_REST_JS:-}" ]]; then
    printf '%s' "$SQUAD_ACA_JOB_REST_JS"
    return 0
  fi
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/aca-job-rest.js"
}

squad_prompt_utf8_bytes() {
  local prompt="${1-}"
  SQUAD_PROMPT_INPUT="$prompt" node "$(squad_aca_job_rest_js)" prompt-bytes
}

squad_assert_prompt_byte_cap() {
  local prompt="${1-}" context="${2:-SQUAD_PROMPT}"
  SQUAD_PROMPT_INPUT="$prompt" node "$(squad_aca_job_rest_js)" assert-prompt-cap "$context"
}

squad_make_scratch_file() {
  local prefix="$1" suffix="${2:-.tmp}" candidate=""
  local i
  for i in $(seq 1 64); do
    candidate="${PWD}/.${prefix}-${$}-${RANDOM}${suffix}"
    if ( set -o noclobber; : > "$candidate" ) 2>/dev/null; then
      chmod 600 "$candidate" 2>/dev/null || true
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

squad_arm_job_url() {
  local subscription_id="$1" resource_group="$2" job_name="$3"
  printf 'https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.App/jobs/%s' \
    "$subscription_id" "$resource_group" "$job_name"
}

squad_fetch_job_definition() {
  local subscription_id="$1" resource_group="$2" job_name="$3"
  local url
  url="$(squad_arm_job_url "$subscription_id" "$resource_group" "$job_name")?api-version=${SQUAD_ACA_ARM_API_VERSION}"
  az rest --method get --url "$url"
}

squad_build_job_start_body() {
  local job_definition_file="$1" env_tokens_file="$2"
  node "$(squad_aca_job_rest_js)" build-start-body "$job_definition_file" "$env_tokens_file"
}

squad_start_job_via_arm() {
  local subscription_id="$1" resource_group="$2" job_name="$3" body_file="$4"
  local url
  url="$(squad_arm_job_url "$subscription_id" "$resource_group" "$job_name")/start?api-version=${SQUAD_ACA_ARM_API_VERSION}"
  az rest --method post --url "$url" --body "@${body_file}"
}
