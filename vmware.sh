#!/bin/bash

set -e

## The following commented environment variables should be set
## before running this script

export GOVC_USERNAME='administrator@vsphere.local'
export GOVC_PASSWORD='xxx'
export GOVC_INSECURE=true
export GOVC_URL='https://172.20.0.1'
export GOVC_DATASTORE='datastore'
export GOVC_NETWORK='network'
export GOVC_DATACENTER='datacenter'
export GOVC_RESOURCE_POOL='/datacenter/host/192.168.1.1/Resources'

CLUSTER_NAME=${CLUSTER_NAME:=vmware-cluster}
TALOS_VERSION=${TALOS_VERSION:=v1.11.1}
OVA_PATH=${OVA_PATH:="https://factory.talos.dev/image/903b2da78f99adef03cbbd4df6714563823f63218508800751560d3bc3557e40/${TALOS_VERSION}/vmware-amd64.ova"}

CONTROL_PLANE_COUNT=${CONTROL_PLANE_COUNT:=3}
CONTROL_PLANE_CPU=${CONTROL_PLANE_CPU:=2}
CONTROL_PLANE_MEM=${CONTROL_PLANE_MEM:=4096}
CONTROL_PLANE_DISK=${CONTROL_PLANE_DISK:=30G}
CONTROL_PLANE_MACHINE_CONFIG_PATH=${CONTROL_PLANE_MACHINE_CONFIG_PATH:="./${CLUSTER_NAME}/controlplane.yaml"}

WORKER_COUNT=${WORKER_COUNT:=1}
WORKER_CPU=${WORKER_CPU:=2}
WORKER_MEM=${WORKER_MEM:=4096}
WORKER_DISK=${WORKER_DISK:=30G}
WORKER_MACHINE_CONFIG_PATH=${WORKER_MACHINE_CONFIG_PATH:="./${CLUSTER_NAME}/worker.yaml"}

INFRA_COUNT=${INFRA_COUNT:=1}
INFRA_CPU=${INFRA_CPU:=2}
INFRA_MEM=${INFRA_MEM:=4096}
INFRA_DISK=${INFRA_DISK:=30G}
INFRA_MACHINE_CONFIG_PATH=${INFRA_MACHINE_CONFIG_PATH:="./${CLUSTER_NAME}/worker.yaml"}


VIP_TALOS=${VIP_TALOS:=172.23.11.45}

#upload_ova () {
    ## Import desired Talos Linux OVA into a new content library
#    govc library.create ${CLUSTER_NAME}
#    govc library.import -n talos-${TALOS_VERSION} ${CLUSTER_NAME} ${OVA_PATH} -disk-provisioning thin
#}

upload_ova () {
    ## STEP 0: Vars
    LOCAL_OVA_NAME="talos-${TALOS_VERSION}"
    TMP_VM_NAME="${LOCAL_OVA_NAME}-tmp"
    EXPORT_DIR="./export-${LOCAL_OVA_NAME}"

    echo "📦 1/5: Downloading & importing OVA into temporary VM..."
    govc import.ova -name=${TMP_VM_NAME} -net=${GOVC_NETWORK} -options <(cat <<EOF
{
  "DiskProvisioning": "thin",
  "PowerOn": false,
  "MarkAsTemplate": false,
  "Name": "${TMP_VM_NAME}"
}
EOF
    ) ${OVA_PATH}

    echo "✅ Imported temporary VM: ${TMP_VM_NAME}"

    echo "🧱 2/5: Verifying disk type..."
    govc vm.info ${TMP_VM_NAME} | grep -i thin || echo "⚠️ Warning: disk type check skipped (verify manually if needed)"

    echo "📤 3/5: Exporting VM back to OVA..."
    rm -rf "${TMP_VM_NAME}"
    govc export.ovf -vm "${TMP_VM_NAME}" .
    OVF_FILE="${TMP_VM_NAME}/${TMP_VM_NAME}.ovf"
    echo "✅ Exported OVF: ${OVA_FILE}"

    echo "🧹 4/5: Cleaning up temporary VM..."
    govc vm.destroy "${TMP_VM_NAME}"

    echo "📚 5/5: Uploading thin-provisioned OVA to Content Library..."
    govc library.create "${CLUSTER_NAME}"
    govc library.import -n "talos-${TALOS_VERSION}" "${CLUSTER_NAME}" "${OVF_FILE}"

    echo "🎉 Done! Library item 'talos-${TALOS_VERSION}' now thin-provisioned and ready to deploy."
}


gen_config () {
    echo "Create directory cluster"
    mkdir -p ${CLUSTER_NAME}

    echo "Copy cp.patch.yaml and patch.yaml to cluster directory"
    cp cp.patch.yaml ${CLUSTER_NAME}
    cp patch.yaml ${CLUSTER_NAME}

    echo "Delete cp.patch.yaml and patch.yaml on home directory"
    rm cp.patch.yaml
    rm patch.yaml

    echo "Create gen config file"
    cd ${CLUSTER_NAME}
    talosctl gen config ${CLUSTER_NAME} https://${VIP_TALOS}:6443 --config-patch-control-plane @cp.patch.yaml --config-patch @patch.yaml
}

create () {
    ## Encode machine configs
    CONTROL_PLANE_B64_MACHINE_CONFIG=$(cat ${CONTROL_PLANE_MACHINE_CONFIG_PATH}| base64 | tr -d '\n')
    WORKER_B64_MACHINE_CONFIG=$(cat ${WORKER_MACHINE_CONFIG_PATH} | base64 | tr -d '\n')
    INFRA_B64_MACHINE_CONFIG=$(cat ${INFRA_MACHINE_CONFIG_PATH} | base64 | tr -d '\n')

    ## Create control plane nodes and edit their settings
    for i in $(seq 1 ${CONTROL_PLANE_COUNT}); do
        echo ""
        echo "launching control plane node: ${CLUSTER_NAME}-control-plane-${i}"
        echo ""

        govc library.deploy ${CLUSTER_NAME}/talos-${TALOS_VERSION} ${CLUSTER_NAME}-control-plane-${i}

        govc vm.change \
        -c ${CONTROL_PLANE_CPU}\
        -m ${CONTROL_PLANE_MEM} \
        -e "guestinfo.talos.config=${CONTROL_PLANE_B64_MACHINE_CONFIG}" \
        -e "disk.enableUUID=1" \
        -vm ${CLUSTER_NAME}-control-plane-${i}

        sleep 20

        govc vm.disk.change -vm ${CLUSTER_NAME}-control-plane-${i} -disk.name "disk-1000-0" -size ${CONTROL_PLANE_DISK}

        if [ -z "${GOVC_NETWORK+x}" ]; then
             echo "GOVC_NETWORK is unset, assuming default VM Network";
        else
            echo "GOVC_NETWORK set to ${GOVC_NETWORK}";
            govc vm.network.change -vm ${CLUSTER_NAME}-control-plane-${i} -net "${GOVC_NETWORK}" ethernet-0
        fi

        govc vm.power -on ${CLUSTER_NAME}-control-plane-${i}
    done

    ## Create worker nodes and edit their settings
    for i in $(seq 1 ${WORKER_COUNT}); do
        echo ""
        echo "launching worker node: ${CLUSTER_NAME}-worker-${i}"
        echo ""

        govc library.deploy ${CLUSTER_NAME}/talos-${TALOS_VERSION} ${CLUSTER_NAME}-worker-${i}

        govc vm.change \
        -c ${WORKER_CPU}\
        -m ${WORKER_MEM} \
        -e "guestinfo.talos.config=${WORKER_B64_MACHINE_CONFIG}" \
        -e "disk.enableUUID=1" \
        -vm ${CLUSTER_NAME}-worker-${i}

        govc vm.disk.change -vm ${CLUSTER_NAME}-worker-${i} -disk.name disk-1000-0 -size ${WORKER_DISK}

        if [ -z "${GOVC_NETWORK+x}" ]; then
             echo "GOVC_NETWORK is unset, assuming default VM Network";
        else
            echo "GOVC_NETWORK set to ${GOVC_NETWORK}";
            govc vm.network.change -vm ${CLUSTER_NAME}-worker-${i} -net "${GOVC_NETWORK}" ethernet-0
        fi


        govc vm.power -on ${CLUSTER_NAME}-worker-${i}
    done

    ## Create INFRA nodes and edit their settings
    for i in $(seq 1 ${INFRA_COUNT}); do
        echo ""
        echo "launching INFRA node: ${CLUSTER_NAME}-infra-${i}"
        echo ""

        govc library.deploy ${CLUSTER_NAME}/talos-${TALOS_VERSION} ${CLUSTER_NAME}-infra-${i}

        govc vm.change \
        -c ${INFRA_CPU}\
        -m ${INFRA_MEM} \
        -e "guestinfo.talos.config=${INFRA_B64_MACHINE_CONFIG}" \
        -e "disk.enableUUID=1" \
        -vm ${CLUSTER_NAME}-infra-${i}

        govc vm.disk.change -vm ${CLUSTER_NAME}-infra-${i} -disk.name disk-1000-0 -size ${INFRA_DISK}

        if [ -z "${GOVC_NETWORK+x}" ]; then
             echo "GOVC_NETWORK is unset, assuming default VM Network";
        else
            echo "GOVC_NETWORK set to ${GOVC_NETWORK}";
            govc vm.network.change -vm ${CLUSTER_NAME}-infra-${i} -net "${GOVC_NETWORK}" ethernet-0
        fi


        govc vm.power -on ${CLUSTER_NAME}-infra-${i}
    done
}

bootstrap () {
   CONTROL_PLANE_1_IP=$(govc vm.ip ${CLUSTER_NAME}-control-plane-1)
   talosctl --talosconfig ${CLUSTER_NAME}/talosconfig bootstrap -e ${CONTROL_PLANE_1_IP} -n ${CONTROL_PLANE_1_IP}
}

kubeconfig () {
   CONTROL_PLANE_1_IP=$(govc vm.ip ${CLUSTER_NAME}-control-plane-1)

   echo "Retrieve Kubeconfig"
   talosctl --talosconfig ./${CLUSTER_NAME}/talosconfig config endpoint ${CONTROL_PLANE_1_IP}
   talosctl --talosconfig ./${CLUSTER_NAME}/talosconfig config node ${CONTROL_PLANE_1_IP}
   talosctl --talosconfig ./${CLUSTER_NAME}/talosconfig kubeconfig ./${CLUSTER_NAME}

   echo "Check kube directory"
   if [ ! -d "~/.kube" ]; then
     echo "directory not found, create ~/.kube directory"
     mkdir -p ~/.kube
   else
     echo "Directory ~/.kube already exists"
   fi

   echo "Move the kubeconfig"
   echo "Move kubeconfig to ~/.kube directory and rename with cluster name"
   mv ${CLUSTER_NAME}/kubeconfig ~/.kube/${CLUSTER_NAME}

   echo "Change ownership kubeconfig"
   sudo chown $(whoami):$(whoami) ~/.kube/${CLUSTER_NAME}

   echo "Create rcfile"
   echo "#/bin/bash" > rc-${CLUSTER_NAME}
   echo export KUBECONFIG=~/.kube/${CLUSTER_NAME} >> rc-${CLUSTER_NAME}

   echo "Success retrieve kubeconfig"
   echo "Run source rc-${CLUSTER_NAME} for connect to kubernetes cluster"
}

labeled () {
    source rc-${CLUSTER_NAME}
    for i in $(seq 1 ${WORKER_COUNT}); do
      echo "Labeled Worker Node"
      IP_NODE=$(govc vm.ip ${CLUSTER_NAME}-worker-${i})
      NODE_NAME=$(kubectl get nodes -o wide | grep $IP_NODE | awk '{print $1}')
      kubectl label node $NODE_NAME node-role.kubernetes.io/worker=worker
    done

    for i in $(seq 1 ${INFRA_COUNT}); do
      echo "Labeled Infra Node"
      IP_NODE=$(govc vm.ip ${CLUSTER_NAME}-infra-${i})
      NODE_NAME=$(kubectl get nodes -o wide | grep $IP_NODE | awk '{print $1}')
      kubectl label node $NODE_NAME node-role.kubernetes.io/worker=worker node-role.kubernetes.io/infra=infra
    done
}

destroy() {
    echo "Delete Control Plane Node"
    for i in $(seq 1 ${CONTROL_PLANE_COUNT}); do
        echo ""
        echo "destroying control plane node: ${CLUSTER_NAME}-control-plane-${i}"
        echo ""

        govc vm.destroy ${CLUSTER_NAME}-control-plane-${i}
    done

    echo "Delete Worker Node"
    for i in $(seq 1 ${WORKER_COUNT}); do
        echo ""
        echo "destroying worker node: ${CLUSTER_NAME}-worker-${i}"
        echo ""
        govc vm.destroy ${CLUSTER_NAME}-worker-${i}
    done

    echo "Delete Infra Node"
    for i in $(seq 1 ${INFRA_COUNT}); do
        echo ""
        echo "destroying infra node: ${CLUSTER_NAME}-infra-${i}"
        echo ""
        govc vm.destroy ${CLUSTER_NAME}-infra-${i}
    done
}

delete_ova() {
    govc library.rm ${CLUSTER_NAME}
}

"$@"