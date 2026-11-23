FROM python:3.12.16-slim-trixie

COPY --from=ghcr.io/astral-sh/uv:0.13.7 /uv /bin/uv

COPY requirements.txt /tmp/requirements.txt
RUN uv pip install --system --no-cache -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt \
    && useradd --uid 10001 --user-group --create-home --shell /usr/sbin/nologin mlflow

USER 10001
WORKDIR /home/mlflow

ENV PORT=8080
EXPOSE 8080

CMD ["sh", "-c", "exec mlflow server --host 0.0.0.0 --port \"$PORT\" --backend-store-uri \"$BACKEND_STORE_URI\" --serve-artifacts --artifacts-destination \"$ARTIFACT_ROOT\""]
