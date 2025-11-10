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

CLUSTER_NAME=${CLUSTER_NAME:=dev}
TALOS_VERSION=${TALOS_VERSION:=v1.11.1}

CONTROL_PLANE_START=4
CONTROL_PLANE_COUNT=2
CONTROL_PLANE_END=$((CONTROL_PLANE_START + CONTROL_PLANE_COUNT - 1))
CONTROL_PLANE_CPU=2
CONTROL_PLANE_MEM=4096
CONTROL_PLANE_DISK=30G
CONTROL_PLANE_MACHINE_CONFIG_PATH=${CONTROL_PLANE_MACHINE_CONFIG_PATH:="./${CLUSTER_NAME}/controlplane.yaml"}

WORKER_START=2
WORKER_COUNT=1
WORKER_END=$((WORKER_START + WORKER_COUNT - 1))
WORKER_CPU=2
WORKER_MEM=4096
WORKER_DISK=30G
WORKER_MACHINE_CONFIG_PATH=${WORKER_MACHINE_CONFIG_PATH:="./${CLUSTER_NAME}/worker.yaml"}

INFRA_START=2
INFRA_COUNT=1
INFRA_END=$((INFRA_START + INFRA_COUNT - 1))
INFRA_CPU=2
INFRA_MEM=4096
INFRA_DISK=30G
INFRA_MACHINE_CONFIG_PATH=${INFRA_MACHINE_CONFIG_PATH:="./${CLUSTER_NAME}/worker.yaml"}

scaling_master () {
    ## Encode machine configs
    CONTROL_PLANE_B64_MACHINE_CONFIG=$(cat ${CONTROL_PLANE_MACHINE_CONFIG_PATH}| base64 | tr -d '\n')
    ## Create control plane nodes and edit their settings
    for i in $(seq ${CONTROL_PLANE_START} ${CONTROL_PLANE_COUNT}); do
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
}

scaling_worker () {
    ## Encode machine configs
    WORKER_B64_MACHINE_CONFIG=$(cat ${WORKER_MACHINE_CONFIG_PATH} | base64 | tr -d '\n')

    ## Create WORKER nodes and edit their settings
    ## Create worker nodes and edit their settings
    for i in $(seq ${WORKER_START} ${WORKER_COUNT}); do
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
}

scaling_infra () {
    ## Encode machine configs
    INFRA_B64_MACHINE_CONFIG=$(cat ${INFRA_MACHINE_CONFIG_PATH} | base64 | tr -d '\n')

    ## Create INFRA nodes and edit their settings
    for i in $(seq ${INFRA_START} ${INFRA_COUNT}); do
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

labeled () {
    source rc-${CLUSTER_NAME}
    for i in $(seq ${WORKER_START} ${WORKER_COUNT}); do
      echo "Labeled Worker Node"
      IP_NODE=$(govc vm.ip ${CLUSTER_NAME}-worker-${i})
      NODE_NAME=$(kubectl get nodes -o wide | grep $IP_NODE | awk '{print $1}')
      kubectl label node $NODE_NAME node-role.kubernetes.io/worker=worker
    done

    for i in $(seq ${INFRA_START} ${INFRA_COUNT}); do
      echo "Labeled Infra Node"
      IP_NODE=$(govc vm.ip ${CLUSTER_NAME}-infra-${i})
      NODE_NAME=$(kubectl get nodes -o wide | grep $IP_NODE | awk '{print $1}')
      kubectl label node $NODE_NAME node-role.kubernetes.io/worker=worker node-role.kubernetes.io/infra=infra
    done
}

"$@"