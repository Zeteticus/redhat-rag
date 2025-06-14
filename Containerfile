FROM python:3.12-slim

# Install system dependencies (minimal compared to Alpine)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install PyTorch explicitly first (crucial for dependency resolution)
RUN pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# Install other dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir setuptools wheel && \
    pip install --no-cache-dir fastapi uvicorn[standard] pydantic && \
    pip install --no-cache-dir numpy scikit-learn && \
    pip install --no-cache-dir sentence-transformers && \
    pip install --no-cache-dir chromadb && \
    pip install --no-cache-dir PyPDF2 python-multipart python-dotenv

# Create non-root user
RUN useradd -m appuser && \
    mkdir -p /app/documents /app/chromadb /app/logs && \
    chown -R appuser:appuser /app

# Copy application files
COPY --chown=appuser:appuser main.py .
COPY --chown=appuser:appuser static/ ./static/

# Set environment variables
ENV DOCUMENTS_DIR=/app/documents \
    CHROMA_DB_PATH=/app/chromadb \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Run the application
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
