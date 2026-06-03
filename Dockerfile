# ============================================================
# Stage 1: Builder — install build tools, compile everything
# ============================================================
ARG BASE_IMAGE=nousresearch/hermes-agent:v2026.5.29.2
FROM ${BASE_IMAGE} AS builder

ARG NODE_VERSION=24.15.0
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl make g++ \
    && rm -rf /var/lib/apt/lists/*

# Install mcp2cli into the venv (pip bootstrap → install → cleanup caches)
RUN curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
    && /opt/hermes/.venv/bin/python3 /tmp/get-pip.py --no-cache-dir \
    && rm /tmp/get-pip.py \
    && /opt/hermes/.venv/bin/pip3 install --no-cache-dir mcp2cli \
    && rm -rf /root/.cache/pip /tmp/get-pip.py /root/.local

# Override Node.js version if needed
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then NODE_ARCH="x64"; else NODE_ARCH="$ARCH"; fi \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
       -o /tmp/node.tar.gz \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
       /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.gz

WORKDIR /app

# Install dependencies
COPY package*.json ./
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN npm ci --ignore-scripts && npm rebuild node-pty

# Build the application
COPY . .
RUN npm run build --registry=https://registry.npmmirror.com/

# Remove dev dependencies
RUN npm prune --omit=dev \
    && rm -rf /root/.npm /root/.cache/node-gyp /usr/local/include

# ============================================================
# Stage 2: Runtime — minimal image with only production files
# ============================================================
FROM ${BASE_IMAGE} AS runtime

ARG NODE_VERSION=24.15.0
USER root

# Only install runtime essentials (no make, g++)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Match builder's Node.js version
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then NODE_ARCH="x64"; else NODE_ARCH="$ARCH"; fi \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
       -o /tmp/node.tar.gz \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
       /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.gz \
    && rm -rf /usr/local/include

WORKDIR /app

# Copy production node_modules and built application from builder
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./package.json
# Copy updated venv (with mcp2cli) from builder
COPY --from=builder /opt/hermes/.venv /opt/hermes/.venv
# Copy mcp2cli sync script (optional convenience)
COPY scripts/mcp-sync.sh ./scripts/mcp-sync.sh

ENV NODE_ENV=production
ENV HOME=/home/agent
ENV HERMES_HOME=/home/agent/.hermes
ENV HERMES_WEB_UI_MANAGED_GATEWAY=1
ENV PATH=/opt/hermes/.venv/bin:$PATH

EXPOSE 6060

ENTRYPOINT ["node", "dist/server/index.js"]
CMD []
