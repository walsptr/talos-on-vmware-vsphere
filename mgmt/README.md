1. Download govc and talosctl
```
./mgmt.sh pre_install
```
2. get cp.patch.yaml
```
./mgmt.sh patch
```

3. upload ova
```
./mgmt.sh upload_ova
```

4. gen config
```
./mgmt.sh gen_config
```

5. edit controlplane.yaml
```
cluster.allowSchedulingOnControlPlanes to true
```

6. create
```
./mgmt.sh create
```

7. bootstrap
```
./mgmt.sh bootstrap
```

8. kubeconfig
```
./mgmt.sh kubeconfig
```

9. labeled
```
./mgmt.sh labeled
```


10. Kubectl and Helm installation
```
./mgmt.sh cilium
```

11. cillium connectivity testing
```
# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# Check Cilium status and connectivity
cilium status --wait
cilium connectivity test


# Add label on cilium-test-1 namespace
kubectl label namespace cilium-test-1 pod-security.kubernetes.io/enforce=privileged
```

12. Config vmware tools guest agent
```
./mgmt.sh vmtools
```

14. Deploy ingress nginx
```
./mgmt.sh ingress
```

# Installation CPI
```
helm repo add vsphere-cpi https://kubernetes.github.io/cloud-provider-vsphere
helm repo update

helm upgrade --install vsphere-cpi vsphere-cpi/vsphere-cpi --namespace kube-system --set config.enabled=true --set config.vcenter=<vCenter IP> --set config.username=<vCenter Username> --set config.password=<vCenter Password> --set config.datacenter=<vCenter Datacenter>

kubectl taint nodes --all node.cloudprovider.kubernetes.io/uninitialized-
```

# Deploy CAPV
1. Install clusterctl
```
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.11.3/clusterctl-linux-amd64 -o clusterctl

sudo install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl

clusterctl version
```

2. create clusterctl.yaml
```
mkdir ~/.cluster-api/
vim ~/.cluster-api/clusterctl.yaml

providers:
  - name: "talos"
    url: "https://github.com/siderolabs/cluster-api-bootstrap-provider-talos/releases/v1.11.1/bootstrap-components.yaml"
    type: "BootstrapProvider"
  - name: "talos"
    url: "https://github.com/siderolabs/cluster-api-control-plane-provider-talos/releases/v1.11.1/control-plane-components.yaml"
    type: "ControlPlaneProvider"
  - name: "vsphere"
    url: "https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/releases/download/v1.14.0/infrastructure-components.yaml"
    type: "InfrastructureProvider"

VSPHERE_SERVER: ""
VSPHERE_USERNAME: ""
VSPHERE_PASSWORD: ""
VSPHERE_DATACENTER: ""
VSPHERE_RESOURCE_POOL: "" 
VSPHERE_DATASTORE: ""
VSPHERE_NETWORK: ""
EXP_CLUSTER_RESOURCE_SET: "true"
VSPHERE_TEMPLATE: "talos"
CONTROL_PLANE_ENDPOINT_IP: ""
```

3. install CAPI
```
clusterctl init --config $CLUSTER_NAME/cluster-api/clusterctl.yaml --infrastructure vsphere --control-plane talos --bootstrap talos
```