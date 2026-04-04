#!/bin/bash
set -e

MOQUI_HOME="../.."
NAME_TAG="moqui-prod"

./docker-build.sh "$MOQUI_HOME" "moqui-temp-build" "$NAME_TAG"

docker build -t "$NAME_TAG" -f Dockerfile.prod .
docker push "$NAME_TAG"
