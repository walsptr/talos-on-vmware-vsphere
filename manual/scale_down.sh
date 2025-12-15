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

CONTROL_PLANE_START=4
CONTROL_PLANE_COUNT=2
CONTROL_PLANE_END=$((CONTROL_PLANE_START + CONTROL_PLANE_COUNT - 1))

WORKER_START=2
WORKER_COUNT=1
WORKER_END=$((WORKER_START + WORKER_COUNT - 1))

INFRA_START=2
INFRA_COUNT=1
INFRA_END=$((INFRA_START + INFRA_COUNT - 1))

scaling_master () {
    ## Scale down CONTROL PLANE nodes
    for i in $(seq ${CONTROL_PLANE_START} ${CONTROL_PLANE_END}); do
        echo ""
        echo "Reset control plane node: ${CLUSTER_NAME}-control-plane-${i}"
        echo ""

        CONTROL_PLANE_IP=$(govc vm.ip ${CLUSTER_NAME}-control-plane-${i})
        talosctl --talosconfig ${CLUSTER_NAME}/talosconfig --nodes ${CONTROL_PLANE_IP} reset

        kubectl get nodes | grep ${CONTROL_PLANE_IP} | awk '{print $1}' | xargs -I{} kubectl delete node {}

        govc vm.destroy ${CLUSTER_NAME}-control-plane-${i}
    done
}

scaling_worker () {
    ## Scale down WORKER nodes
    for i in $(seq ${WORKER_START} ${WORKER_END}); do
        echo ""
        echo "Reset worker node: ${CLUSTER_NAME}-worker-${i}"
        echo ""

        CONTROL_PLANE_IP=$(govc vm.ip ${CLUSTER_NAME}-worker-${i})
        talosctl --talosconfig ${CLUSTER_NAME}/talosconfig --nodes ${CONTROL_PLANE_IP} reset

        kubectl get nodes | grep ${CONTROL_PLANE_IP} | awk '{print $1}' | xargs -I{} kubectl delete node {}

        govc vm.destroy ${CLUSTER_NAME}-worker-${i}
    done
}

scaling_infra () {
    ## Scale down INFRA nodes
    for i in $(seq ${INFRA_START} ${INFRA_END}); do
        echo ""
        echo "Reset infra node: ${CLUSTER_NAME}-infra-${i}"
        echo ""

        CONTROL_PLANE_IP=$(govc vm.ip ${CLUSTER_NAME}-infra-${i})
        talosctl --talosconfig ${CLUSTER_NAME}/talosconfig --nodes ${CONTROL_PLANE_IP} reset

        kubectl get nodes | grep ${CONTROL_PLANE_IP} | awk '{print $1}' | xargs -I{} kubectl delete node {}

        govc vm.destroy ${CLUSTER_NAME}-infra-${i}
    done
}

"$@"