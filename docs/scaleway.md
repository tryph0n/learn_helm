# Scaleway Kapsule Deployment

Complete guide to deploying MLflow on a Scaleway Kapsule cluster with the Helm chart and `charts/mlflow/values-scaleway.yaml`: nginx Ingress with basic auth, PostgreSQL in the cluster, artifacts in a real S3 bucket.

## Architecture

```
Client (train.py, browser)
       |
       v
  [ nginx Ingress ]
    basic auth
       |
       v
  [ Service mlflow ]
    ClusterIP:5000
       |
       v
  [ MLflow pod ]
      :8080
     /       \
[PostgreSQL]  [S3 bucket]
 metadata      artifacts
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
- `helm` installed (CI uses v4.3.0)
- An S3 bucket for artifacts: AWS S3, or Scaleway Object Storage (S3-compatible)
- `htpasswd` installed:
  ```bash
  sudo apt-get install apache2-utils
  ```

> **Note**: The image `ghcr.io/tryph0n/mlflow-k8s-helm:3.18.0-1` supports both amd64 and arm64 architectures.

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

> **IMPORTANT**: All `kubectl` and `helm` commands in this guide target the Kapsule cluster. Verify your context before every operation to avoid deploying to the wrong cluster.

## Step 1: Configure secrets

```bash
cp .env.example .env
```

Edit `.env` and fill in **all** the variables:

| Variable | Description | Example |
|----------|-------------|---------|
| MLFLOW_TRACKING_URI | Tracking URI | `http://<EXTERNAL_IP>` (updated after Step 2) |
| POSTGRES_PASSWORD | PostgreSQL password, letters and digits only | output of `openssl rand -hex 24` |
| AWS_ACCESS_KEY_ID | Access key of your S3 bucket | (from AWS IAM or the Scaleway console) |
| AWS_SECRET_ACCESS_KEY | Secret key of your S3 bucket | (from AWS IAM or the Scaleway console) |
| MLFLOW_AUTH_USER | User name for Ingress basic auth | `user@example.com` |
| MLFLOW_AUTH_PASSWORD | Password for Ingress basic auth | (strong password) |

> **Note**: `MLFLOW_TRACKING_URI` will only be known after Step 2, when the Ingress external IP is assigned. Leave it as `http://PENDING` for now and update it once the external IP is available.

> **IMPORTANT**: The `.env` file contains secrets. Never commit it. It is excluded via `.gitignore`.

Create the two Secrets. The chart creates no Secret: it reads `mlflow-credentials`, and the Ingress reads `mlflow-basic-auth`.

```bash
source .env
kubectl create secret generic mlflow-credentials \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=aws-access-key-id="$AWS_ACCESS_KEY_ID" \
  --from-literal=aws-secret-access-key="$AWS_SECRET_ACCESS_KEY"

htpasswd -cb auth "$MLFLOW_AUTH_USER" "$MLFLOW_AUTH_PASSWORD"
kubectl create secret generic mlflow-basic-auth --from-file=auth
rm auth
```

---

## Step 2: Install Nginx Ingress Controller

> **Note**: The Kubernetes project retired ingress-nginx in March 2026: it gets no new releases and no security fixes ([announcement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)). This guide keeps it because the basic auth uses its annotations. For a long-lived cluster, use a [Gateway API](https://gateway-api.sigs.k8s.io/) implementation instead.

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

- Restrict access by source IP: add this annotation to `ingress.annotations` in `charts/mlflow/values-scaleway.yaml`:
```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "YOUR_IP/32"
```

- Add HTTPS with cert-manager (see Production notes)

> **Note**: Local port-forwarding (`kubectl port-forward`) does not go through the Load Balancer and is not exposed to the internet.

---

## Step 3: Install MLflow with the Helm chart

Replace `<EXTERNAL_IP>` with the IP from Step 2, and `<your-bucket>` with your bucket name:

```bash
helm install mlflow charts/mlflow -f charts/mlflow/values-scaleway.yaml \
  --set artifacts.destination=s3://<your-bucket>/mlflow-artifacts \
  --set s3.region=<bucket-region> \
  --set "mlflow.allowedHosts={<EXTERNAL_IP>}" \
  --set "mlflow.corsAllowedOrigins={http://<EXTERNAL_IP>}" \
  --wait --timeout 10m
```

- **AWS S3**: set `s3.region` to the region of the bucket (for example `eu-west-3`).
- **Scaleway Object Storage**: also add `--set s3.endpointUrl=https://s3.fr-par.scw.cloud --set s3.region=fr-par` (use the region of your bucket).

Why the two host options: MLflow 3 refuses a request whose `Host` header is not allowed (error `Invalid Host header - possible DNS rebinding attack detected`). It also refuses changes (POST, PUT, DELETE) from a browser page whose origin is not allowed (error `Cross-origin request blocked`). Through the Ingress, the host is the public IP. With a domain name, use `--set ingress.host=<your-domain>` instead: the chart then allows the domain for both checks.

### Verify

```bash
kubectl get pods -l app.kubernetes.io/instance=mlflow
kubectl get ingress mlflow
helm test mlflow --logs
```

Wait until the pods `mlflow-...` and `mlflow-postgresql-0` show the `Running` status and the Ingress has an assigned address.

### StorageClass

Kapsule provides a default StorageClass for persistent storage (Block Storage SBS). The PostgreSQL StatefulSet of the chart uses it automatically.

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
kubectl describe pvc data-mlflow-postgresql-0
```

---

## Step 4: Access MLflow

Retrieve the Ingress external IP:

```bash
kubectl get ingress mlflow
```

Open `http://<EXTERNAL_IP>` in a browser. The browser will prompt for the basic auth credentials configured in Step 1.

### Test with curl

```bash
source .env
curl -u "$MLFLOW_AUTH_USER:$MLFLOW_AUTH_PASSWORD" "http://<EXTERNAL_IP>/api/2.0/mlflow/experiments/search?max_results=10"
```

### DNS configuration (optional)

The Load Balancer's external IP is sufficient to access MLflow. For more convenient access, you can set up a domain name:

1. Purchase a domain from a registrar (OVH, Gandi, Cloudflare, etc.)
2. Create a DNS A record pointing to the Load Balancer's external IP
3. Upgrade the release with `--set ingress.host=your-domain.com` (see Updates)
4. Access MLflow via `http://your-domain.com`

> **Note**: The Load Balancer IP may change if you recreate it. For a fixed IP, reserve a flexible IP in the Scaleway console and attach it to the Load Balancer.

---

## Step 5: Test with a training script

### Install Python dependencies

```bash
uv sync
```

> **Note**: `train.py` calls `load_dotenv()` at startup, so all variables from your `.env` file (including `MLFLOW_TRACKING_URI`) are loaded automatically. No need to export them manually. The script needs no S3 keys: the MLflow server stores the artifacts.

### Run with port-forward (recommended)

Port-forwarding bypasses the Ingress and basic auth, which is the simplest approach for local training scripts:

```bash
kubectl port-forward svc/mlflow 5000:5000
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

### Change the chart values

Run `helm upgrade` with the same options as `helm install` in Step 3, plus your changes:

```bash
helm upgrade mlflow charts/mlflow -f charts/mlflow/values-scaleway.yaml \
  --set artifacts.destination=s3://<your-bucket>/mlflow-artifacts \
  --set s3.region=<bucket-region> \
  --set "mlflow.allowedHosts={<EXTERNAL_IP>}" \
  --set "mlflow.corsAllowedOrigins={http://<EXTERNAL_IP>}" \
  --wait --timeout 10m
```

### Update the application secrets

```bash
source .env
kubectl delete secret mlflow-credentials
kubectl create secret generic mlflow-credentials \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=aws-access-key-id="$AWS_ACCESS_KEY_ID" \
  --from-literal=aws-secret-access-key="$AWS_SECRET_ACCESS_KEY"
kubectl rollout restart deployment mlflow
```

> **Note**: PostgreSQL reads the password only when it creates the database. To change the password of an existing database, change it in PostgreSQL too (`ALTER USER mlflow PASSWORD '...'`).

### Update the basic auth secret

```bash
source .env
htpasswd -cb auth "$MLFLOW_AUTH_USER" "$MLFLOW_AUTH_PASSWORD"
kubectl delete secret mlflow-basic-auth
kubectl create secret generic mlflow-basic-auth --from-file=auth
rm auth
```

---

## Full cleanup

```bash
helm uninstall mlflow
kubectl delete pvc data-mlflow-postgresql-0
kubectl delete secret mlflow-credentials mlflow-basic-auth
```

> **Warning**: Deleting the PVC permanently destroys the PostgreSQL data. This action is irreversible.

The artifacts stay in your S3 bucket. Delete them from the AWS or Scaleway console if you no longer need them.

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
> Deleting the Kubernetes deployments (`helm uninstall`, `kubectl delete`) does NOT delete the cluster or the Load Balancer. To stop all billing, delete the entire cluster via `scw k8s cluster delete` or the web console.

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
kubectl describe pod mlflow-postgresql-0
kubectl logs mlflow-postgresql-0
kubectl get pvc
```

Common causes: PVC stuck in Pending (StorageClass not available on Kapsule), Secret `mlflow-credentials` missing.

### MLflow pod not Ready or in CrashLoopBackOff

```bash
kubectl logs deploy/mlflow -c wait-for-dependencies
kubectl logs deploy/mlflow -c mlflow --tail=100
kubectl describe pod -l app.kubernetes.io/instance=mlflow,app.kubernetes.io/component=server
```

Common causes: PostgreSQL not yet Ready, a database password with `@`, `:`, `/` or `%`, invalid S3 keys, a wrong `s3.region` or `s3.endpointUrl`. Status `OOMKilled`: lower `mlflow.workers` or raise `resources.limits.memory`.

### 403 error (Invalid Host header or Cross-origin request blocked)

The host or the origin is not allowed by MLflow. Add the public IP or the domain with `mlflow.allowedHosts` and `mlflow.corsAllowedOrigins` (see Step 3), then run `helm upgrade`.

### Ingress has no EXTERNAL-IP

```bash
kubectl get svc -l app.kubernetes.io/name=ingress-nginx
kubectl describe svc ingress-nginx-controller
```

Common causes: the Scaleway LoadBalancer has not yet provisioned the IP (wait a few minutes), LoadBalancer quota reached.

### 503 error on the Ingress

```bash
kubectl get endpointslices -l kubernetes.io/service-name=mlflow
kubectl logs -l app.kubernetes.io/name=ingress-nginx --tail=50
```

Common causes: the MLflow pod is not Ready (empty endpoints).

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

to `ingress.annotations` in `charts/mlflow/values-scaleway.yaml`, then run `helm upgrade`.

---

## Production notes

### Security

- **Basic auth**: sufficient for internal use. For production, consider OAuth2 Proxy or an Identity Provider.
- **HTTPS**: set up cert-manager with Let's Encrypt to obtain an automatic TLS certificate, then set `ingress.host` and `ingress.tls`:
  - [cert-manager with an NGINX Ingress](https://cert-manager.io/docs/tutorials/acme/nginx-ingress/)
- **Network Policies**: restrict traffic between pods if needed.

### Scalability

- The chart runs 1 MLflow replica (`replicaCount`): on a new database, two pods would run the schema migration at the same time. After the first start, you can raise `replicaCount` based on load.
- PostgreSQL runs as a single pod. For high availability, use a managed database (for example Scaleway Managed Database for PostgreSQL) with `postgresql.enabled=false` and the `externalDatabase.*` values.

### Storage

- The PostgreSQL PVC uses the Kapsule default StorageClass (Block Storage SBS).
- Default size: 2Gi (`postgresql.persistence.size` in `charts/mlflow/values-scaleway.yaml`).

### Backups

- MLflow artifacts are stored in S3 (already durable).
- For PostgreSQL, set up regular backups (pg_dump or Scaleway snapshots).

---

## Scaleway references

- [Kapsule documentation](https://www.scaleway.com/en/docs/containers/kubernetes/)
- [Scaleway CLI Quickstart](https://www.scaleway.com/en/docs/developer-tools/scaleway-cli/quickstart/)
- [Deploy an Ingress Controller on Kapsule](https://www.scaleway.com/en/docs/containers/kubernetes/reference-content/using-load-balancer-annotations/)
- [cert-manager with an NGINX Ingress](https://cert-manager.io/docs/tutorials/acme/nginx-ingress/)
- [Block Storage (SBS) on Kapsule](https://www.scaleway.com/en/docs/kubernetes/api-cli/managing-storage/)
