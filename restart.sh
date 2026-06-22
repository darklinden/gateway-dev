#!/bin/bash

docker load < nginx-with-acme.tar.gz

docker network inspect gateway-shared >/dev/null 2>&1 || docker network create gateway-shared

docker compose -f docker-compose.yaml down --remove-orphans

docker compose -f docker-compose.yaml up -d

docker system prune -f
