# MLflow on Kubernetes

Deploying MLflow with PostgreSQL (metadata store) and AWS S3 (artifact store) on Kubernetes, using a pre-built Docker image (`sambot961/image-mlflow:latest`). Supports two deployment modes: local (k3s) and cloud (Scaleway Kapsule).

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


**Local mode (k3s)**: NodePort Service, direct access without authentication
**Scaleway mode (Kapsule)**: ClusterIP Service + Nginx Ingress + basic auth, access via public IP

## Versions

| Component | Version |
|-----------|---------|
| MLflow | 2.21.3 |
| Helm | 3+ |
| Base image | python:3.10 |
| MLflow image | sambot961/image-mlflow:latest |

## Common Prerequisites

| Tool | Description | Installation |
|------|-------------|--------------|
| kubectl | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| helm | Helm v3+ | [helm.sh](https://helm.sh/docs/intro/install/) |
| uv | Python package manager (to run train.py) | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| AWS S3 bucket | S3 bucket (or S3-compatible storage) for MLflow artifacts | [aws.amazon.com/s3](https://aws.amazon.com/s3/) |

## Quick Start

```bash
git clone <repo-url> && cd learn_helm
cp .env.example .env   # then fill in your secrets
# Follow the deployment guide for your target:
#   Local (k3s)       → docs/local.md
#   Scaleway Kapsule  → docs/scaleway.md
```

## Deployment Guides

| Mode | Guide | Additional Prerequisites |
|------|-------|--------------------------|
| **Local (k3s)** | [docs/local.md](docs/local.md) | k3s installed and running |
| **Scaleway Kapsule** | [docs/scaleway.md](docs/scaleway.md) | Scaleway account, `scw` CLI, Kapsule cluster |

## Environment Variables

Copy the template and fill in the values:

```bash
cp .env.example .env
```

| Variable | Description | Local | Scaleway |
|----------|-------------|:-----:|:--------:|
| PORT | MLflow server port | Required | Required |
| BACKEND_STORE_URI | PostgreSQL URI | Required | Required |
| ARTIFACT_ROOT | S3 path for artifacts | Required | Required |
| AWS_ACCESS_KEY_ID | AWS key | Required | Required |
| AWS_SECRET_ACCESS_KEY | AWS secret | Required | Required |
| POSTGRES_USER | PostgreSQL user | Required | Required |
| POSTGRES_PASSWORD | PostgreSQL password | Required | Required |
| POSTGRES_DB | Database name | Required | Required |
| POSTGRES_ADMIN_PASSWORD | PostgreSQL admin password | Required | Required |
| MLFLOW_TRACKING_URI | Tracking URI (local scripts) | Required | Required |
| MLFLOW_AUTH_USER | Email for Ingress basic auth | - | Required |
| MLFLOW_AUTH_PASSWORD | Password for Ingress basic auth | - | Required |

> **IMPORTANT**: The `.env` file contains secrets. Never commit it. It is excluded via `.gitignore`.

## General Troubleshooting

```bash
# Resource overview
kubectl get all

# Helm releases
helm list

# Recent events
kubectl get events --sort-by='.lastTimestamp'

# MLflow pod logs
kubectl logs -l app=mlflow-dashboard --tail=50

# PostgreSQL logs
kubectl logs mlflow-db-postgresql-0
```

For mode-specific troubleshooting, refer to the corresponding guide.

> **Note**: After working with a specific cluster, remember to switch your kubectl context back if you have multiple clusters configured:
> ```bash
> kubectl config get-contexts
> kubectl config use-context <your-other-context>
> ```
