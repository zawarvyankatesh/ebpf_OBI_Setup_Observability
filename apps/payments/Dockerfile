# Stage 1: install deps into a virtualenv
FROM python:3.13.18-slim AS build
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt

# Stage 2: small runtime image, non-root
FROM python:3.13.18-slim
COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .
USER 10001
EXPOSE 5000
# gunicorn = real WSGI server; 1 worker keeps RAM low
CMD ["/venv/bin/gunicorn", "-w", "1", "-b", "0.0.0.0:5000", "--access-logfile", "-", "app:app"]
