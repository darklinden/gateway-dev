#!/bin/bash

docker load < nginx-with-acme.tar.gz

docker compose -f docker-compose.yaml down --remove-orphans

docker compose -f docker-compose.yaml up -d

docker system prune -f
