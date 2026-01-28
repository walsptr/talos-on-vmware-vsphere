#!/bin/bash
set -e

export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='xxx'
export GOVC_INSECURE=true
export GOVC_URL='https://172.20.0.1'
export GOVC_DATASTORE='datastore'
export GOVC_NETWORK='network'
export GOVC_DATACENTER='datacenter'
export GOVC_RESOURCE_POOL='/datacenter/host/192.168.1.1/Resources'

# ====== MULTI CLUSTER SETTINGS ======
PARTICIPANT_START=${PARTICIPANT_START:=1}
PARTICIPANT_END=${PARTICIPANT_END:=6}
CLUSTER_PREFIX=${CLUSTER_PREFIX:=peserta}

# ====== TALOS SETTINGS ======
TALOS_VERSION=${TALOS_VERSION:=v1.11.1}
OVA_PATH=${OVA_PATH:="https://factory.talos.dev/image/903b2da78f99adef03cbbd4df6714563823f63218508800751560d3bc3557e40/${TALOS_VERSION}/vmware-amd64.ova"}

# Per peserta: 1 master + 1 worker (sesuai format nama talos-master-01..06)
CONTROL_PLANE_CPU=${CONTROL_PLANE_CPU:=2}
CONTROL_PLANE_MEM=${CONTROL_PLANE_MEM:=4096}
CONTROL_PLANE_DISK=${CONTROL_PLANE_DISK:=40G}

WORKER_CPU=${WORKER_CPU:=2}
WORKER_MEM=${WORKER_MEM:=4096}
WORKER_DISK=${WORKER_DISK:=40G}

# VIP base, akan jadi 172.23.11.(45+N-1) per peserta
VIP_TALOS_BASE=${VIP_TALOS_BASE:=172.23.11.45}

# ====== HELPERS ======
ip_last_octet() {
  # input: 172.23.11.45
  echo "${1##*.}"
}

ip_prefix_3octets() {
  # input: 172.23.11.45 -> 172.23.11
  echo "${1%.*}"
}

vip_for_participant() {
  local p="$1"
  local base_last
  base_last="$(ip_last_octet "${VIP_TALOS_BASE}")"
  local prefix
  prefix="$(ip_prefix_3octets "${VIP_TALOS_BASE}")"
  local last=$((base_last + p - 1))
  echo "${prefix}.${last}"
}

participant_id() {
  printf "%02d" "$1"
}

cluster_name_for() {
  local p="$1"
  echo "${CLUSTER_PREFIX}${p}"
}

master_name_for() {
  local pid
  pid="$(participant_id "$1")"
  echo "talos-master-${pid}"
}

worker_name_for() {
  local pid
  pid="$(participant_id "$1")"
  echo "talos-worker-${pid}"
}

# ====== FUNCTIONS ======

upload_ova () {
  VM_NAME="talos-${TALOS_VERSION}"

  echo "Downloading & importing OVA into temporary VM..."
  govc import.ova -name="${VM_NAME}" -options <(cat <<EOF
{
  "DiskProvisioning": "thin",
  "PowerOn": false,
  "MarkAsTemplate": false,
  "Name": "${VM_NAME}",
  "NetworkMapping": [
    {
      "Name": "VM Network",
      "Network": "${GOVC_NETWORK}"
    }
  ]
}
EOF
) "${OVA_PATH}"

  echo "Imported temporary VM: ${VM_NAME}"
  echo "Verifying disk type..."
  govc vm.info "${VM_NAME}" | grep -i thin || echo "Warning: disk type check skipped (verify manually if needed)"

  echo "Exporting VM back to OVF..."
  rm -rf "${VM_NAME}"
  govc export.ovf -vm "${VM_NAME}" .
  OVF_FILE="${VM_NAME}/${VM_NAME}.ovf"
  echo "Exported OVF: ${OVF_FILE}"

  echo "Converting VM to template..."
  govc vm.markastemplate "${VM_NAME}"

  echo "Uploading thin-provisioned OVF to Content Library..."
  govc library.create "talos-images" || true
  govc library.import -n "talos-${TALOS_VERSION}" "talos-images" "${OVF_FILE}"

  echo "Done! Library item 'talos-${TALOS_VERSION}' available in library 'talos-images'."
}

patch_for_participant () {
  local p="$1"
  local VIP_TALOS
  VIP_TALOS="$(vip_for_participant "$p")"

  echo "Create cp.patch.yaml (participant ${p})"
  cat <<EOF > cp.patch.yaml
- op: add
  path: /machine/network
  value:
    interfaces:
    - interface: eth0
      dhcp: true
      vip:
        ip: ${VIP_TALOS}

- op: replace
  path: /cluster/extraManifests
  value:
    - "https://raw.githubusercontent.com/siderolabs/talos-vmtoolsd/refs/tags/v1.4.0/deploy/latest.yaml"
EOF

  echo "Create patch.yaml (participant ${p})"
  cat <<EOF > patch.yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF
}

gen_config_for_participant () {
  local p="$1"
  local CLUSTER_NAME
  CLUSTER_NAME="$(cluster_name_for "$p")"
  local VIP_TALOS
  VIP_TALOS="$(vip_for_participant "$p")"

  echo "== Generating config for ${CLUSTER_NAME} (VIP ${VIP_TALOS}) =="

  mkdir -p "${CLUSTER_NAME}"
  sudo mkdir -p "/opt/${CLUSTER_NAME}"
  sudo chown -R "$(whoami):$(whoami)" "/opt/${CLUSTER_NAME}"

  cp cp.patch.yaml "${CLUSTER_NAME}/cp.patch.yaml"
  cp patch.yaml "${CLUSTER_NAME}/patch.yaml"

  mv cp.patch.yaml "/opt/${CLUSTER_NAME}/cp.patch.yaml"
  mv patch.yaml "/opt/${CLUSTER_NAME}/patch.yaml"

  (
    cd "${CLUSTER_NAME}"
    talosctl gen config "${CLUSTER_NAME}" "https://${VIP_TALOS}:6443" \
      --kubernetes-version 1.33.1 \
      --config-patch-control-plane @cp.patch.yaml \
      --config-patch @patch.yaml
  )
}

create_for_participant () {
  local p="$1"
  local CLUSTER_NAME
  CLUSTER_NAME="$(cluster_name_for "$p")"

  local MASTER_NAME
  MASTER_NAME="$(master_name_for "$p")"
  local WORKER_NAME
  WORKER_NAME="$(worker_name_for "$p")"

  local CONTROL_PLANE_MACHINE_CONFIG_PATH="./${CLUSTER_NAME}/controlplane.yaml"
  local WORKER_MACHINE_CONFIG_PATH="./${CLUSTER_NAME}/worker.yaml"

  local CONTROL_PLANE_B64_MACHINE_CONFIG
  CONTROL_PLANE_B64_MACHINE_CONFIG="$(cat "${CONTROL_PLANE_MACHINE_CONFIG_PATH}" | base64 | tr -d '\n')"
  local WORKER_B64_MACHINE_CONFIG
  WORKER_B64_MACHINE_CONFIG="$(cat "${WORKER_MACHINE_CONFIG_PATH}" | base64 | tr -d '\n')"

  echo "== Deploying VMs for ${CLUSTER_NAME} =="

  # Ensure participant library exists (optional, just for grouping)
  govc library.create "${CLUSTER_NAME}" || true

  # Deploy master
  echo "Launching control plane node: ${MASTER_NAME}"
  govc library.deploy "talos-images/talos-${TALOS_VERSION}" "${MASTER_NAME}"

  govc vm.change \
    -c "${CONTROL_PLANE_CPU}" \
    -m "${CONTROL_PLANE_MEM}" \
    -e "guestinfo.talos.config=${CONTROL_PLANE_B64_MACHINE_CONFIG}" \
    -e "disk.enableUUID=1" \
    -vm "${MASTER_NAME}"

  sleep 5
  govc vm.disk.change -vm "${MASTER_NAME}" -disk.name "disk-1000-0" -size "${CONTROL_PLANE_DISK}"

  if [ -n "${GOVC_NETWORK:-}" ]; then
    govc vm.network.change -vm "${MASTER_NAME}" -net "${GOVC_NETWORK}" ethernet-0
  fi
  govc vm.power -on "${MASTER_NAME}"

  # Deploy worker
  echo "Launching worker node: ${WORKER_NAME}"
  govc library.deploy "talos-images/talos-${TALOS_VERSION}" "${WORKER_NAME}"

  govc vm.change \
    -c "${WORKER_CPU}" \
    -m "${WORKER_MEM}" \
    -e "guestinfo.talos.config=${WORKER_B64_MACHINE_CONFIG}" \
    -e "disk.enableUUID=1" \
    -vm "${WORKER_NAME}"

  sleep 5
  govc vm.disk.change -vm "${WORKER_NAME}" -disk.name "disk-1000-0" -size "${WORKER_DISK}"

  if [ -n "${GOVC_NETWORK:-}" ]; then
    govc vm.network.change -vm "${WORKER_NAME}" -net "${GOVC_NETWORK}" ethernet-0
  fi
  govc vm.power -on "${WORKER_NAME}"

  echo "== Done deploying ${CLUSTER_NAME}: ${MASTER_NAME}, ${WORKER_NAME} =="
}

bootstrap_for_participant () {
  local p="$1"
  local CLUSTER_NAME
  CLUSTER_NAME="$(cluster_name_for "$p")"
  local MASTER_NAME
  MASTER_NAME="$(master_name_for "$p")"

  local MASTER_IP
  MASTER_IP="$(govc vm.ip "${MASTER_NAME}")"

  echo "Bootstrapping ${CLUSTER_NAME} via ${MASTER_NAME} (${MASTER_IP})"
  talosctl --talosconfig "${CLUSTER_NAME}/talosconfig" bootstrap -e "${MASTER_IP}" -n "${MASTER_IP}"
}

kubeconfig_for_participant () {
  local p="$1"
  local CLUSTER_NAME
  CLUSTER_NAME="$(cluster_name_for "$p")"
  local MASTER_NAME
  MASTER_NAME="$(master_name_for "$p")"

  local MASTER_IP
  MASTER_IP="$(govc vm.ip "${MASTER_NAME}")"

  echo "Retrieve kubeconfig for ${CLUSTER_NAME} from ${MASTER_IP}"
  talosctl --talosconfig "./${CLUSTER_NAME}/talosconfig" config endpoint "${MASTER_IP}"
  talosctl --talosconfig "./${CLUSTER_NAME}/talosconfig" config node "${MASTER_IP}"
  talosctl --talosconfig "./${CLUSTER_NAME}/talosconfig" kubeconfig "./${CLUSTER_NAME}"

  mkdir -p ~/.kube
  mv "${CLUSTER_NAME}/kubeconfig" "~/.kube/${CLUSTER_NAME}"
  sudo chown "$(whoami):$(whoami)" "~/.kube/${CLUSTER_NAME}"

  echo "#!/bin/bash" > "rc-${CLUSTER_NAME}"
  echo "export KUBECONFIG=~/.kube/${CLUSTER_NAME}" >> "rc-${CLUSTER_NAME}"

  echo "Success: source rc-${CLUSTER_NAME}"
}

run_all_participants () {
  for p in $(seq "${PARTICIPANT_START}" "${PARTICIPANT_END}"); do
    echo ""
    echo "=============================="
    echo "== PARTICIPANT ${p}"
    echo "=============================="

    patch_for_participant "${p}"
    gen_config_for_participant "${p}"
    create_for_participant "${p}"
  done
}

run_bootstrap_all () {
  for p in $(seq "${PARTICIPANT_START}" "${PARTICIPANT_END}"); do
    bootstrap_for_participant "${p}"
  done
}

run_kubeconfig_all () {
  for p in $(seq "${PARTICIPANT_START}" "${PARTICIPANT_END}"); do
    kubeconfig_for_participant "${p}"
  done
}

delete_all_clusters() {
  for p in $(seq "${PARTICIPANT_START}" "${PARTICIPANT_END}"); do
    local MASTER_NAME
    MASTER_NAME="$(master_name_for "$p")"
    local WORKER_NAME
    WORKER_NAME="$(worker_name_for "$p")"

    echo "Deleting VMs: ${MASTER_NAME}, ${WORKER_NAME}"
    govc vm.destroy "${MASTER_NAME}" || true
    govc vm.destroy "${WORKER_NAME}" || true
  done
}

# ====== COMMAND ROUTER ======
# Contoh:
#   ./script.sh upload_ova
#   ./script.sh run_all_participants
#   ./script.sh run_bootstrap_all
#   ./script.sh run_kubeconfig_all
#   ./script.sh delete_all_clusters
"$@"
