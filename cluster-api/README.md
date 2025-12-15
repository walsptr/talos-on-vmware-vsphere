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

# CPI & CSI

add repo vsphere cpi
```
helm repo add vsphere-cpi https://kubernetes.github.io/cloud-provider-vsphere
helm repo update
```

install vsphere-cpi
```
helm upgrade --install vsphere-cpi vsphere-cpi/vsphere-cpi --namespace kube-system --set config.enabled=true --set config.vcenter=<vCenter IP> --set config.username=<vCenter Username> --set config.password=<vCenter Password> --set config.datacenter=<vCenter Datacenter>
```

if using cilium for cni you need to delete taint cloudprovider for operator to run
```
kubectl taint nodes --all node.cloudprovider.kubernetes.io/uninitialized-
```

edit vsphere-cloud-config
```
kubectl  edit cm -n kube-system vsphere-cloud-config

# delete label region and zone
```

rollout vsphere-cpi
```
kubectl -n kube-system rollout restart ds vsphere-cpi
```


apply to create namespace
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/vsphere-csi-driver/refs/heads/master/manifests/vanilla/namespace.yaml
```

example secret config csi for vmfs
```
vim csi-vsphere.conf

[Global]
cluster-id = "talos-cluster"
cluster-distribution = "Talos"

[VirtualCenter "172.23.0.20"]
insecure-flag = "true"
user = "administrator@idn.local"
password = "Idn123*()"
port = "443"
datacenters = "DC IDN-PALMERAH"
default-datastore = "DS-DATA"
```

create secret
```
kubectl create secret generic vsphere-config-secret --from-file=csi-vsphere.conf --namespace=vmware-system-csi
```

apply csi driver
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/vsphere-csi-driver/refs/heads/master/manifests/vanilla/vsphere-csi-driver.yaml
```

add label vmware-system-csi for privileged escalation
```
kubectl label ns vmware-system-csi pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label ns vmware-system-csi pod-security.kubernetes.io/audit=privileged --overwrite
kubectl label ns vmware-system-csi pod-security.kubernetes.io/warn=privileged --overwrite
```


## testing storage policy
```
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: vmfs-default
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.vsphere.vmware.com
parameters:
  datastoreurl: "ds:///vmfs/volumes/5fdfb4d2-2f0a7f8a/" {optional}
reclaimPolicy: Delete
volumeBindingMode: Immediate
```
jika datastoreurl kosong, CSI akan pilih datastore default dari host ESXi yang terkait node.

datastoreurl can get using govc. 
```
govc datastore.info -json <datastore_name> | grep url
```

testing with statefulset apps
```
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  ports:
    - port: 80
      name: web
  clusterIP: None
  selector:
    app: nginx
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nginx
spec:
  serviceName: "nginx"
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
              name: web
          volumeMounts:
            - name: web-data
              mountPath: /usr/share/nginx/html
          # write something to the volume to verify persistence
          command:
            - /bin/sh
            - -c
            - |
              echo "Pod: $(hostname)" > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'
  volumeClaimTemplates:
    - metadata:
        name: web-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: vmfs-default
        resources:
          requests:
            storage: 2Gi
```

checking
```
kubectl get pods
kubectl get pvc
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
mkdir $CLUSTER_NAME/cluster-api
vim $CLUSTER_NAME/cluster-api/clusterctl.yaml

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

VSPHERE_SERVER: "172.20.0.20"
VSPHERE_USERNAME: "administrator@vsphere.local"
VSPHERE_PASSWORD: "xxx"
VSPHERE_RESOURCE_POOL: "<hostname/ip host/cluster name>/Resources"
VSPHERE_FOLDER: ""
VSPHERE_DATACENTER: "datacenter"
VSPHERE_DATASTORE: "datastore"
VSPHERE_NETWORK: "network"
EXP_CLUSTER_RESOURCE_SET: "true"
VSPHERE_TEMPLATE: "template name"
CONTROL_PLANE_ENDPOINT_IP: "endpoint vip"
CPI_IMAGE_K8S_VERSION: "v1.32.3"
VSPHERE_SSH_AUTHORIZED_KEY: ""
VSPHERE_TLS_THUMBPRINT: "7F:55:25:3F:FA:F7:DE:F9:61:ED:37:9D:C7:DC:8A:90:6E:2E:10:16:C7:D5:DA:41:85:5D:1D:71:2F:14:66:3D"
VSPHERE_STORAGE_POLICY: ""
```

3. install CAPI
```
clusterctl init --config $CLUSTER_NAME/cluster-api/clusterctl.yaml --infrastructure vsphere --control-plane talos --bootstrap talos
```
3. install CAPI
```
clusterctl init --config $CLUSTER_NAME/cluster-api/clusterctl.yaml --infrastructure vsphere --control-plane talos --bootstrap talos
```

5. Create yaml for cluster, vspherecluster, secret and template
```
vim cluster.yaml

apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  labels:
    cluster.x-k8s.io/cluster-name: talos-cluster
  name: talos-cluster
  namespace: default
spec:
  controlPlaneRef:
    apiGroup: controlplane.cluster.x-k8s.io
    kind: TalosControlPlane
    name: talos-cp
  infrastructureRef:
    apiGroup: infrastructure.cluster.x-k8s.io
    kind: VSphereCluster
    name: vsphere-cluster
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: VSphereCluster
metadata:
  name: vsphere-cluster
  namespace: default
spec:
  controlPlaneEndpoint:
    host: 172.23.10.30
    port: 6443
  identityRef:
    kind: Secret
    name: vsphere-secret
  server: 172.23.0.20
  thumbprint: 7F:55:25:3F:FA:F7:DE:F9:61:ED:37:9D:C7:DC:8A:90:6E:2E:10:16:C7:D5:DA:41:85:5D:1D:71:2F:14:66:3D
---
apiVersion: v1
kind: Secret
metadata:
  name: vsphere-secret
  namespace: default
stringData:
  password: Idn123*()
  username: administrator@idn.local
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: VSphereMachineTemplate
metadata:
  name: talos-control-plane
  namespace: default
spec:
  template:
    spec:
      cloneMode: fullClone
      datacenter: 'DC IDN-PALMERAH'
      datastore: DS-DATA
      diskGiB: 30
      folder: ""
      memoryMiB: 8192
      network:
        devices:
        - dhcp4: true
          networkName: VM Network
      numCPUs: 2
      os: Linux
      powerOffMode: trySoft
      resourcePool: '192.168.20.108/Resources'
      server: 172.23.0.20
      storagePolicyName: ""
      template: talos-v1.11.1-tmp
---
apiVersion: controlplane.cluster.x-k8s.io/v1alpha3
kind: TalosControlPlane
metadata:
  name: talos-cp
  namespace: default
spec:
  version: v1.33.1
  replicas: 1
  infrastructureTemplate:
    kind: VSphereMachineTemplate
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    name: talos-control-plane
    namespace: default
  controlPlaneConfig:
    controlplane:
      generateType: controlplane
      talosVersion: v1.11.1
      strategicPatches:
        - |
          - op: add
            path: /cluster/allowSchedulingOnControlPlanes
            value: true
          - op: replace
            path: /cluster/extraManifests
            value:
              - "https://raw.githubusercontent.com/siderolabs/talos-vmtoolsd/refs/tags/v1.4.0/deploy/latest.yaml"
          - op: add
            path: /machine/install/extraKernelArgs
            value:
              - net.ifnames=0
          - op: add
            path: /machine/network/interfaces
            value:
              - interface: eth0
                dhcp: true
                vip:
                  ip: 172.23.10.30
          - op: add
            path: /machine/kubelet/extraArgs
            value:
              cloud-provider: external
```

# Reference
- https://cluster-api.sigs.k8s.io/user/quick-start
- https://a-cup-of.coffee/blog/talos-capi-proxmox/
- https://medium.com/@dhananjayak/harnessing-cluster-api-for-vmware-a-deep-dive-into-management-and-workload-cluster-deployment-fb2c97e1814e

# Noted
```
kubectl get cluster,vspherecluster,machines
```

for example cluster, vspherecluster, etc template u can use this command
```
clusterctl generate cluster capi-quickstart \
  --kubernetes-version v1.34.0 \
  --control-plane-machine-count=3 \
  --worker-machine-count=3 \
  > capi-quickstart.yaml
```


get kubeconfig after provisioning cluster/node in cluster api
```
kubectl get secret talos-cluster-kubeconfig  -o jsonpath="{.data.value}" | base64 -d > kubeconfig
kubectl get secret talos-cluster-talosconfig -o jsonpath="{.data.talosconfig}" | base64 -d > talosconfig
```

create vmtools secret
```
export KUBECONFIG=kubeconfig
CONTROL_PLANE_1_IP=$(kubectl get nodes -o jsonpath="{.items[*].status.addresses[?(@.type=='InternalIP')].address}")
talosctl --talosconfig talosconfig -n 172.23.1.240 config new vmtoolsd-talos-secret.yaml --roles os:admin
kubectl -n kube-system create secret generic talos-vmtoolsd-config --from-file=talosconfig=vmtoolsd-talos-secret.yaml
```

deploy csi
```
export KUBECONFIG=kubeconfig

helm upgrade --install vsphere-cpi vsphere-cpi/vsphere-cpi --namespace kube-system --set config.enabled=true --set config.vcenter=${IP_VMWARE} --set config.username=${GOVC_USERNAME} --set config.password=${GOVC_PASSWORD} --set config.datacenter="'${GOVC_DATACENTER}'"

kubectl get cm vsphere-cloud-config -n kube-system -o yaml \
  | sed -e '/^    # labels for regions and zones$/,/^      zone:/d' \
  | kubectl apply -f -

kubectl -n kube-system rollout restart ds vsphere-cpi
```