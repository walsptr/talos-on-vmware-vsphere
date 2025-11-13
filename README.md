1. Download govc and talosctl
```
curl -L -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | sudo tar -C /usr/local/bin -xvzf - govc

curl -sL https://talos.dev/install | sh
```
2. get cp.patch.yaml
```
curl -fsSLO https://raw.githubusercontent.com/siderolabs/talos/refs/tags/v1.11.0/website/content/v1.8/talos-guides/install/virtualized-platforms/vmware/cp.patch.yaml
```
3. edit cp.patch.yaml
```
- op: add
  path: /machine/network
  value:
    interfaces:
    - interface: eth0
      dhcp: true
      vip:
        ip: <VIP>

- op: replace
  path: /cluster/extraManifests
  value:
    - "https://raw.githubusercontent.com/siderolabs/talos-vmtoolsd/refs/tags/v1.4.0/deploy/latest.yaml"
```
4. create patch.yaml
```
cat <<EOF | sudo tee patch.yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF
```
5. upload ova
```
./mgmt.sh upload_ova
```
6. gen config
```
./mgmt.sh gen_config
```

7. edit controlplane.yaml
```
cluster.allowSchedulingOnControlPlanes to true
```

8. create
```
./mgmt.sh create
```

9. bootstrap
```
./mgmt.sh bootstrap
```

10. kubeconfig
```
./mgmt.sh kubeconfig
```

11. labeled
```
./mgmt.sh labeled
```


11. Kubectl and Helm installation
```

curl -LO https://dl.k8s.io/release/v1.33.4/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client


# Helm installation
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add cilium repo
helm repo add cilium https://helm.cilium.io/
helm repo update
```

12. Cillium installation
```
helm install \
    cilium \
    cilium/cilium \
    --version 1.18.0 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set k8s.requireIPv4PodCIDR=true \
    --set kubeProxyReplacement=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set operator.tolerateMaster=true \
    --set k8sServicePort=7445
```

13. cillium connectivity testing
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

14. Config vmware tools guest agent
```
# Create new talos config for secret
talosctl --talosconfig talosconfig -n <control plane IP> config new vmtoolsd-secret.yaml --roles os:admin

# Create secret
kubectl -n kube-system create secret generic talos-vmtoolsd-config --from-file=talosconfig=vmtoolsd-secret.yaml
```

15. Deploy ingress nginx
```
# Add Helm Repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install ingress-nginx with helm
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=3 \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443
```



# Noted
enable scheduling on controlplane
```
cluster:
    allowSchedulingOnControlPlanes: true  
```

enable cloudprovider external
```
  externalCloudProvider:
    enabled: true
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