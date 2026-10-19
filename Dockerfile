FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=UTC

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home planif

# FOU-17 : Gemini CLI, pour qui branche son compte Google. Il lui faut Node.js,
# soit environ 150 Mo de plus : l'image ne l'a qu'avec GEMINI_CLI=1 dans .env.
# Claude Code, lui, vient avec le SDK Python et n'a besoin de rien.
ARG GEMINI_CLI=0
ARG NODE_VERSION=22.12.0
ARG GEMINI_CLI_VERSION=0.64.0
RUN if [ "$GEMINI_CLI" = "1" ]; then \
      arch="$(dpkg --print-architecture | sed 's/amd64/x64/')" \
   && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE \
   && npm install -g "@google/gemini-cli@${GEMINI_CLI_VERSION}" \
   && npm cache clean --force; \
    fi

COPY pyproject.toml ./
COPY api ./api
# Les outils de diagnostic vivent dans l'image : quand un flux se tait, c'est
# depuis le serveur qu'il faut l'interroger, avec ses identifiants.
COPY outils ./outils
# COA-8 : le dossier du coach vit dans le dépôt, et l'API le lit à chaque appel.
COPY coach ./coach
RUN pip install --no-cache-dir . \
 && chown -R planif:planif /app

USER planif
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:8000/sante || exit 1

CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
