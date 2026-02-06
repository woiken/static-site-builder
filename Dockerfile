# ==============================================================================
# Stage 1: Build the Swift application
# ==============================================================================
FROM swift:6.0-noble AS builder

WORKDIR /build

# Copy manifests first for better layer caching
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Copy source and build
COPY Sources/ Sources/
COPY Tests/ Tests/
RUN swift build -c release --static-swift-stdlib

# ==============================================================================
# Stage 2: Runtime image with build tooling
# ==============================================================================
FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install common static site build tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essentials
    ca-certificates \
    curl \
    git \
    openssh-client \
    # Build tools
    make \
    gcc \
    g++ \
    # Python (for Sphinx, MkDocs, Pelican, etc.)
    python3 \
    python3-pip \
    python3-venv \
    # Ruby (for Jekyll)
    ruby-full \
    # Go (for Hugo)
    golang-go \
    # General utilities
    unzip \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install common Node.js package managers globally
RUN npm install -g yarn pnpm

# Install Hugo (extended edition, latest stable)
RUN HUGO_VERSION=$(curl -s https://api.github.com/repos/gohugoio/hugo/releases/latest | jq -r .tag_name | sed 's/^v//') \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin hugo

# Install common Python static site generators
RUN pip3 install --break-system-packages --no-cache-dir \
    mkdocs \
    mkdocs-material \
    sphinx

# Install Jekyll
RUN gem install jekyll bundler --no-document

# Create non-root user for builds
RUN useradd -m -s /bin/bash builder
RUN mkdir -p /tmp/static-builder/work && chown builder:builder /tmp/static-builder/work

# Copy the compiled binary from the builder stage
COPY --from=builder /build/.build/release/StaticBuilder /usr/local/bin/static-builder

USER builder
WORKDIR /home/builder

ENV WORK_DIR=/tmp/static-builder/work

ENTRYPOINT ["static-builder"]
