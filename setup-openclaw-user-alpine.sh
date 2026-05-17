#!/bin/sh
set -eu

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
KEY_TYPE="${KEY_TYPE:-ed25519}"
KEY_COMMENT="${KEY_COMMENT:-openclaw@$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo alpine)}"
PRINT_PRIVATE_KEY="${PRINT_PRIVATE_KEY:-1}"
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS_FILE="${SUDOERS_DIR}/${OPENCLAW_USER}"
SUDO_GROUP="wheel"

die() {
  echo "$*" >&2
  exit 1
}

install_packages() {
  if ! command -v apk >/dev/null 2>&1; then
    die "This script is intended for Alpine Linux and requires apk."
  fi

  apk update

  if ! command -v sudo >/dev/null 2>&1; then
    apk add sudo
  fi

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    apk add openssh-keygen
  fi
}

user_exists() {
  grep -q "^${OPENCLAW_USER}:" /etc/passwd
}

group_exists() {
  grep -q "^$1:" /etc/group
}

user_in_group() {
  GROUP_NAME="$1"
  GROUP_LINE="$(grep "^${GROUP_NAME}:" /etc/group || true)"
  echo "${GROUP_LINE}" | awk -F: '{ print "," $4 "," }' | grep -q ",${OPENCLAW_USER},"
}

get_user_home() {
  awk -F: -v user="${OPENCLAW_USER}" '$1 == user { print $6 }' /etc/passwd
}

host_name() {
  hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown-host
}

if [ "$(id -u)" -ne 0 ]; then
  die "Run this script as root, for example: doas sh $0 or sudo sh $0"
fi

install_packages

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is still not available after package installation."
fi

if ! command -v visudo >/dev/null 2>&1; then
  die "visudo is still not available after installing sudo."
fi

if user_exists; then
  echo "User '${OPENCLAW_USER}' already exists."
else
  adduser -D -s /bin/ash "${OPENCLAW_USER}"
  echo "Created user '${OPENCLAW_USER}'."
fi

if ! group_exists "${SUDO_GROUP}"; then
  addgroup "${SUDO_GROUP}"
fi

if user_in_group "${SUDO_GROUP}"; then
  echo "User '${OPENCLAW_USER}' is already in group '${SUDO_GROUP}'."
else
  addgroup "${OPENCLAW_USER}" "${SUDO_GROUP}"
fi

mkdir -p "${SUDOERS_DIR}"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${OPENCLAW_USER}" > "${SUDOERS_FILE}"
chown root:root "${SUDOERS_FILE}"
chmod 440 "${SUDOERS_FILE}"

if ! visudo -cf "${SUDOERS_FILE}" >/dev/null; then
  rm -f "${SUDOERS_FILE}"
  die "Generated sudoers file failed validation and was removed."
fi

USER_HOME="$(get_user_home)"
if [ -z "${USER_HOME}" ]; then
  die "Could not determine home directory for '${OPENCLAW_USER}'."
fi

SSH_DIR="${USER_HOME}/.ssh"
KEY_PATH="${SSH_DIR}/id_${KEY_TYPE}"

mkdir -p "${SSH_DIR}"
chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [ -f "${KEY_PATH}" ]; then
  echo "SSH key already exists at ${KEY_PATH}; leaving it unchanged."
else
  ssh-keygen \
    -t "${KEY_TYPE}" \
    -f "${KEY_PATH}" \
    -C "${KEY_COMMENT}" \
    -N ""
  chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${KEY_PATH}" "${KEY_PATH}.pub"
  chmod 600 "${KEY_PATH}"
  chmod 644 "${KEY_PATH}.pub"
fi

AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
touch "${AUTHORIZED_KEYS}"
chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${AUTHORIZED_KEYS}"
chmod 600 "${AUTHORIZED_KEYS}"

PUB_KEY="$(cat "${KEY_PATH}.pub")"
if grep -qxF "${PUB_KEY}" "${AUTHORIZED_KEYS}"; then
  echo "Public key is already present in ${AUTHORIZED_KEYS}."
else
  printf '%s\n' "${PUB_KEY}" >> "${AUTHORIZED_KEYS}"
  echo "Added public key to ${AUTHORIZED_KEYS}."
fi

HOST_FQDN="$(host_name)"
HOST_SHORT="$(hostname 2>/dev/null || echo unknown-host)"

cat <<EOF

OpenClaw target user is ready.

User: ${OPENCLAW_USER}
Sudo group: ${SUDO_GROUP}
Passwordless sudo: ${SUDOERS_FILE}
Host: ${HOST_FQDN}
Public key path: ${KEY_PATH}.pub
Private key path: ${KEY_PATH}
Authorized keys: ${AUTHORIZED_KEYS}

Copy the following SSH config block to your central OpenClaw server and save
the private key below as a protected key file, for example:
  /opt/openclaw/keys/${HOST_SHORT}_${OPENCLAW_USER}

Host ${HOST_SHORT}
  HostName ${HOST_FQDN}
  User ${OPENCLAW_USER}
  IdentityFile /opt/openclaw/keys/${HOST_SHORT}_${OPENCLAW_USER}
  IdentitiesOnly yes

EOF

if [ "${PRINT_PRIVATE_KEY}" = "1" ]; then
  cat <<EOF
-----BEGIN COPY PRIVATE KEY-----
$(cat "${KEY_PATH}")
-----END COPY PRIVATE KEY-----

EOF
fi

cat <<EOF
Public key:
$(cat "${KEY_PATH}.pub")

Security note: this private key gives access to this server as '${OPENCLAW_USER}'.
Store it only on the central OpenClaw server, chmod it to 600, and remove any
terminal scrollback or copied notes that should not retain the key.
EOF
