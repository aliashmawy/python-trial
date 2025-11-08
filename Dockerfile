FROM ghcr.io/astral-sh/uv:python3.10-trixie-slim AS builder

# Build arg to control model pre-download (set to 'false' in CI to save space)
ARG PREDOWNLOAD_MODEL=true

WORKDIR /app

RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    libtesseract-dev \
    libleptonica-dev \
    poppler-utils \
    libpoppler-cpp-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency files only (for caching)
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --locked --no-install-project --no-editable

# CRITICAL: Uninstall GPU PyTorch and install CPU-only version
# This saves ~6GB by removing nvidia, triton, and CUDA libraries
RUN /app/.venv/bin/pip uninstall -y torch torchvision torchaudio && \
    /app/.venv/bin/pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cpu

# Copy full project source
ADD . /app

# Install project into .venv
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable

# Verify PyTorch is CPU-only and show size
RUN /app/.venv/bin/python -c "import torch; assert not torch.cuda.is_available(), 'CUDA should not be available!'; print(f'✓ PyTorch CPU-only: {torch.__version__}')" && \
    echo "=== Virtual Environment Size ===" && \
    du -sh /app/.venv && \
    echo "=== Largest Packages ===" && \
    du -sh /app/.venv/lib/python3.10/site-packages/* | sort -rh | head -10

# Set cache directories for model downloads in builder
ENV HF_HOME=/app/.cache/huggingface
ENV TRANSFORMERS_CACHE=/app/.cache/huggingface
ENV SENTENCE_TRANSFORMERS_HOME=/app/.cache/sentence_transformers

# Pre-download sentence-transformer model to bake it into the image
# This avoids downloading 250+ MB at runtime
# Skip in CI by passing --build-arg PREDOWNLOAD_MODEL=false
RUN if [ "$PREDOWNLOAD_MODEL" = "true" ]; then \
        /app/.venv/bin/python -c "from sentence_transformers import SentenceTransformer; \
        SentenceTransformer('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')"; \
    fi

# Clean up unnecessary files to reduce layer size
RUN find /app/.venv -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /app/.venv -type f -name "*.pyc" -delete && \
    find /app/.venv -type f -name "*.pyo" -delete && \
    find /app/.venv -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true && \
    find /app/.venv -type d -name "test" -exec rm -rf {} + 2>/dev/null || true && \
    rm -rf /app/.venv/lib/python3.10/site-packages/*/tests && \
    rm -rf /app/.venv/lib/python3.10/site-packages/torch/test && \
    rm -rf /app/.venv/lib/python3.10/site-packages/*/benchmarks 2>/dev/null || true



FROM python:3.10-slim

WORKDIR /app

# Install only runtime dependencies (removed -dev packages)
RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

RUN addgroup --system app && adduser --system --ingroup app app

# Copy app and .venv from builder
COPY --from=builder --chown=app:app /app /app

ENV PORT=7860
ENV WORKERS=4
EXPOSE 7860

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH=/app/src

# Set cache directories to use pre-downloaded models from /app/.cache
ENV HF_HOME=/app/.cache/huggingface
ENV TRANSFORMERS_CACHE=/app/.cache/huggingface
ENV SENTENCE_TRANSFORMERS_HOME=/app/.cache/sentence_transformers

USER app

# Start the Flask app via gunicorn
# Increased timeout for document processing workloads
CMD ["sh", "-c", "gunicorn -w ${WORKERS} -b 0.0.0.0:${PORT} --timeout 120 --access-logfile - src.document_processor_flask_api:app"]