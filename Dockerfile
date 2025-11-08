FROM ghcr.io/astral-sh/uv:python3.10-trixie-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    libtesseract-dev \
    libleptonica-dev \
    poppler-utils \
    libpoppler-cpp-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set PyTorch to CPU-only to reduce image size
ENV PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cpu

# Copy dependency files only (for caching)
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --locked --no-install-project --no-editable

# Copy full project source
ADD . /app

# Install project into .venv
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable

# Pre-download sentence-transformer model to bake it into the image
# This avoids downloading 250+ MB at runtime
RUN /app/.venv/bin/python -c "from sentence_transformers import SentenceTransformer; \
    SentenceTransformer('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')"



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

# Copy pre-downloaded models from builder
COPY --from=builder --chown=app:app /tmp/sentence_transformers /tmp/sentence_transformers

ENV PORT=7860
ENV WORKERS=4
EXPOSE 7860

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH=/app/src

# Set cache directories to match pre-downloaded models
ENV HF_HOME="/tmp/huggingface"
ENV TRANSFORMERS_CACHE="/tmp/huggingface"
ENV SENTENCE_TRANSFORMERS_HOME="/tmp/sentence_transformers"

USER app

# Start the Flask app via gunicorn
# Increased timeout for document processing workloads
CMD ["sh", "-c", "gunicorn -w ${WORKERS} -b 0.0.0.0:${PORT} --timeout 120 --access-logfile - src.document_processor_flask_api:app"]