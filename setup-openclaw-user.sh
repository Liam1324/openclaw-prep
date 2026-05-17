#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
KEY_TYPE="${KEY_TYPE:-ed25519}"
KEY_COMMENT="${KEY_COMMENT:-openclaw@$(hostname -f 2>/dev/null || hostname)}"
PRINT_PRIVATE_KEY="${PRINT_PRIVATE_KEY:-1}"
SUDOERS_FILE="/etc/sudoers.d/${OPENCLAW_USER}"

install_sudo() {
  echo "sudo is not installed; attempting to install it."

  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install sudo
  elif command -v apk >/dev/null 2>&1; then
    apk add sudo
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm sudo
  else
    echo "Could not find a supported package manager to install sudo." >&2
    echo "Install sudo manually, then rerun this script." >&2
    exit 1
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root, for example: sudo $0" >&2
  exit 1
fi

if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "ssh-keygen is required. Install openssh-client/openssh first." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  install_sudo
fi

if ! command -v visudo >/dev/null 2>&1; then
  echo "visudo is still not available after installing sudo." >&2
  exit 1
fi

if id "${OPENCLAW_USER}" >/dev/null 2>&1; then
  echo "User '${OPENCLAW_USER}' already exists."
else
  useradd --create-home --shell /bin/bash "${OPENCLAW_USER}"
  echo "Created user '${OPENCLAW_USER}'."
fi

if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "${OPENCLAW_USER}"
  SUDO_GROUP="sudo"
elif getent group wheel >/dev/null 2>&1; then
  usermod -aG wheel "${OPENCLAW_USER}"
  SUDO_GROUP="wheel"
else
  echo "No sudo or wheel group found. Install/configure sudo before using this account for updates." >&2
  exit 1
fi

if [[ ! -d /etc/sudoers.d ]]; then
  echo "/etc/sudoers.d does not exist. Install/configure sudo before using passwordless sudo." >&2
  exit 1
fi

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${OPENCLAW_USER}" > "${SUDOERS_FILE}"
chown root:root "${SUDOERS_FILE}"
chmod 440 "${SUDOERS_FILE}"

if ! visudo -cf "${SUDOERS_FILE}" >/dev/null; then
  rm -f "${SUDOERS_FILE}"
  echo "Generated sudoers file failed validation and was removed." >&2
  exit 1
fi

USER_HOME="$(getent passwd "${OPENCLAW_USER}" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
KEY_PATH="${SSH_DIR}/id_${KEY_TYPE}"

install -d -m 700 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${SSH_DIR}"

if [[ -f "${KEY_PATH}" ]]; then
  echo "SSH key already exists at ${KEY_PATH}; leaving it unchanged."
else
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "${OPENCLAW_USER}" -- ssh-keygen \
      -t "${KEY_TYPE}" \
      -f "${KEY_PATH}" \
      -C "${KEY_COMMENT}" \
      -N ""
  else
    sudo -u "${OPENCLAW_USER}" ssh-keygen \
      -t "${KEY_TYPE}" \
      -f "${KEY_PATH}" \
      -C "${KEY_COMMENT}" \
      -N ""
  fi
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

HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
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

if [[ "${PRINT_PRIVATE_KEY}" == "1" ]]; then
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
