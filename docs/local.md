# Local Deployment (k3s)

Complete guide to deploy MLflow on a local k3s cluster.

## Prerequisites

- [k3s](https://k3s.io/) installed and running (`sudo k3s server` or installed as a service)
- `kubectl` configured to point to the k3s cluster (automatic with k3s)
- `helm` v3+ installed
- An AWS S3 bucket (or S3-compatible storage) for artifacts

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
```

Edit `.env` and fill in the variables from the **Common** section:

| Variable | Description | Example |
|----------|-------------|---------|
| PORT | MLflow server port | `8080` |
| BACKEND_STORE_URI | PostgreSQL URI | `postgresql://mlflow:password@mlflow-db-postgresql:5432/mlflow_db` |
| ARTIFACT_ROOT | S3 path | `s3://my-bucket/mlflow-artifacts/` |
| AWS_ACCESS_KEY_ID | AWS key | `AKIA...` |
| AWS_SECRET_ACCESS_KEY | AWS secret | `wJal...` |
| POSTGRES_USER | PostgreSQL user | `mlflow` |
| POSTGRES_PASSWORD | PostgreSQL password | (strong password) |
| POSTGRES_DB | Database name | `mlflow_db` |
| POSTGRES_ADMIN_PASSWORD | Admin password | (strong password) |
| MLFLOW_TRACKING_URI | Local tracking URI | `http://localhost:5000` |

> **Note**: The authentication variables (the "Scaleway only" section in `.env.example`) are not required in local mode. You can safely ignore them.

---

## Step 2: Install PostgreSQL via Helm

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

```bash
source .env
helm install mlflow-db bitnami/postgresql -f values-postgresql.yaml \
  --set auth.username=$POSTGRES_USER \
  --set auth.password=$POSTGRES_PASSWORD \
  --set auth.database=$POSTGRES_DB \
  --set auth.postgresPassword=$POSTGRES_ADMIN_PASSWORD
```

### Verify

```bash
kubectl get pods
```

Wait until `mlflow-db-postgresql-0` shows a `Running` status.

```bash
kubectl logs mlflow-db-postgresql-0
```

The message `database system is ready to accept connections` confirms that PostgreSQL is up and running.

---

## Step 3: Deploy MLflow

### Create the application secret

```bash
kubectl create secret generic mlflow-env-variables --from-env-file=.env
```

### Apply the manifests

```bash
kubectl apply -f k8s/common/mlflow_deployment.yaml
kubectl apply -f k8s/local/mlflow_service.yaml
```

### Verify

```bash
kubectl get pods -l app=mlflow-dashboard
kubectl get svc mlflow-service
```

Wait until both pods show a `Running` status.

---

## Step 4: Access MLflow

### Option 1: Port-forward (recommended)

```bash
kubectl port-forward svc/mlflow-service 5000:5000
```

Verify the connection is working:

```bash
curl http://localhost:5000/health
```

Then open http://localhost:5000 in your browser.

### Option 2: NodePort

The service is of type NodePort. Retrieve the assigned port:

```bash
kubectl get svc mlflow-service
```

The `PORT(S)` column displays `5000:3xxxx/TCP`. Access it at `http://NODE_IP:3xxxx`.

On k3s, the NODE_IP is usually `127.0.0.1` or the machine's IP address.

> **Note**: If you use NodePort instead of port-forward, update `MLFLOW_TRACKING_URI` in your `.env` file to match the NodePort URL (e.g. `http://127.0.0.1:3xxxx`) instead of `http://localhost:5000`.

---

## Step 5: Test with a training script

In a first terminal, start the port-forward:

```bash
kubectl port-forward svc/mlflow-service 5000:5000
```

In a second terminal, install the Python dependencies:

```bash
uv sync
```

Then run the training script:

```bash
uv run python train.py --n_estimators 100 --min_samples_split 2
```

> **Note**: `train.py` calls `load_dotenv()` via `python-dotenv`, so `MLFLOW_TRACKING_URI=http://localhost:5000` from your `.env` file is loaded automatically without any manual `export`.

Check the results in the MLflow UI (http://localhost:5000): experiment, runs, metrics, and registered model.

---

## Updating

### Update secrets

```bash
kubectl delete secret mlflow-env-variables
kubectl create secret generic mlflow-env-variables --from-env-file=.env
kubectl rollout restart deployment mlflow-deployment
```

### Update PostgreSQL

```bash
source .env
helm upgrade mlflow-db bitnami/postgresql -f values-postgresql.yaml \
  --set auth.username=$POSTGRES_USER \
  --set auth.password=$POSTGRES_PASSWORD \
  --set auth.database=$POSTGRES_DB \
  --set auth.postgresPassword=$POSTGRES_ADMIN_PASSWORD
```

---

## Full cleanup

```bash
kubectl delete -f k8s/local/mlflow_service.yaml
kubectl delete -f k8s/common/mlflow_deployment.yaml
kubectl delete secret mlflow-env-variables
helm uninstall mlflow-db
kubectl delete pvc data-mlflow-db-postgresql-0
```

> **Warning**: Deleting the PVC permanently destroys all PostgreSQL data. This action is irreversible.

---

## Troubleshooting

### PostgreSQL does not start

```bash
kubectl describe pod mlflow-db-postgresql-0
kubectl logs mlflow-db-postgresql-0
kubectl get pvc
```

Common causes: PVC stuck in Pending (StorageClass not available), incorrect credentials.

### MLflow pods in CrashLoopBackOff

```bash
kubectl logs -l app=mlflow-dashboard --tail=100
kubectl describe pod -l app=mlflow-dashboard
```

Common causes: PostgreSQL not yet Ready, incorrect BACKEND_STORE_URI, invalid AWS credentials.

### Port-forward not working

```bash
kubectl get endpoints mlflow-service
```

If the endpoints are empty, the MLflow pods are not Ready.
