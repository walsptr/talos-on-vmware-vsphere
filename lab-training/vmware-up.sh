#!/bin/bash
set -euo pipefail

# ===== vSphere / govc env =====
export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='xxx'
export GOVC_INSECURE=true
export GOVC_URL='https://172.20.0.1'
export GOVC_DATASTORE='datastore'
export GOVC_NETWORK='network'
export GOVC_DATACENTER='datacenter'
export GOVC_RESOURCE_POOL='/datacenter/host/192.168.1.1/Resources'

# ===== Talos settings =====
TALOS_VERSION=${TALOS_VERSION:=v1.11.1}
OVA_PATH=${OVA_PATH:="https://factory.talos.dev/image/903b2da78f99adef03cbbd4df6714563823f63218508800751560d3bc3557e40/${TALOS_VERSION}/vmware-amd64.ova"}

CONTROL_PLANE_CPU=${CONTROL_PLANE_CPU:=2}
CONTROL_PLANE_MEM=${CONTROL_PLANE_MEM:=4096}
CONTROL_PLANE_DISK=${CONTROL_PLANE_DISK:=40G}

WORKER_CPU=${WORKER_CPU:=2}
WORKER_MEM=${WORKER_MEM:=4096}
WORKER_DISK=${WORKER_DISK:=40G}

# VIP base untuk cluster 1. Cluster 2 = +1, cluster 3 = +2
VIP_TALOS_BASE=${VIP_TALOS_BASE:=172.23.11.45}

# Nama cluster (boleh kamu ubah)
CLUSTERS=("cluster-a" "cluster-b" "cluster-c")

# Mapping 2 peserta per cluster (home dir target copy)
# cluster-a => peserta01 + peserta02
# cluster-b => peserta03 + peserta04
# cluster-c => peserta05 + peserta06
CLUSTER_USERS=("peserta01 peserta02" "peserta03 peserta04" "peserta05 peserta06")

# Node VM yang dipakai (1 master + 1 worker per cluster)
# sengaja pakai 01,03,05 biar tidak “mengambil” semua nomor peserta
CLUSTER_NODE_IDS=("01" "03" "05")

# Kubernetes version (opsional)
K8S_VERSION=${K8S_VERSION:=1.33.1}

# Working dir sementara (untuk gen config sebelum disebar)
WORKDIR=${WORKDIR:=/tmp/talos-lab}

# ===== helpers =====
ip_last_octet() { echo "${1##*.}"; }
ip_prefix_3octets() { echo "${1%.*}"; }

vip_for_cluster_index() {
  local idx="$1" # 0..2
  local base_last prefix last
  base_last="$(ip_last_octet "${VIP_TALOS_BASE}")"
  prefix="$(ip_prefix_3octets "${VIP_TALOS_BASE}")"
  last=$((base_last + idx))
  echo "${prefix}.${last}"
}

master_name_for_id() { echo "talos-master-$1"; }
worker_name_for_id() { echo "talos-worker-$1"; }

ensure_user_home() {
  local user="$1"
  local home="/home/${user}"
  if [ ! -d "${home}" ]; then
    echo "ERROR: home directory ${home} tidak ada"
    exit 1
  fi
}

# ===== functions =====

upload_ova () {
  local VM_NAME="talos-${TALOS_VERSION}"

  echo "Importing OVA to vSphere as temporary VM: ${VM_NAME}"
  govc import.ova -name="${VM_NAME}" -options <(cat <<EOF
{
  "DiskProvisioning": "thin",
  "PowerOn": false,
  "MarkAsTemplate": false,
  "Name": "${VM_NAME}",
  "NetworkMapping": [
    { "Name": "VM Network", "Network": "${GOVC_NETWORK}" }
  ]
}
EOF
) "${OVA_PATH}"

  echo "Mark as template..."
  govc vm.markastemplate "${VM_NAME}"

  echo "Ensure content library talos-images exists..."
  govc library.create "talos-images" || true

  # NOTE: import OVF ke content library dari template VM itu tricky.
  # Kalau kamu sudah punya item di content library, cukup skip upload_ova ini.
  echo "INFO: Pastikan content library 'talos-images' memiliki item 'talos-${TALOS_VERSION}'"
}

make_patches() {
  local vip="$1"

  cat <<EOF > cp.patch.yaml
- op: add
  path: /machine/network
  value:
    interfaces:
    - interface: eth0
      dhcp: true
      vip:
        ip: ${vip}

- op: replace
  path: /cluster/extraManifests
  value:
    - "https://raw.githubusercontent.com/siderolabs/talos-vmtoolsd/refs/tags/v1.4.0/deploy/latest.yaml"
EOF

  cat <<EOF > patch.yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF
}

gen_config_once() {
  local cluster_name="$1"
  local vip="$2"

  mkdir -p "${WORKDIR}/${cluster_name}"
  pushd "${WORKDIR}/${cluster_name}" >/dev/null

  make_patches "${vip}"

  echo "Generate Talos config for ${cluster_name} (VIP ${vip})"
  talosctl gen config "${cluster_name}" "https://${vip}:6443" \
    --kubernetes-version "${K8S_VERSION}" \
    --config-patch-control-plane @cp.patch.yaml \
    --config-patch @patch.yaml

  popd >/dev/null
}

distribute_config_to_users() {
  local cluster_name="$1"
  local users="$2"

  for u in ${users}; do
    ensure_user_home "${u}"
    local target="/home/${u}/${cluster_name}"

    echo "Copy config to ${target}"
    sudo mkdir -p "${target}"
    sudo rsync -a --delete "${WORKDIR}/${cluster_name}/" "${target}/"

    # ownership ke user masing-masing
    sudo chown -R "${u}:${u}" "${target}"
  done
}

deploy_node_from_library() {
  local node_name="$1"
  local cpu="$2"
  local mem="$3"
  local disk="$4"
  local b64cfg="$5"

  govc library.deploy "talos-images/talos-${TALOS_VERSION}" "${node_name}"

  govc vm.change \
    -c "${cpu}" \
    -m "${mem}" \
    -e "guestinfo.talos.config=${b64cfg}" \
    -e "disk.enableUUID=1" \
    -vm "${node_name}"

  sleep 5
  govc vm.disk.change -vm "${node_name}" -disk.name "disk-1000-0" -size "${disk}"

  if [ -n "${GOVC_NETWORK:-}" ]; then
    govc vm.network.change -vm "${node_name}" -net "${GOVC_NETWORK}" ethernet-0
  fi

  govc vm.power -on "${node_name}"
}

create_cluster_vms() {
  local cluster_name="$1"
  local node_id="$2"

  local master
  master="$(master_name_for_id "${node_id}")"
  local worker
  worker="$(worker_name_for_id "${node_id}")"

  # Machine config diambil dari WORKDIR hasil gen config
  local cp_cfg="${WORKDIR}/${cluster_name}/controlplane.yaml"
  local w_cfg="${WORKDIR}/${cluster_name}/worker.yaml"

  local cp_b64 w_b64
  cp_b64="$(base64 -w0 < "${cp_cfg}")"
  w_b64="$(base64 -w0 < "${w_cfg}")"

  echo "Deploy VM for ${cluster_name}: ${master} + ${worker}"
  deploy_node_from_library "${master}" "${CONTROL_PLANE_CPU}" "${CONTROL_PLANE_MEM}" "${CONTROL_PLANE_DISK}" "${cp_b64}"
  deploy_node_from_library "${worker}" "${WORKER_CPU}" "${WORKER_MEM}" "${WORKER_DISK}" "${w_b64}"
}

bootstrap_cluster() {
  local cluster_name="$1"
  local node_id="$2"

  local master
  master="$(master_name_for_id "${node_id}")"
  local master_ip
  master_ip="$(govc vm.ip "${master}")"

  echo "Bootstrap ${cluster_name} via ${master} (${master_ip})"
  talosctl --talosconfig "${WORKDIR}/${cluster_name}/talosconfig" bootstrap -e "${master_ip}" -n "${master_ip}"
}

kubeconfig_once_and_distribute() {
  local cluster_name="$1"
  local node_id="$2"
  local users="$3"

  local master
  master="$(master_name_for_id "${node_id}")"
  local master_ip
  master_ip="$(govc vm.ip "${master}")"

  echo "Get kubeconfig for ${cluster_name} from ${master_ip}"
  talosctl --talosconfig "${WORKDIR}/${cluster_name}/talosconfig" config endpoint "${master_ip}"
  talosctl --talosconfig "${WORKDIR}/${cluster_name}/talosconfig" config node "${master_ip}"
  talosctl --talosconfig "${WORKDIR}/${cluster_name}/talosconfig" kubeconfig "${WORKDIR}/${cluster_name}"

  # Distribusikan kubeconfig & rc file ke masing-masing peserta
  for u in ${users}; do
    local home="/home/${u}"
    local kube_dir="${home}/.kube"
    local kube_target="${kube_dir}/${cluster_name}"
    local rc_target="${home}/rc-${cluster_name}"

    sudo mkdir -p "${kube_dir}"
    sudo cp "${WORKDIR}/${cluster_name}/kubeconfig" "${kube_target}"

    # rc file untuk export KUBECONFIG
    sudo bash -c "cat > '${rc_target}' <<EOF
#!/bin/bash
export KUBECONFIG=${kube_target}
EOF"

    sudo chown -R "${u}:${u}" "${kube_dir}"
    sudo chown "${u}:${u}" "${rc_target}"
    sudo chmod +x "${rc_target}"

    echo "User ${u}: source ${rc_target}"
  done
}

run_all_clusters() {
  mkdir -p "${WORKDIR}"

  for idx in 0 1 2; do
    local cluster_name="${CLUSTERS[$idx]}"
    local users="${CLUSTER_USERS[$idx]}"
    local node_id="${CLUSTER_NODE_IDS[$idx]}"
    local vip
    vip="$(vip_for_cluster_index "${idx}")"

    echo ""
    echo "=============================="
    echo "CLUSTER : ${cluster_name}"
    echo "USERS   : ${users}"
    echo "NODES   : talos-master-${node_id}, talos-worker-${node_id}"
    echo "VIP     : ${vip}"
    echo "WORKDIR : ${WORKDIR}/${cluster_name}"
    echo "=============================="

    gen_config_once "${cluster_name}" "${vip}"
    distribute_config_to_users "${cluster_name}" "${users}"
    create_cluster_vms "${cluster_name}" "${node_id}"
  done
}

run_bootstrap_all() {
  for idx in 0 1 2; do
    bootstrap_cluster "${CLUSTERS[$idx]}" "${CLUSTER_NODE_IDS[$idx]}"
  done
}

run_kubeconfig_all() {
  for idx in 0 1 2; do
    kubeconfig_once_and_distribute "${CLUSTERS[$idx]}" "${CLUSTER_NODE_IDS[$idx]}" "${CLUSTER_USERS[$idx]}"
  done
}

delete_all_nodes() {
  for id in 01 03 05; do
    govc vm.destroy "talos-master-${id}" || true
    govc vm.destroy "talos-worker-${id}" || true
  done
}

"$@"
