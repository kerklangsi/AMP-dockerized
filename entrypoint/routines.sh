#!/bin/bash

check_data_volume() {
  # Starting with V24, we recommend that users mount /home/amp instead of /home/amp/.ampdata. 
  # This function allows existing users to simply change their mount point in the container, 
  # without needing to do any complicated remapping of their host data.
  echo "Checking data volume..."
  local AMP_HOME="/home/amp"
  local AMP_DATA_DIR="${AMP_HOME}/.ampdata"
  local AMP_DOCKERIZED_DIR="${AMP_DATA_DIR}/.amp-dockerized"
  local LEGACY_INSTANCES_JSON="${AMP_HOME}/instances.json"
  local LEGACY_INSTANCES_DIR="${AMP_HOME}/instances"
  # Check if migration is needed
  if [ -f "${LEGACY_INSTANCES_JSON}" ] || [ -d "${LEGACY_INSTANCES_DIR}" ]; then
    echo "Updated data volume detected. Migration is required."
    # At this point we have detected that the contents of .ampdata are mapped to /home/amp, which is expected for V24 volume migration.
    # For example, the volume mount may have changed from:
    #     /mnt/user/appdata/amp:/home/amp/.ampdata 
    # to...
    #     /mnt/user/appdata/amp:/home/amp
    if [ -d "${AMP_DATA_DIR}" ]; then # This can happen if the new volume (/home/amp) was accidentally mounted on image v23 or earlier.
      if [ ! -z "$(ls -A "${AMP_DATA_DIR}")" ]; then # Something is very odd if .ampdata is not empty.
        echo "Error: Need to migrate data (${LEGACY_INSTANCES_DIR} and ${LEGACY_INSTANCES_JSON}), but ${AMP_DATA_DIR} is not empty. Please resolve this conflict manually. For help, visit https://github.com/MitchTalmadge/AMP-dockerized/discussions/247"
        exit 1
      fi
      echo "Empty .ampdata directory detected. Removing..."
      rmdir "${AMP_DATA_DIR}"
    fi
    echo "Beginning data migration..."
    mkdir -p "${AMP_DATA_DIR}"
    find "${AMP_HOME}" -mindepth 1 -maxdepth 1 \
      ! -name '.ampdata' \
      ! -name 'scripts' \
      -exec mv {} "${AMP_DATA_DIR}" \;
    # For future use, we will leave a fingerprint indicating that a migration took place
    mkdir -p "${AMP_DOCKERIZED_DIR}"
    touch "${AMP_DOCKERIZED_DIR}/.v24_volume_migrated"
    echo "Migration complete."
  fi
 # Verify that the data volume is writable
  echo "Data volume (/home/amp/.ampdata) is ok!"
  if [ -w "${AMP_DATA_DIR}" ]; then
    chmod 755 "${AMP_DATA_DIR}"
  fi
 # Verify that the home directory is writable
  echo "Data volume (/home/amp/) is ok!"
  if [ -w "${AMP_HOME}" ]; then
    chmod 755 "${AMP_HOME}"
  fi
}

# Configure file permissions
check_file_permissions() {
  echo "Checking file permissions..."
  chown -R ${APP_USER}:${APP_GROUP} /home/amp
  if [ -w /home/amp ]; then
    echo "File permissions set for ${APP_USER}:${APP_GROUP}. Directory /home/amp is writable."
  else
    echo "Warning: Directory /home/amp is not writable for ${APP_USER}:${APP_GROUP}."
  fi
}

# Configure main ADS instance
configure_main_instance() {
  echo "Checking ADS instance existence..."
  if ! does_main_instance_exist; then
    echo "Creating ADS instance... (This can take a while)"
    run_amp_command "QuickStart \"${USERNAME}\" \"${PASSWORD}\" \"${IPBINDING}\" \"${PORT}\"" | consume_progress_bars
    if ! does_main_instance_exist; then
      handle_error "Failed to create ADS instance. Please check your configuration."
    fi
  fi
  echo "Setting ADS instance to start on boot..."
  run_amp_command "ShowInstanceInfo ADS01" | grep "Start on Boot" | grep -q "No" && run_amp_command "SetStartBoot ADS01 yes" || true
}

# Configure release stream for all instances
configure_release_stream() {
  echo "Setting release stream to ${AMP_RELEASE_STREAM}..."
  # Example Output from ShowInstancesList:
  # [Info] AMP Instance Manager v2.4.5.4 built 26/06/2023 18:20
  # [Info] Stream: Mainline / Release - built by CUBECODERS/buildbot on CCL-DEV
  # Instance ID        │ 295e9fc7-9987-4e4e-94a6-183cb04de459
  # Module             │ ADS
  # Instance Name      │ Main
  # Friendly Name      │ Main
  # URL                │ http://127.0.0.1:8080/
  # Running            │ No
  # Runs in Container  │ No
  # Runs as Shared     │ No
  # Start on Boot      │ Yes
  # AMP Version        │ 2.4.5.4
  # Release Stream     │ Mainline
  # Data Path          │ /home/amp/.ampdata/instances/Main
  run_amp_command "ShowInstancesList" | grep "Instance Name" | awk '{ print $4 }' | while read -r INSTANCE_NAME; do
    local RELEASE_STREAM=$(run_amp_command "ShowInstanceInfo \"${INSTANCE_NAME}\"" | grep "Release Stream" | awk '{ print $4 }')
    if [ "${RELEASE_STREAM}" != "${AMP_RELEASE_STREAM}" ]; then
      echo "Changing release stream of ${INSTANCE_NAME} from ${RELEASE_STREAM} to ${AMP_RELEASE_STREAM}..."
      run_amp_command "ChangeInstanceStream \"${INSTANCE_NAME}\" ${AMP_RELEASE_STREAM} True" | consume_progress_bars
      # Since we changed release streams we have to force an upgrade
      run_amp_command "UpgradeInstance \"${INSTANCE_NAME}\"" | consume_progress_bars
    fi
  done
}

# Configure ADS defaults for new instances
configure_ads_defaults() {
  if [ -n "${AMP_LICENCE}" ]; then
    echo "Reactivating AMP licence across instances."
    if run_amp_command "--silent ReactivateAll \"${AMP_LICENCE}\"" >/dev/null; then
      echo "Successfully reactivated licence."
    else
      echo "Warning: Failed to reactivate AMP instances with licence key."
    fi
  fi
}


# Configure timezone
configure_timezone() {
  echo "Configuring timezone..."
  ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ >/etc/timezone
  dpkg-reconfigure --frontend noninteractive tzdata
}

# AMP user/group
create_amp_user() {
  local AMP_GID="${GID}"
  local DOCKER_GROUP_GID="${DOCKER_GID}"
  # try to DOCKER_GROUP_GID detect from docker socket
  if [ -z "${DOCKER_GROUP_GID}" ] && [ -S "/var/run/docker.sock" ]; then
    DOCKER_GROUP_GID=$(stat -c '%g' /var/run/docker.sock)
    if [ "${DOCKER_GROUP_GID}" = "0" ]; then
      echo "Docker socket owned by root group. Not using docker group."
      DOCKER_GROUP_GID=""
    else
      echo "Detected docker socket GID: ${DOCKER_GROUP_GID}"
    fi
  # Else, use AMP_GID
  else
    echo "docker socket not found. Using default AMP GID: ${AMP_GID}"
  fi
  # Create AMP user
  echo "Creating AMP user..."
  if ! getent passwd ${UID} > /dev/null 2>&1; then
    adduser \
      --uid ${UID} \
      --shell /bin/bash \
      --no-create-home \
      --disabled-password \
      --gecos "" \
      amp
  fi
  APP_USER=$(getent passwd ${UID} | awk -F ":" '{ print $1 }')
  echo "User Created: ${APP_USER} (${UID})"
  # Add AMP user to docker group if it exists
  if getent group docker > /dev/null 2>&1; then
    usermod -a -G docker ${APP_USER}
    APP_GROUP=docker
    echo "Use Docker group: ${APP_GROUP} (${DOCKER_GID})"
  # If DOCKER_GROUP_GID is specified, create/use that group
  elif [ ! -z "${DOCKER_GROUP_GID}" ]; then
    if ! getent group ${DOCKER_GROUP_GID} > /dev/null 2>&1; then
      echo "Creating docker group with GID ${DOCKER_GROUP_GID}..."
      addgroup --gid ${DOCKER_GROUP_GID} docker
    fi
    usermod -a -G docker ${APP_USER}
    APP_GROUP=docker
    echo "Docker group created: ${APP_GROUP} (${DOCKER_GROUP_GID})"
  # Otherwise, create/use amp group
  else
    if ! getent group ${AMP_GID} > /dev/null 2>&1; then
      echo "Creating AMP group with GID ${AMP_GID}..."
      addgroup --gid ${AMP_GID} amp
    fi
    usermod -a -G amp ${APP_USER}
    APP_GROUP=amp
    echo "AMP group created: ${APP_GROUP} (${AMP_GID})"
  fi
  echo "AMP User: ${APP_USER} , Group: ${APP_GROUP}"
}

setup_main_port_proxy() {
  local listen_port="${PORT:-8080}"
  local target_host="${AMP_REMOTE_PROXY_HOST}"
  local target_port="${AMP_REMOTE_PROXY_PORT}"

  if [ -n "${target_host}" ]; then
    if [ -z "${target_port}" ]; then
      target_port="${listen_port}"
    fi
  else
    local main_instance
    main_instance=$(get_main_instance_name)
    if [ -z "${main_instance}" ] || [ "${main_instance}" = "null" ]; then
      return
    fi

    local instance_info url actual_port
    instance_info=$(run_amp_command "ShowInstanceInfo \"${main_instance}\"") || return
    url=$(echo "${instance_info}" | grep -oE 'https?://[^[:space:]]+' | head -n1)
    if [ -z "${url}" ]; then
      return
    fi

    actual_port=$(echo "${url}" | sed -n 's#.*:\([0-9]\+\)/.*#\1#p')
    if [ -z "${actual_port}" ]; then
      return
    fi

    if [ "${actual_port}" = "${listen_port}" ]; then
      return
    fi

    target_host="127.0.0.1"
    target_port="${actual_port}"
  fi

  if [ -z "${target_host}" ] || [ -z "${target_port}" ]; then
    return
  fi

  if [ "${target_host}" = "127.0.0.1" ] && [ "${target_port}" = "${listen_port}" ]; then
    return
  fi

  if ! command -v socat >/dev/null 2>&1; then
    echo "Warning: socat not available; cannot proxy AMP remote API from ${listen_port} to ${target_host}:${target_port}."
    return
  fi

  echo "Forwarding AMP requests on TCP ${listen_port} to ${target_host}:${target_port}."
  socat TCP-LISTEN:${listen_port},fork,reuseaddr TCP:${target_host}:${target_port} &
  SOCAT_PID=$!
  sleep 0.2
  if ! kill -0 "${SOCAT_PID}" >/dev/null 2>&1; then
    echo "Warning: failed to establish AMP port proxy on ${listen_port}."
    SOCAT_PID=""
  fi
}

# Error handler
handle_error() {
  # Prints a nice error message and exits.
  # Usage: handle_error "Error message"
  local error_message="$1"
  echo "Sorry! An error occurred during startup and AMP needs to shut down."
  if [ ! -z "${error_message}" ]; then
    echo "Error message: ${error_message}"
  fi
  echo "Please direct any questions or concerns to https://github.com/MitchTalmadge/AMP-dockerized/issues"
  exit 1
}

# Monitor AMP for pending tasks
monitor_amp() {
  # Periodically process pending tasks (e.g. upgrade, reboots, ...)
  while true; do
    run_amp_command_silently "ProcessPendingTasks"
    sleep 60 # Check for pending tasks every 60 seconds to reduce CPU usage
  done
}

# Run user-provided startup script
run_startup_script() {
  # Users may provide their own startup script for installing dependencies, etc.
  STARTUP_SCRIPT="/home/amp/scripts/startup.sh"
  if [ -f ${STARTUP_SCRIPT} ]; then
    echo "Running startup script..."
    chmod +x ${STARTUP_SCRIPT}
    /bin/bash ${STARTUP_SCRIPT}
  fi
}

# Graceful shutdown
shutdown() {
  echo "Shutting down... (Signal ${1})"
  if [ -n "${AMP_STARTED}" ] && [ "${AMP_STARTED}" -eq 1 ] && [ "${1}" != "KILL" ]; then
    stop_amp
  fi
  if [ -n "${SOCAT_PID}" ]; then
    if kill -0 "${SOCAT_PID}" >/dev/null 2>&1; then
      echo "Stopping AMP port proxy (PID ${SOCAT_PID})..."
      kill "${SOCAT_PID}" >/dev/null 2>&1 || true
      wait "${SOCAT_PID}" >/dev/null 2>&1 || true
    fi
  fi
  exit 0
}

# Start AMP
start_amp() {
  echo "Starting AMP..."
  run_amp_command "StartBoot"
  export AMP_STARTED=1
  echo "AMP Started!"
}

# Stop AMP
stop_amp() {
  echo "Stopping AMP..."
  run_amp_command "StopAll"
  echo "AMP Stopped."
}

# Upgrade instances
upgrade_instances() {
  echo "Upgrading instances..."
  run_amp_command "UpgradeAll" | consume_progress_bars
}