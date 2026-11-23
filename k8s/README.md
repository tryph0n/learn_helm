# Raw manifests (before Helm)

These files are the first version of this project: plain Kubernetes manifests, applied with
`kubectl apply`. They stay here as an example of what the Helm chart replaces.

The Helm chart in [`charts/mlflow/`](../charts/mlflow/) is the reference. These files are not
maintained and CI does not test them.

| File | Content |
|---|---|
| `common/mlflow_deployment.yaml` | MLflow server Deployment (2 replicas), environment from the Secret `mlflow-env-variables` |
| `common/mlflow_secrets.yaml` | Shape of the Secret `mlflow-env-variables`, with placeholders. Do not apply it. |
| `local/mlflow_service.yaml` | NodePort Service for a local cluster |
| `scaleway/mlflow_service.yaml` | ClusterIP Service for Scaleway Kapsule |
| `scaleway/mlflow_ingress.yaml` | nginx Ingress with basic auth (Secret `mlflow-basic-auth`) |

## What the manifests need

The chart does these things for you. With the raw manifests, you do them by hand:

- A PostgreSQL server. The first version installed it with the Bitnami PostgreSQL chart
  (release `mlflow-db`, Service `mlflow-db-postgresql`). This repository no longer uses Bitnami:
  its free images are now published with the `latest` tag only.
- An S3 bucket for the artifacts. The manifests have no local S3 server.
- The Secret `mlflow-env-variables`. The comments in `common/mlflow_secrets.yaml` refer to the old
  `.env` file, which no longer has these keys. Create the Secret with `--from-literal`:

```bash
kubectl create secret generic mlflow-env-variables \
  --from-literal=PORT=8080 \
  --from-literal=BACKEND_STORE_URI=postgresql+psycopg2://<user>:<password>@mlflow-db-postgresql:5432/<database> \
  --from-literal=ARTIFACT_ROOT=s3://<your-bucket>/mlflow-artifacts \
  --from-literal=AWS_ACCESS_KEY_ID=<access-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret-access-key>

kubectl apply -f k8s/common/mlflow_deployment.yaml -f k8s/local/mlflow_service.yaml
```

The image has the psycopg2 driver. Keep `+psycopg2` in the URI: SQLAlchemy 2.1 uses psycopg 3
for a plain `postgresql://` URI, and the server then stops with `No module named 'psycopg'`.

## Known limits

- MLflow 3 checks the `Host` header of each request. By default it accepts `localhost`, `127.0.0.1`
  and the private IP ranges (`10.*`, `172.16.*` to `172.31.*`, `192.168.*`). A request to a public
  IP or a domain gets an error. To allow it, add the key `MLFLOW_SERVER_ALLOWED_HOSTS` to the Secret,
  for example `localhost:*,127.0.0.1:*,mlflow-service:*,<EXTERNAL_IP>`. This list replaces the
  defaults. The chart builds this list for you.
- With 2 replicas on a new database, both pods can run the schema migration at the same time.
  The chart uses 1 replica.
- The Deployment has no probes, no resource limits and no security context.
