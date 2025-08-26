#!/usr/bin/env bash
set -e

echo "Stopping and removing containers..."
docker compose down --remove-orphans

echo "Pruning unused volumes..."
docker volume prune -f

echo "Pruning unused images..."
docker image prune -f

echo "✅ Docker environment reset complete."