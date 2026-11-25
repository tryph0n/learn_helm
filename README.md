# MLflow on Kubernetes

[![CI](https://github.com/tryph0n/learn_helm/actions/workflows/ci.yml/badge.svg)](https://github.com/tryph0n/learn_helm/actions/workflows/ci.yml)

Deploy an MLflow tracking server on Kubernetes with a Helm chart: PostgreSQL stores the metadata, S3 stores the artifacts. Two deployment modes: local (k3s, with a local S3 server) and cloud (Scaleway Kapsule, with a real S3 bucket).

> [!WARNING]
> **This repository is a pedagogical exercise / Proof of Concept.**
>
> It demonstrates the feasibility of a local and cloud deployment of an MLOps stack
> (K3s, Scaleway, Helm, Kubernetes, MLflow, PostgreSQL).
>
> **The focus here:** deployment infrastructure with a real PostgreSQL database,
> Helm charts, and Kubernetes orchestration.
>
> **Not the focus:** the ML model and its training, which are intentionally kept simplistic.
>
> This project serves as a base / POC for other students working on Helm, Kubernetes,
> and MLflow topics. It is not a finished product and is not intended to be.


## Architecture

- **Local mode (k3s)**: NodePort Service, no authentication. [moto](https://github.com/getmoto/moto) runs a local S3 server in the cluster, so you need no AWS account.
- **Scaleway mode (Kapsule)**: ClusterIP Service, nginx Ingress with basic auth, access by public IP. The artifacts go to a real S3 bucket (AWS S3 or Scaleway Object Storage).

The MLflow server reads and writes the artifacts itself (proxied artifacts). Clients such as `train.py` need no S3 keys.

The chart is in `charts/mlflow/`. With the release name `mlflow`, it creates:

| Resource | Name | Notes |
|----------|------|-------|
| Deployment and Service | `mlflow` | MLflow server, Service port 5000 |
| StatefulSet and Service | `mlflow-postgresql` | PostgreSQL, volume claim `data-mlflow-postgresql-0` (2Gi) |
| Deployment and Service | `mlflow-moto` | Local S3 server, only when `moto.enabled` is true |
| Ingress | `mlflow` | Only when `ingress.enabled` is true |

The chart creates no Secret. You create the Secret `mlflow-credentials` with `kubectl` (keys `postgres-password`, `aws-access-key-id` and `aws-secret-access-key`), as the guides show.

The folder `k8s/` keeps the first version of this project: raw manifests, before Helm. See `k8s/README.md`.

## Versions

| Component | Version |
|-----------|---------|
| MLflow | 3.18.0 |
| Python | 3.12 (image `python:3.12.16-slim-trixie`) |
| PostgreSQL | 17.12 (image `postgres:17.12`) |
| moto (local S3) | 5.2.5 (image `motoserver/moto:5.2.5`) |
| Helm | v4.3.0 in CI |
| Kubernetes in CI | k3s v1.37.2+k3s1 (k3d v5.9.0) |
| MLflow image | `ghcr.io/tryph0n/mlflow-k8s-helm:3.18.0-1` (amd64 and arm64) |

The image tag `3.18.0-1` is `<MLflow version>-<image revision>`. CI also pushes the tag `sha-<commit>` for each commit on `main`.

The first version used the Bitnami PostgreSQL chart. Bitnami now publishes its free images with the `latest` tag only, so the chart runs the official `postgres` image with a fixed version.

## Common Prerequisites

| Tool | Description | Installation |
|------|-------------|--------------|
| kubectl | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| helm | Helm (CI uses v4.3.0) | [helm.sh](https://helm.sh/docs/intro/install/) |
| uv | Python package manager (to run train.py) | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

The Scaleway mode also needs an S3 bucket: [AWS S3](https://aws.amazon.com/s3/) or [Scaleway Object Storage](https://www.scaleway.com/en/object-storage/).

## Quick Start

```bash
git clone https://github.com/tryph0n/learn_helm.git && cd learn_helm
cp .env.example .env   # then fill in the values
# Follow the deployment guide for your target:
#   Local (k3s)       -> docs/local.md
#   Scaleway Kapsule  -> docs/scaleway.md
```

## Deployment Guides

| Mode | Guide | Additional Prerequisites |
|------|-------|--------------------------|
| **Local (k3s)** | [docs/local.md](docs/local.md) | k3s installed and running |
| **Scaleway Kapsule** | [docs/scaleway.md](docs/scaleway.md) | Scaleway account, `scw` CLI, Kapsule cluster, S3 bucket |

## Environment Variables

Copy the template and fill in the values:

```bash
cp .env.example .env
```

| Variable | Description | Local | Scaleway |
|----------|-------------|:-----:|:--------:|
| MLFLOW_TRACKING_URI | Tracking URI for `train.py` | Required | Required |
| POSTGRES_PASSWORD | PostgreSQL password, letters and digits only (Secret `mlflow-credentials`) | Required | Required |
| AWS_ACCESS_KEY_ID | S3 key of the MLflow server (Secret `mlflow-credentials`) | Any value (moto) | Required |
| AWS_SECRET_ACCESS_KEY | S3 secret of the MLflow server (Secret `mlflow-credentials`) | Any value (moto) | Required |
| MLFLOW_AUTH_USER | User name for the Ingress basic auth | - | Required |
| MLFLOW_AUTH_PASSWORD | Password for the Ingress basic auth | - | Required |

> **IMPORTANT**: The `.env` file contains secrets. Never commit it. It is excluded via `.gitignore`.

## Data

`train.py` downloads a sample of the IBM HR attrition dataset from the Jedha course bucket: `https://full-stack-assets.s3.eu-west-3.amazonaws.com/Deployment/ibm_hr_attrition.xlsx`. No licence is stated for this file. The file is not in this repository, and the code licence does not cover it.

## Continuous integration

The CI workflow (`.github/workflows/ci.yml`) runs ruff, pytest and the README link check. It lints and validates the chart with both values files. Then it builds the image and runs `scripts/smoke_test.sh` on a k3d cluster. The smoke test needs no data and runs no training: it checks that MLflow starts, stores an experiment and stores an artifact. On `main`, CI then pushes the image to GHCR.

## General Troubleshooting

```bash
# Resource overview
kubectl get all

# Helm releases
helm list
helm status mlflow

# Recent events
kubectl get events --sort-by='.lastTimestamp'

# MLflow pod logs (init container and server)
kubectl logs deploy/mlflow --all-containers --tail=50

# PostgreSQL logs
kubectl logs mlflow-postgresql-0
```

MLflow 3 checks the `Host` header of each request. A request to a host that is not allowed gets the error `Invalid Host header - possible DNS rebinding attack detected`. The chart allows `localhost`, `127.0.0.1`, the Service names, the private IP ranges and `ingress.host`. Add other hosts with `mlflow.allowedHosts` (see `charts/mlflow/values.yaml`).

For mode-specific troubleshooting, refer to the corresponding guide.

> **Note**: After working with a specific cluster, remember to switch your kubectl context back if you have multiple clusters configured:
> ```bash
> kubectl config get-contexts
> kubectl config use-context <your-other-context>
> ```

## License

The code is under the MIT licence: see `LICENSE`. The licence does not cover the dataset (see Data).
