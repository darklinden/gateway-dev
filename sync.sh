#!/bin/bash

set -a
source "$(dirname "$0")/.env"
set +a

rsync -av . $DOMAIN:~/gateway \
    --exclude .git \
    --exclude .claude \
    --exclude .DS_Store \
    --exclude sync.sh \
    --exclude nginx_ssl \
    --exclude cert_data \
    --exclude acme_data
