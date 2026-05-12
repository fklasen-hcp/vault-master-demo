FROM python:3.11-slim

LABEL maintainer="Vault Demo"
LABEL description="Vault Audit Log Exporter for Prometheus"

# Set working directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy exporter script
COPY vault_audit_exporter.py .

# Make script executable
RUN chmod +x vault_audit_exporter.py

# Create audit log directory
RUN mkdir -p /audit

# Set environment variables
ENV AUDIT_LOG_PATH=/audit/audit.log
ENV EXPORTER_PORT=9091
ENV LOG_LEVEL=INFO
ENV PYTHONUNBUFFERED=1

# Expose metrics port
EXPOSE 9091

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:9091/metrics')" || exit 1

# Run exporter
CMD ["python", "-u", "vault_audit_exporter.py"]

# Made with Bob
