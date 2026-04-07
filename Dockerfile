FROM python:3.12-slim AS base

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]

# System dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        fonts-liberation \
        fonts-noto-cjk \
        gsfonts \
        libldap2-dev \
        libpq-dev \
        libsasl2-dev \
        libssl-dev \
        libxml2-dev \
        libxslt1-dev \
        node-less \
        npm \
        postgresql-client \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install wkhtmltopdf (required for PDF report generation)
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG TARGETARCH=amd64
RUN curl -sSL -o /tmp/wkhtmltox.deb \
    "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_${TARGETARCH}.deb" && \
    apt-get update && \
    apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb && \
    rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/*

# Install rtlcss for RTL support
RUN npm install -g rtlcss

# Create odoo user
RUN useradd --create-home --shell /bin/bash odoo

# Python dependencies
COPY requirements.txt /opt/odoo/requirements.txt
RUN pip install --no-cache-dir -r /opt/odoo/requirements.txt

# Copy Odoo source
COPY . /opt/odoo
RUN pip install --no-cache-dir -e /opt/odoo

# Extra addon Python dependencies (installed after Odoo to preserve layer cache)
RUN pip install --no-cache-dir -r /opt/odoo/requirements-extra.txt

# Directories for filestore and custom addons
RUN mkdir -p /var/lib/odoo /mnt/extra-addons \
    && chown -R odoo:odoo /var/lib/odoo /mnt/extra-addons /opt/odoo

# Copy config
COPY docker/odoo.conf /etc/odoo/odoo.conf
RUN chown odoo:odoo /etc/odoo/odoo.conf

VOLUME ["/var/lib/odoo", "/mnt/extra-addons"]

EXPOSE 8069 8072

USER odoo

ENTRYPOINT ["odoo"]
CMD ["--config=/etc/odoo/odoo.conf"]
