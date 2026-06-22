FROM nginx:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl curl socat bash procps cron ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://get.acme.sh | sh -s email=admin@example.com

COPY entrypoint.sh /entrypoint.sh
COPY nginx.conf /etc/nginx/nginx.conf.template

ENTRYPOINT ["/entrypoint.sh"]
