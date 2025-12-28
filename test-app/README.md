# Install test app on Talos

## Redis
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install redis bitnami/redis --version 24.1.0 \
  --set auth.enabled=true \
  --set auth.password='P@ssw0rld'
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

secret
```
secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: superset-secret
type: Opaque
data:
  SUPERSET_SECRET_KEY: DB24XmpKNbaRgzDcmLmOhbMOd0uReDiCLsO+2BA4QhCBUv59Mzxgk2bp
```