# Stage 1: install deps into a virtualenv
FROM python:3.13.18-slim AS build
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt

# Stage 2: small runtime image, non-root
FROM python:3.13.18-slim
COPY --from=build /venv /venv
WORKDIR /app
COPY main.py .
USER 10001
EXPOSE 8000
# 1 uvicorn worker keeps RAM low
CMD ["/venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
