#!/bin/bash

set -a
source "$(dirname "$0")/.env"
set +a

rsync -av . $DOMAIN:~/gateway --exclude .git --exclude .claude --exclude sync.sh
