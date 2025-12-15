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
KUBECONFIG_PATH=${KUBECONFIG_PATH:="./dev-kubeconfig"}
TALOSCONFIG_PATH=${TALOSCONFIG_PATH:="./dev-talosconfig"}

config (){
    kubectl get secret talos-cluster-kubeconfig  -o jsonpath="{.data.value}" | base64 -d > ${KUBECONFIG_PATH}
    kubectl get secret talos-cluster-talosconfig -o jsonpath="{.data.talosconfig}" | base64 -d > ${TALOSCONFIG_PATH}
}

vmtools () {
    export KUBECONFIG=${KUBECONFIG_PATH}

    # search another way to get control plane 1 IP
    CONTROL_PLANE_1_IP=$(kubectl get nodes -o jsonpath="{.items[*].status.addresses[?(@.type=='InternalIP')].address}")
    talosctl --talosconfig ${TALOSCONFIG_PATH} -n ${CONTROL_PLANE_1_IP} config new vmtoolsd-talos-secret.yaml --roles os:admin
    kubectl -n kube-system create secret generic talos-vmtoolsd-config --from-file=talosconfig=vmtoolsd-talos-secret.yaml
}

csi (){
    export KUBECONFIG=${KUBECONFIG_PATH}
    IP_VMWARE=$(echo "$GOVC_URL" | sed -E 's|https?://([^/]+).*|\1|')
    
    echo "Add VMware CPI Helm repository"
    helm repo add vsphere-cpi https://kubernetes.github.io/cloud-provider-vsphere
    helm repo update

    helm upgrade --install vsphere-cpi vsphere-cpi/vsphere-cpi --namespace kube-system --set config.enabled=true --set config.vcenter=${IP_VMWARE} --set config.username=${GOVC_USERNAME} --set config.password=${GOVC_PASSWORD} --set config.datacenter="'${GOVC_DATACENTER}'"

    kubectl get cm vsphere-cloud-config -n kube-system -o yaml \
    | sed -e '/^    # labels for regions and zones$/,/^      zone:/d' \
    | kubectl apply -f -

    kubectl -n kube-system rollout restart ds vsphere-cpi
}


"$@"