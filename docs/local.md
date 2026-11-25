# Local Deployment (k3s)

Complete guide to deploy MLflow on a local k3s cluster with the Helm chart and `charts/mlflow/values-local.yaml`. The chart runs PostgreSQL and a local S3 server (moto) in the cluster: you need no AWS account.

## Prerequisites

- [k3s](https://k3s.io/) installed and running (`sudo k3s server` or installed as a service)
- `kubectl` configured to point to the k3s cluster (automatic with k3s)
- `helm` installed (CI uses v4.3.0)
- `openssl`, to generate the database password

### kubectl and KUBECONFIG setup for k3s

On k3s, `kubectl` is available via `sudo k3s kubectl`. To use `kubectl` directly:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# Or adjust permissions so non-root users can read it:
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

> **Tip**: Add `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` to your `~/.bashrc` or `~/.zshrc` to make it persistent.

## Step 1: Configure secrets

```bash
cp .env.example .env
# Generate a database password (letters and digits only: it goes into a connection URI)
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" .env
```

| Variable | Description | Local value |
|----------|-------------|-------------|
| MLFLOW_TRACKING_URI | Tracking URI for `train.py` | `http://localhost:5000` |
| POSTGRES_PASSWORD | PostgreSQL password | output of `openssl rand -hex 24` |
| AWS_ACCESS_KEY_ID | S3 key of the MLflow server | any value: moto accepts all keys |
| AWS_SECRET_ACCESS_KEY | S3 secret of the MLflow server | any value: moto accepts all keys |

> **Note**: The authentication variables (the "Scaleway only" section in `.env.example`) are not required in local mode. You can safely ignore them.

Create the Secret `mlflow-credentials`. The chart creates no Secret: it reads this one.

```bash
source .env
kubectl create secret generic mlflow-credentials \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=aws-access-key-id="$AWS_ACCESS_KEY_ID" \
  --from-literal=aws-secret-access-key="$AWS_SECRET_ACCESS_KEY"
```

---

## Step 2: Install MLflow with the Helm chart

```bash
helm install mlflow charts/mlflow -f charts/mlflow/values-local.yaml --wait --timeout 10m
```

The chart pulls `ghcr.io/tryph0n/mlflow-k8s-helm:3.18.0-1`. CI publishes this image from the `main` branch. If the pull fails (`ImagePullBackOff`), or to use an image that you build yourself, see [Use a local image](#use-a-local-image).

The release starts three pods:

- `mlflow-...`: the MLflow server. Its init container waits for PostgreSQL and moto, then creates the bucket `mlflow`.
- `mlflow-postgresql-0`: PostgreSQL, with the volume claim `data-mlflow-postgresql-0` (2Gi).
- `mlflow-moto-...`: the local S3 server. It keeps the data in memory: the artifacts are lost when this pod restarts.

### Verify

```bash
kubectl get pods -l app.kubernetes.io/instance=mlflow
helm test mlflow --logs
```

`helm test` starts a pod that calls `/health` on the MLflow Service. The output ends with `Phase: Succeeded`.

---

## Step 3: Access MLflow

### Option 1: Port-forward (recommended)

```bash
kubectl port-forward svc/mlflow 5000:5000
```

Verify the connection is working:

```bash
curl http://localhost:5000/health
```

Then open http://localhost:5000 in your browser.

### Option 2: NodePort

The service is of type NodePort. Retrieve the assigned port:

```bash
kubectl get svc mlflow
```

The `PORT(S)` column displays `5000:3xxxx/TCP`. Access it at `http://NODE_IP:3xxxx`.

On k3s, the NODE_IP is usually `127.0.0.1` or the machine's IP address. The chart allows `127.0.0.1` and the private IP ranges (`10.*`, `172.16.*` to `172.31.*`, `192.168.*`) in the MLflow host check. For another address, add it with `--set "mlflow.allowedHosts={<NODE_IP>}"`.

> **Note**: MLflow refuses changes (POST, PUT, DELETE) from a browser page that is not on `localhost` or `127.0.0.1`. To use the UI on `http://NODE_IP:3xxxx`, add `--set "mlflow.corsAllowedOrigins={http://NODE_IP:3xxxx}"`. Scripts such as `train.py` are not affected.

> **Note**: If you use NodePort instead of port-forward, update `MLFLOW_TRACKING_URI` in your `.env` file to match the NodePort URL (e.g. `http://127.0.0.1:3xxxx`) instead of `http://localhost:5000`.

---

## Step 4: Test with a training script

In a first terminal, start the port-forward:

```bash
kubectl port-forward svc/mlflow 5000:5000
```

In a second terminal, install the Python dependencies:

```bash
uv sync
```

Then run the training script:

```bash
uv run python train.py --n_estimators 100 --min_samples_split 2
```

> **Note**: `train.py` calls `load_dotenv()` via `python-dotenv`, so `MLFLOW_TRACKING_URI=http://localhost:5000` from your `.env` file is loaded automatically without any manual `export`. The script needs no S3 keys: the MLflow server stores the artifacts.

Check the results in the MLflow UI (http://localhost:5000): experiment, runs, metrics, and registered model.

---

## Updating

### Change the chart values

Edit `charts/mlflow/values-local.yaml` (or add `--set` options), then:

```bash
helm upgrade mlflow charts/mlflow -f charts/mlflow/values-local.yaml --wait --timeout 10m
```

`helm upgrade` does not keep the `--set` options of earlier commands. If you use a local image, add its `--set image.*` options again (see [Use a local image](#use-a-local-image)).

### Update secrets

```bash
source .env
kubectl delete secret mlflow-credentials
kubectl create secret generic mlflow-credentials \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=aws-access-key-id="$AWS_ACCESS_KEY_ID" \
  --from-literal=aws-secret-access-key="$AWS_SECRET_ACCESS_KEY"
kubectl rollout restart deployment mlflow
```

> **Note**: PostgreSQL reads the password only when it creates the database. To change the password of an existing database, change it in PostgreSQL too (`ALTER USER mlflow PASSWORD '...'`), or delete the volume claim (this deletes the data).

### Use a local image

Build the image, import it into k3s, then install with `image.pullPolicy=Never`:

```bash
docker build -t mlflow-k8s-helm:dev images_mlflow
docker save mlflow-k8s-helm:dev | sudo k3s ctr images import -
helm upgrade --install mlflow charts/mlflow -f charts/mlflow/values-local.yaml \
  --set image.repository=mlflow-k8s-helm --set image.tag=dev --set image.pullPolicy=Never \
  --wait --timeout 10m
```

---

## Full cleanup

```bash
helm uninstall mlflow
kubectl delete pvc data-mlflow-postgresql-0
kubectl delete secret mlflow-credentials
```

> **Warning**: Deleting the PVC permanently destroys all PostgreSQL data. This action is irreversible.

---

## Smoke test (k3d, as in CI)

CI runs the same chart on a [k3d](https://k3d.io/) cluster (k3s in Docker) with `scripts/smoke_test.sh`. You can run it locally on a new k3d cluster:

```bash
docker build -t mlflow-k8s-helm:dev images_mlflow
k3d cluster create smoke --image rancher/k3s:v1.37.2-k3s1
k3d image import mlflow-k8s-helm:dev -c smoke
TAG=dev scripts/smoke_test.sh
k3d cluster delete smoke
```

The script refuses to run when the kubectl context is not a k3d cluster. To run it on your k3s cluster, set `SMOKE_ANY_CONTEXT=1` (it installs the release `mlflow` there).

---

## Troubleshooting

### PostgreSQL does not start

```bash
kubectl describe pod mlflow-postgresql-0
kubectl logs mlflow-postgresql-0
kubectl get pvc
```

Common causes: PVC stuck in Pending (StorageClass not available), Secret `mlflow-credentials` missing.

### MLflow pod not Ready or in CrashLoopBackOff

```bash
kubectl logs deploy/mlflow -c wait-for-dependencies
kubectl logs deploy/mlflow -c mlflow --tail=100
kubectl describe pod -l app.kubernetes.io/instance=mlflow,app.kubernetes.io/component=server
```

Common causes: PostgreSQL not yet Ready, a database password with `@`, `:`, `/` or `%`, an error `Invalid Host header` (see Option 2 above). Status `OOMKilled`: lower `mlflow.workers` or raise `resources.limits.memory`.

### Port-forward not working

```bash
kubectl get endpointslices -l kubernetes.io/service-name=mlflow
```

If the `ENDPOINTS` column is empty, the MLflow pod is not Ready.
