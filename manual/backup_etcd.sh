#!/usr/bin/env bash
set -euo pipefail

# =========================
# Wajib di-set
# =========================
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-/etc/talos/talosconfig}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/talos-etcd}"

# Retention (hari)
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Nama prefix file (opsional)
PREFIX="${PREFIX:-etcd-snapshot}"

# =========================
# Validasi
# =========================
if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  echo "[ERROR] CONTROL_PLANE_IP belum di-set"
  exit 1
fi

if [[ ! -f "${TALOSCONFIG_PATH}" ]]; then
  echo "[ERROR] talosconfig tidak ditemukan: ${TALOSCONFIG_PATH}"
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
FILE_PATH="${BACKUP_DIR}/${PREFIX}-${TS}.db"

# =========================
# Backup snapshot (sesuai format kamu)
# =========================
echo "[INFO] Running snapshot -> ${FILE_PATH}"
talosctl --talosconfig "${TALOSCONFIG_PATH}" -n "${CONTROL_PLANE_IP}" etcd snapshot -o "${FILE_PATH}"

if [[ ! -s "${FILE_PATH}" ]]; then
  echo "[ERROR] Snapshot file kosong/invalid: ${FILE_PATH}"
  exit 1
fi

echo "[INFO] Snapshot OK"

# =========================
# Retention: hapus > 30 hari
# =========================
echo "[INFO] Retention: delete older than ${RETENTION_DAYS} days in ${BACKUP_DIR}"
find "${BACKUP_DIR}" -type f -name "${PREFIX}-*.db" -mtime +"${RETENTION_DAYS}" -print -delete

echo "[INFO] Done"