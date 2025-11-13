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

CONTROL_PLANE_START=1
CONTROL_PLANE_END=1

WORKER_START=1
WORKER_END=3

INFRA_START=1
INFRA_END=3

destroy_master() {
    echo "Delete Control Plane Node"
    for i in $(seq ${CONTROL_PLANE_START} ${CONTROL_PLANE_END}); do
        echo ""
        echo "destroying control plane node: ${CLUSTER_NAME}-control-plane-${i}"
        echo ""

        govc vm.destroy ${CLUSTER_NAME}-control-plane-${i}
    done

    echo "Delete rc file"
    rm -rf rc-${CLUSTER_NAME}

    echo "Delete kubeconfig"
    rm -rf ~/.kube/${CLUSTER_NAME}
}

destroy_worker(){
    
    echo "Delete Worker Node"
    for i in $(seq ${WORKER_START} ${WORKER_END}); do
        echo ""
        echo "destroying worker node: ${CLUSTER_NAME}-worker-${i}"
        echo ""
        govc vm.destroy ${CLUSTER_NAME}-worker-${i}
    done

}

destroy_infra (){
    echo "Delete Infra Node"
    for i in $(seq ${INFRA_START} ${INFRA_END}); do
        echo ""
        echo "destroying infra node: ${CLUSTER_NAME}-infra-${i}"
        echo ""
        govc vm.destroy ${CLUSTER_NAME}-infra-${i}
    done
}

"$@"