# Install test app on Talos

## Redis
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install redis bitnami/redis --version 24.1.0
```

## Deploy apps on private registry
```
kubectl create secret generic regcred \
    --from-file=.dockerconfigjson=<path/to/.docker/config.json> \
    --type=kubernetes.io/dockerconfigjson
```

Create app using helm
```
helm create superset-test

cd superset-test
```