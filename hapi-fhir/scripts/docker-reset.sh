#!/usr/bin/env bash
set -e

echo "Stopping and removing containers..."
docker compose down --remove-orphans

echo "Deleting Postgres volume directory..."
rm -rf ./volumes/postgres

echo "Pruning unused volumes..."
docker volume prune -f

echo "Pruning unused images..."
docker image prune -f

echo "✅ Docker environment reset complete."