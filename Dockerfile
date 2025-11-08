FROM ghcr.io/astral-sh/uv:python3.10-alpine AS builder


WORKDIR /app


RUN apk add --no-cache \
    tesseract-ocr \
    tesseract-ocr-lang-eng \
    poppler-utils \
    leptonica \
    gcc \
    g++ \
    make \
    musl-dev \
    libstdc++

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



FROM python:3.10-alpine


WORKDIR /app


RUN apk add --no-cache \
    tesseract-ocr \
    tesseract-ocr-lang-eng \
    poppler-utils \
    leptonica \
    libstdc++


RUN addgroup -S app && adduser -S app -G app

# Copy app and .venv from builder
COPY --from=builder --chown=app:app /app /app


ENV PORT=7860
EXPOSE 7860

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH=/app/src


USER app

# Start the Flask app via gunicorn
# (4 workers, listening on 0.0.0.0:7860)
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:7860", "src.document_processor_flask_api:app"]
