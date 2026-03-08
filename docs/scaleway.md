# Scaleway Kapsule Deployment

Complete guide to deploying MLflow on a Scaleway Kapsule cluster with Nginx Ingress and basic auth.

## Architecture

```
Client (train.py)
       |
       v
  [ Nginx Ingress ]
    basic auth
       |
       v
  [ MLflow Service ]
    ClusterIP:5000
     /        \
[ Pod 1 ]  [ Pod 2 ]
  :8080      :8080
   |           |
   +-----+-----+
         |
    +----+----+
    |         |
[PostgreSQL] [AWS S3]
 metadata    artifacts
```

## Prerequisites

- A [Scaleway](https://www.scaleway.com/) account with a Kapsule cluster already created
- [scw CLI](https://www.scaleway.com/en/docs/developer-tools/scaleway-cli/quickstart/) installed and configured
- `kubectl` configured to point to the Kapsule cluster:
  ```bash
  # List your clusters to find the cluster ID:
  scw k8s cluster list

  # Install the kubeconfig for your cluster:
  scw k8s kubeconfig install <cluster-id>
  ```
- `helm` v3+ installed
- An AWS S3 bucket (or S3-compatible storage) for artifacts
- `htpasswd` installed:
  ```bash
  sudo apt-get install apache2-utils
  ```

> **Note**: The pre-built image `sambot961/image-mlflow:latest` supports both amd64 and arm64 architectures.

### Private network (VPC)

Kapsule clusters are associated with a Private Network inside a Scaleway VPC. If you created your cluster through the web console, the VPC and Private Network were created automatically.

To verify:

```bash
scw vpc private-network list
```

> **Note**: Pods and services communicate with each other through the cluster's private network. No additional configuration is required for the MLflow deployment.

### Managing kubectl contexts

If you have multiple clusters (local + Scaleway), make sure you are using the correct context:

```bash
# List all available contexts
kubectl config get-contexts

# Switch to the Scaleway Kapsule context
kubectl config use-context <your-kapsule-context>

# Verify you're connected to the right cluster
kubectl get nodes
```

> **IMPORTANT**: All `kubectl` commands in this guide target the Kapsule cluster. Verify your context before every operation to avoid deploying to the wrong cluster.

## Step 1: Configure secrets

```bash
cp .env.example .env
```

Edit `.env` and fill in **all** the variables (common + Scaleway):

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
| MLFLOW_TRACKING_URI | Tracking URI | `http://<EXTERNAL_IP>` (updated after Step 3) |
| MLFLOW_AUTH_USER | Email for Ingress basic auth | `user@example.com` |
| MLFLOW_AUTH_PASSWORD | Password for Ingress basic auth | (strong password) |

> **Note**: `MLFLOW_TRACKING_URI` will only be known after Step 3, when the Ingress external IP is assigned. Leave it as `http://PENDING` for now and update it once the external IP is available.

> **IMPORTANT**: The `.env` file contains secrets. Never commit it. It is excluded via `.gitignore`.

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

Wait until `mlflow-db-postgresql-0` shows the `Running` status.

```bash
kubectl logs mlflow-db-postgresql-0
```

The message `database system is ready to accept connections` confirms that PostgreSQL is up and running.

### StorageClass

Kapsule provides a default StorageClass for persistent storage (Block Storage SBS). The PostgreSQL chart uses it automatically.

To check the available StorageClasses:

```bash
kubectl get storageclass
```

Expected output (the name may vary):

```
NAME                   PROVISIONER        RECLAIMPOLICY   VOLUMEBINDINGMODE
scw-bssd (default)     csi.scaleway.com   Delete          Immediate
scw-bssd-retain        csi.scaleway.com   Retain          Immediate
```

If the PostgreSQL PVC stays in `Pending`, investigate:

```bash
kubectl get pvc
kubectl describe pvc data-mlflow-db-postgresql-0
```

---

## Step 3: Install Nginx Ingress Controller

Scaleway Kapsule provides a built-in Nginx Ingress Controller addon. If it is not already enabled:

```bash
scw k8s cluster list
```

Check that the Ingress addon is enabled on the cluster. If not, enable it from the Scaleway console or via CLI.

Alternatively, install it manually:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx
```

### Verify

```bash
kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx
kubectl get svc -l app.kubernetes.io/name=ingress-nginx
```

Wait until the Ingress service has an assigned `EXTERNAL-IP` (Scaleway LoadBalancer).

```bash
kubectl get svc ingress-nginx-controller
```

Take note of the external IP address: this is the public IP to access MLflow.

> **Note**: Now that you have the external IP, go back and update `MLFLOW_TRACKING_URI` in your `.env` file (see Step 1).

### Network security

By default, Kapsule nodes are protected by Scaleway Security Groups. The Load Balancer created by the Ingress Controller exposes ports 80 (HTTP) and 443 (HTTPS) to the internet.

The basic auth configured on the Ingress protects access to MLflow. To strengthen security:

- Restrict access by source IP in the Ingress annotations:
```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "YOUR_IP/32"
```

- Add HTTPS with cert-manager (see Production notes)

> **Note**: Local port-forwarding (`kubectl port-forward`) does not go through the Load Balancer and is not exposed to the internet.

---

## Step 4: Deploy MLflow

### 4.1 Create the application secret

```bash
kubectl create secret generic mlflow-env-variables --from-env-file=.env
```

### 4.2 Create the basic auth secret for the Ingress

Generate the htpasswd file:

```bash
source .env
htpasswd -cb auth "$MLFLOW_AUTH_USER" "$MLFLOW_AUTH_PASSWORD"
kubectl create secret generic mlflow-basic-auth --from-file=auth
rm auth
```

### 4.3 Apply the manifests

```bash
kubectl apply -f k8s/common/mlflow_deployment.yaml
kubectl apply -f k8s/scaleway/mlflow_service.yaml
kubectl apply -f k8s/scaleway/mlflow_ingress.yaml
```

### Verify

```bash
kubectl get pods -l app=mlflow-dashboard
kubectl get svc mlflow-service
kubectl get ingress mlflow-ingress
```

Wait until the 2 pods show the `Running` status and the Ingress has an assigned address.

---

## Step 5: Access MLflow

Retrieve the Ingress external IP:

```bash
kubectl get ingress mlflow-ingress
```

Open `http://<EXTERNAL_IP>` in a browser. The browser will prompt for the basic auth credentials configured in step 4.2.

### Test with curl

```bash
source .env
curl -u "$MLFLOW_AUTH_USER:$MLFLOW_AUTH_PASSWORD" http://<EXTERNAL_IP>/api/2.0/mlflow/experiments/search
```

### DNS configuration (optional)

The Load Balancer's external IP is sufficient to access MLflow. For more convenient access, you can set up a domain name:

1. Purchase a domain from a registrar (OVH, Gandi, Cloudflare, etc.)
2. Create a DNS A record pointing to the Load Balancer's external IP
3. Access MLflow via `http://your-domain.com`

> **Note**: The Load Balancer IP may change if you recreate it. For a fixed IP, reserve a flexible IP in the Scaleway console and attach it to the Load Balancer.

---

## Step 6: Test with a training script

### Install Python dependencies

```bash
uv sync
```

> **Note**: `train.py` calls `load_dotenv()` at startup, so all variables from your `.env` file (including `MLFLOW_TRACKING_URI`) are loaded automatically. No need to export them manually.

### Run with port-forward (recommended)

Port-forwarding bypasses the Ingress and basic auth, which is the simplest approach for local training scripts:

```bash
kubectl port-forward svc/mlflow-service 5000:5000
```

In a separate terminal:

```bash
MLFLOW_TRACKING_URI=http://localhost:5000 uv run python train.py --n_estimators 100 --min_samples_split 2
```

### Alternative: run through the Ingress

If you want to go through the Ingress (e.g., from a remote machine), the MLflow client supports basic auth via environment variables:

```bash
export MLFLOW_TRACKING_URI=http://<EXTERNAL_IP>
export MLFLOW_TRACKING_USERNAME=$MLFLOW_AUTH_USER
export MLFLOW_TRACKING_PASSWORD=$MLFLOW_AUTH_PASSWORD
uv run python train.py --n_estimators 100 --min_samples_split 2
```

Check the results in the MLflow UI: experiment, runs, metrics, registered model.

---

## Updates

### Update the application secrets

```bash
kubectl delete secret mlflow-env-variables
kubectl create secret generic mlflow-env-variables --from-env-file=.env
kubectl rollout restart deployment mlflow-deployment
```

### Update the basic auth secret

```bash
source .env
htpasswd -cb auth "$MLFLOW_AUTH_USER" "$MLFLOW_AUTH_PASSWORD"
kubectl delete secret mlflow-basic-auth
kubectl create secret generic mlflow-basic-auth --from-file=auth
rm auth
```

### Update the Kubernetes manifests

```bash
kubectl apply -f k8s/common/mlflow_deployment.yaml
kubectl apply -f k8s/scaleway/mlflow_service.yaml
kubectl apply -f k8s/scaleway/mlflow_ingress.yaml
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
kubectl delete -f k8s/scaleway/mlflow_ingress.yaml
kubectl delete -f k8s/scaleway/mlflow_service.yaml
kubectl delete -f k8s/common/mlflow_deployment.yaml
kubectl delete secret mlflow-env-variables
kubectl delete secret mlflow-basic-auth
helm uninstall mlflow-db
kubectl delete pvc data-mlflow-db-postgresql-0
```

> **Warning**: Deleting the PVC permanently destroys the PostgreSQL data. This action is irreversible.

### Delete the Kapsule cluster

If you no longer need the cluster:

```bash
# List clusters to find the ID
scw k8s cluster list

# Delete the cluster (replace CLUSTER_ID)
scw k8s cluster delete CLUSTER_ID
```

> **BILLING WARNING**: As long as the cluster and its resources exist, you are billed for:
> - **Nodes** (Scaleway instances): main cost (~10-30 EUR/month per node depending on the type)
> - **Load Balancer** (created by the Ingress): ~10 EUR/month
> - **Block Storage** (PostgreSQL PVC): ~0.10 EUR/GB/month
>
> Deleting the Kubernetes deployments (`kubectl delete`) does NOT delete the cluster or the Load Balancer. To stop all billing, delete the entire cluster via `scw k8s cluster delete` or the web console.

### Post-cleanup verification

Check in the Scaleway console (console.scaleway.com) that the following resources have been properly deleted:
- Kapsule cluster
- Load Balancer
- Block Storage volumes

### Switch kubectl context back

After you are done working with the Scaleway cluster, switch your kubectl context back to your local cluster (or default context):

```bash
# List all contexts
kubectl config get-contexts

# Switch back to your local context
kubectl config use-context <your-local-context>
```

> **Important**: Always verify which cluster you are targeting before running kubectl commands, especially destructive ones like `delete`.

---

## Troubleshooting

### PostgreSQL does not start

```bash
kubectl describe pod mlflow-db-postgresql-0
kubectl logs mlflow-db-postgresql-0
kubectl get pvc
```

Common causes: PVC stuck in Pending (StorageClass not available on Kapsule), incorrect credentials.

### MLflow pods in CrashLoopBackOff

```bash
kubectl logs -l app=mlflow-dashboard --tail=100
kubectl describe pod -l app=mlflow-dashboard
```

Common causes: PostgreSQL not yet Ready, incorrect BACKEND_STORE_URI, invalid AWS credentials.

### Ingress has no EXTERNAL-IP

```bash
kubectl get svc -l app.kubernetes.io/name=ingress-nginx
kubectl describe svc ingress-nginx-controller
```

Common causes: the Scaleway LoadBalancer has not yet provisioned the IP (wait a few minutes), LoadBalancer quota reached.

### 503 error on the Ingress

```bash
kubectl get endpoints mlflow-service
kubectl logs -l app.kubernetes.io/name=ingress-nginx --tail=50
```

Common causes: MLflow pods are not Ready (empty endpoints), the Service selector does not match the Deployment labels.

### 401 error (Unauthorized)

```bash
kubectl get secret mlflow-basic-auth -o yaml
```

Common causes: the `mlflow-basic-auth` secret does not exist or the `auth` file was generated incorrectly. Recreate it with `htpasswd`.

### 413 error (Request Entity Too Large)

Nginx Ingress has a default body size limit. For large artifacts, add the following annotation:

```yaml
nginx.ingress.kubernetes.io/proxy-body-size: "100m"
```

in the `k8s/scaleway/mlflow_ingress.yaml` file.

---

## Production notes

### Security

- **Basic auth**: sufficient for internal use. For production, consider OAuth2 Proxy or an Identity Provider.
- **HTTPS**: set up cert-manager with Let's Encrypt to obtain an automatic TLS certificate:
  - [cert-manager on Kapsule](https://www.scaleway.com/en/docs/tutorials/cert-manager-kapsule/)
- **Network Policies**: restrict traffic between pods if needed.

### Scalability

- The MLflow Deployment is configured with 2 replicas. Adjust in `k8s/common/mlflow_deployment.yaml` based on load.
- PostgreSQL is deployed in standalone mode (1 replica). For high availability, use `architecture: replication` in `values-postgresql.yaml`.

### Storage

- The PostgreSQL PVC uses the Kapsule default StorageClass (Block Storage SBS).
- Default size: 2Gi (configurable in `values-postgresql.yaml`).

### Backups

- MLflow artifacts are stored in S3 (already durable).
- For PostgreSQL, set up regular backups (pg_dump or Scaleway snapshots).

---

## Scaleway references

- [Kapsule documentation](https://www.scaleway.com/en/docs/containers/kubernetes/)
- [Scaleway CLI Quickstart](https://www.scaleway.com/en/docs/developer-tools/scaleway-cli/quickstart/)
- [Deploy an Ingress Controller on Kapsule](https://www.scaleway.com/en/docs/containers/kubernetes/reference-content/using-load-balancer-annotations/)
- [cert-manager on Kapsule](https://www.scaleway.com/en/docs/tutorials/cert-manager-kapsule/)
- [Block Storage (SBS) on Kapsule](https://www.scaleway.com/en/docs/containers/kubernetes/reference-content/managing-storage/)
