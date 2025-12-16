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
./vmware.sh upload_ova
```
6. gen config
```
./vmware.sh gen_config
```

7. edit controlplane.yaml
```
cluster.allowSchedulingOnControlPlanes to true
```

8. create
```
./vmware.sh create
```

9. bootstrap
```
./vmware.sh bootstrap
```

10. kubeconfig
```
./vmware.sh kubeconfig
```

11. labeled
```
./vmware.sh labeled
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

## CPI Deploy
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

## CSI Deployment
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

[VirtualCenter "172.20.0.1"]
insecure-flag = "true"
user = "administrator@vsphere.local"
password = "xxx"
port = "443"
datacenters = "datacenter"
default-datastore = "datastore"
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

## Clustering DRBD


```
# parted /dev/sdb (optional)

sudo parted /dev/sdb --script \
  mklabel gpt \
  mkpart drbd 1MiB 100%
```

```
sudo apt update -y && sudo apt install -y pacemaker pcs resource-agents corosync crmsh drbd-utils
```

```
sudo vim /etc/drbd.d/grafana.res

resource grafana {
  on hqmgmttls-01 {
    device    /dev/drbd0;
    disk      /dev/sdb;
    address   10.10.10.11:7788;
    meta-disk internal;
  }

  on hqmgmttls-02 {
    device    /dev/drbd0;
    disk      /dev/sdb;
    address   10.10.10.12:7788;
    meta-disk internal;
  }

  net {
    cram-hmac-alg sha1;
    shared-secret "CHANGE_ME_SECRET";
  }
}
```

on all node
```
sudo drbdadm create-md grafana
sudo drbdadm up grafana
```

promote drbd on primary node
```
sudo drbdadm primary grafana --force
```

partisi
```
sudo mkfs.xfs -f /dev/drbd0
```

checking replication
```
sudo watch -n 2 cat /proc/drbd
```


blacklist drbd from lvm
```
sudo vim /etc/multipath.conf

blacklist {
    devnode "^drbd[0-9]+"
}

sudo multipath -ll
```

Lanjut ke pacemaker dan corosync
```
sudo systemctl stop pacemaker corosync
sudo systemctl enable --now pcsd
sudo pcs cluster destroy
sudo passwd hacluster
```

auth
```
sudo pcs host auth hqmgmttls-01 hqmgmttls-02 -u hacluster
sudo pcs cluster setup ha_grafana hqmgmttls-01 hqmgmttls-02
sudo pcs cluster start --all
sudo pcs cluster enable --all
```

create resource drbd
```
sudo pcs resource create drbd_grafana ocf:linbit:drbd drbd_resource=grafana \
  op monitor interval=20s role=Master \
  op monitor interval=30s role=Slave \
  promotable master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true

sudo pcs resource master ms_drbd_grafana drbd_grafana \
  master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true
```

Filesystem
```
sudo pcs resource create fs_grafana Filesystem \
  device="/dev/drbd0" directory="/opt/grafana" fstype="xfs" \
  op monitor interval=20s
```


## Monitoring

### Grafana

#### Manual
```
sudo apt-get install -y adduser libfontconfig1 musl apt-transport-https software-properties-common wget

wget https://dl.grafana.com/grafana/release/12.3.0/grafana_12.3.0_19497075765_linux_amd64.tar.gz
tar -zxvf grafana_12.3.0_19497075765_linux_amd64.tar.gz

sudo useradd -r -s /bin/false grafana

sudo mv grafana_12.3.0_19497075765_linux_amd64/bin/grafana /usr/local/bin/grafana
sudo mv grafana_12.3.0_19497075765_linux_amd64 /opt/grafana

sudo chown -R grafana:users /usr/local/grafana

sudo touch /etc/systemd/system/grafana-server.service
```

```
[Unit]
Description=Grafana Server
After=network.target

[Service]
Type=simple
User=grafana
Group=users
ExecStart=/usr/local/bin/grafana server --config=/opt/grafana/conf/grafana.ini --homepath=/opt/grafana
Restart=on-failure

[Install]
WantedBy=multi-user.target  
```


#### Repo
```
sudo apt-get install -y apt-transport-https software-properties-common wget
```

```
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
```

```
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee -a /etc/apt/sources.list.d/grafana.list
```

```
# Updates the list of available packages
sudo apt-get update

# Installs the latest OSS release:
sudo apt-get install grafana
```
disable grafana so not start from systemctl
```
sudo systemctl disable --now grafana-server
```

disable stonith
```
sudo pcs property set stonith-enabled=false
```

svc grafana
```
sudo pcs resource create svc_grafana systemd:grafana-server \
  op monitor interval=20s
```

constraint
```
sudo pcs constraint colocation add fs_grafana with master ms_drbd_grafana INFINITY
sudo pcs constraint colocation add svc_grafana with fs_grafana INFINITY

sudo pcs constraint order promote ms_drbd_grafana then start fs_grafana
sudo pcs constraint order start fs_grafana then start svc_grafana
```

VIP
```
sudo pcs resource create vip_grafana ocf:heartbeat:IPaddr2 \
  ip=10.10.10.50 cidr_netmask=24 nic=ens192 \
  op monitor interval=10s

sudo pcs constraint colocation add vip_grafana with svc_grafana INFINITY
sudo pcs constraint order start svc_grafana then start vip_grafana
sudo pcs constraint order stop vip_grafana then stop svc_grafana


sudo pcs resource move svc_grafana hqmgmttls-02
sudo pcs status
```

### Prometheus for mgmt
```
wget https://github.com/prometheus/prometheus/releases/download/v3.8.0/prometheus-3.8.0.linux-amd64.tar.gz

tar xvf prometheus-3.8.0.linux-amd64.tar.gz

mkdir /etc/prometheus
mkdir /var/lib/prometheus

cd prometheus-3.8.0.linux-amd64
mv prometheus promtool /usr/local/bin/
mv consoles/ console_libraries/ prometheus.yml /etc/prometheus

groupadd --system prometheus
useradd --system -s /sbin/nologin -g prometheus prometheus

chown -R prometheus:prometheus /var/lib/prometheus

vim /etc/prometheus/prometheus.yml
```

```
sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/prometheus \
  --config.file /etc/prometheus/prometheus.yml \
  --storage.tsdb.path /var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle \
  --log.level=info

[Install]
WantedBy=multi-user.target
EOF
```

```
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus
systemctl status prometheus
```

Node Exporter
```
wget https://github.com/prometheus/node_exporter/releases/download/v1.10.2/node_exporter-1.10.2.linux-amd64.tar.gz

tar xvf node_exporter-1.10.2.linux-amd64.tar.gz

cd node_exporter-1.10.2.linux-amd64

mv node_exporter /usr/local/bin
```

```
sudo tee /etc/systemd/system/node-exporter.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus exporter for machine materics

[Service]
User=prometheus
Restart=always
ExecStart=/usr/local/bin/node_exporter
ExecReload=/bin/kill -HUP $MAINPID
TimeoutStopSec=20s
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF
```

Prometheus stack for cluster
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.enabled=false
```

ingress
```
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
    - host: "app1.example.com"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app1-service
                port:
                  number: 8080
```

## Dashboard ID for kube-prometh-stack
```
19105
```