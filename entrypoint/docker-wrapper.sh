#!/bin/bash
set -euo pipefail

# Docker wrapper to adjust volume mounts for AMP container
REAL_DOCKER="/usr/bin/docker"
CONTAINER_PREFIX="/home/amp"

# Normalize a path by removing trailing slashes
normalize_path() {
  local value="$1"
  if [ -z "$value" ]; then
    echo ""
    return
  fi
  while [ "${#value}" -gt 1 ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  echo "$value"
}

# Decode escaped characters in mount paths
decode_mount_path() {
  local path="$1"
  path="${path//\\040/ }"
  path="${path//\\011/$'\t'}"
  path="${path//\\012/$'\n'}"
  path="${path//\\134/\\}"
  echo "$path"
}

# Detect host mount prefix for the container prefix
detect_host_prefix() {
  local mount_line
  mount_line=$(awk -v mp="$CONTAINER_PREFIX" '$5==mp {print $4; exit}' /proc/self/mountinfo 2>/dev/null || true)
  if [ -z "$mount_line" ] || [ "$mount_line" = "/" ]; then
    echo ""
    return
  fi
  decode_mount_path "$mount_line"
}

# Determine HOST_PREFIX
HOST_PREFIX="${AMP_HOST_HOME:-}"
if [ -z "$HOST_PREFIX" ]; then
  HOST_PREFIX="$(detect_host_prefix)"
fi
HOST_PREFIX="$(normalize_path "$HOST_PREFIX")"
CONTAINER_PREFIX="$(normalize_path "$CONTAINER_PREFIX")"

# If no host prefix detected or same as container, run docker as-is
if [ -z "$HOST_PREFIX" ] || [ "$HOST_PREFIX" = "$CONTAINER_PREFIX" ]; then
  exec "$REAL_DOCKER" "$@"
fi

# Helper to split quoted values
split_with_quote() {
  local value="$1"
  local quote=""
  if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
    quote='"'
    value="${value#\"}"
    value="${value%\"}"
  elif [ "${value#\'}" != "$value" ] && [ "${value%\'}" != "$value" ]; then
    quote="'"
    value="${value#\'}"
    value="${value%\'}"
  fi
  printf '%s|%s' "$quote" "$value"
}

# Rewrite volume argument
rewrite_volume_arg() {
  local original="$1"
  local src_with_quotes="${original%%:*}"
  local remainder="${original#"$src_with_quotes"}"
  local parsed
  parsed="$(split_with_quote "$src_with_quotes")"
  local quote=""
  local src=""
  IFS='|' read -r quote src <<<"$parsed"
  if [ -n "$src" ] && { [ "$src" = "$CONTAINER_PREFIX" ] || [ "${src#$CONTAINER_PREFIX/}" != "$src" ]; }; then
    local suffix="${src#$CONTAINER_PREFIX}"
    local new_src="${HOST_PREFIX}${suffix}"
    echo "${quote}${new_src}${quote}${remainder}"
    return
  fi
  echo "$original"
}

# Rewrite mount argument
rewrite_mount_arg() {
  local original="$1"
  IFS=',' read -ra parts <<<"$original"
  local updated=()
  for part in "${parts[@]}"; do
    local key="${part%%=*}"
    local value="${part#*=}"
    if [ "$key" = "source" ] || [ "$key" = "src" ]; then
      local parsed
      parsed="$(split_with_quote "$value")"
      local quote=""
      local path=""
      IFS='|' read -r quote path <<<"$parsed"
      if [ -n "$path" ] && { [ "$path" = "$CONTAINER_PREFIX" ] || [ "${path#$CONTAINER_PREFIX/}" != "$path" ]; }; then
        local suffix="${path#$CONTAINER_PREFIX}"
        local new_path="${HOST_PREFIX}${suffix}"
        part="${key}=${quote}${new_path}${quote}"
      fi
    fi
    updated+=("$part")
  done
  local IFS=','
  echo "${updated[*]}"
}

# Adjust all arguments
adjust_args() {
  local -a result=()
  while [ "$#" -gt 0 ]; do
    local arg="$1"
    case "$arg" in
      -v)
        if [ "$#" -gt 1 ]; then
          result+=("-v" "$(rewrite_volume_arg "$2")")
          shift
        else
          result+=("$arg")
        fi
        ;;
      -v*)
        result+=("-v$(rewrite_volume_arg "${arg#-v}")")
        ;;
      --volume)
        if [ "$#" -gt 1 ]; then
          result+=("--volume" "$(rewrite_volume_arg "$2")")
          shift
        else
          result+=("$arg")
        fi
        ;;
      --volume=*)
        result+=("--volume=$(rewrite_volume_arg "${arg#--volume=}")")
        ;;
      --mount)
        if [ "$#" -gt 1 ]; then
          result+=("--mount" "$(rewrite_mount_arg "$2")")
          shift
        else
          result+=("$arg")
        fi
        ;;
      --mount=*)
        result+=("--mount=$(rewrite_mount_arg "${arg#--mount=}")")
        ;;
      *)
        result+=("$arg")
        ;;
    esac
    shift
  done
  printf '%s\0' "${result[@]}"
}

# Transform and execute
mapfile -d '' transformed < <(adjust_args "$@")
exec "$REAL_DOCKER" "${transformed[@]}"