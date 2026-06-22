#!/usr/bin/env bash

BASEDIR=$(dirname "$0")
PROJECT_DIR="$(realpath "${BASEDIR}/")"

set -a
source "$PROJECT_DIR/.env"
set +a

DOCKER_FILE="Dockerfile"
IMAGE_NAME="nginx-with-acme"
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
GIT_COMMIT=$(git rev-parse --short HEAD)
IMAGE_TAG="${GIT_BRANCH}-${GIT_COMMIT}"

echo "Building image: $IMAGE_NAME:$IMAGE_TAG"

# countdown timer
function build_docker() {
    IMAGE_NAME=$1
    DOCKERFILE=$2

    echo "Will build image: $IMAGE_NAME:$IMAGE_TAG"

    # rm docker containers and images if exists
    CONTAINERS=$(docker ps -a -q -f name=$IMAGE_NAME)
    if [ -n "$CONTAINERS" ]; then
        docker rm -f $CONTAINERS
    fi
    IMAGES=$(docker images -q $IMAGE_NAME)
    if [ -n "$IMAGES" ]; then
        docker rmi -f $IMAGES
    fi
    rm -f ./$IMAGE_NAME.tar.gz

    # build image
    docker build --progress=plain --platform=linux/amd64 --no-cache -t $IMAGE_NAME:$IMAGE_TAG -f ./$DOCKERFILE ./

    if [ $? -ne 0 ]; then
        echo "Failed to build image $IMAGE_NAME:$IMAGE_TAG"
        exit 1
    fi
}

build_docker $IMAGE_NAME $DOCKER_FILE

docker tag $IMAGE_NAME:$IMAGE_TAG "$DOMAIN/$IMAGE_NAME:latest"

docker save $IMAGE_NAME:$IMAGE_TAG "$DOMAIN/$IMAGE_NAME:latest" | gzip > ./$IMAGE_NAME.tar.gz

echo ''
echo "Done!"
echo "Image saved to ./$IMAGE_NAME.tar.gz"
