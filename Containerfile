FROM python:3.12-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=100 \
    PYTHONIOENCODING=UTF-8

# Install system dependencies with error handling
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        wget \
        git \
        pkg-config \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Verify network connectivity and PyPI access
RUN echo "Testing network connectivity..." && \
    ping -c 1 pypi.org || echo "Warning: Cannot ping pypi.org, but continuing..."

# Setup pip with alternative index URLs and retry mechanism
RUN echo "[global]" > /etc/pip.conf && \
    echo "timeout = 100" >> /etc/pip.conf && \
    echo "retries = 5" >> /etc/pip.conf && \
    echo "trusted-host = pypi.org files.pythonhosted.org pypi.python.org" >> /etc/pip.conf

# Install dependencies with fallback repositories and better error handling
RUN pip install --no-cache-dir --upgrade pip && \
    echo "Installing setuptools..." && \
    pip install --no-cache-dir setuptools && \
    echo "Installing wheel..." && \
    pip install --no-cache-dir wheel || pip install --no-cache-dir wheel --index-url https://pypi.tuna.tsinghua.edu.cn/simple

# Install FastAPI and dependencies (separated for better error diagnosis)
RUN echo "Installing FastAPI dependencies..." && \
    pip install --no-cache-dir fastapi uvicorn pydantic || \
    pip install --no-cache-dir fastapi uvicorn pydantic --index-url https://pypi.tuna.tsinghua.edu.cn/simple

# Install NumPy and scikit-learn
RUN echo "Installing NumPy and scikit-learn..." && \
    pip install --no-cache-dir numpy scikit-learn || \
    pip install --no-cache-dir numpy scikit-learn --index-url https://pypi.tuna.tsinghua.edu.cn/simple

# Install sentence-transformers
RUN echo "Installing sentence-transformers..." && \
    pip install --no-cache-dir sentence-transformers || \
    pip install --no-cache-dir sentence-transformers --index-url https://pypi.tuna.tsinghua.edu.cn/simple

# Install chromadb
RUN echo "Installing chromadb..." && \
    pip install --no-cache-dir chromadb || \
    pip install --no-cache-dir chromadb --index-url https://pypi.tuna.tsinghua.edu.cn/simple

# Install remaining dependencies
RUN echo "Installing remaining dependencies..." && \
    pip install --no-cache-dir PyPDF2 python-multipart python-dotenv || \
    pip install --no-cache-dir PyPDF2 python-multipart python-dotenv --index-url https://pypi.tuna.tsinghua.edu.cn/simple

# Create non-root user for better security
RUN useradd -m appuser && \
    mkdir -p /app/documents /app/chromadb /app/logs && \
    chown -R appuser:appuser /app

# Copy application files
COPY --chown=appuser:appuser main.py .
COPY --chown=appuser:appuser static/ ./static/

# Set environment variables
ENV DOCUMENTS_DIR=/app/documents \
    CHROMA_DB_PATH=/app/chromadb \
    PYTHONPATH=/app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Command to run the application
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
