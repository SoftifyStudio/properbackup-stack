#!/bin/bash

# ProperBackup Docker Compose Launcher
# Usage: ./start.sh [dev|prod] [up|down|build]

set -e

ENV_FILE=""
COMMAND="up"

# Parse arguments
if [ "$1" = "dev" ]; then
  ENV_FILE=".env.dev"
elif [ "$1" = "prod" ]; then
  ENV_FILE=".env.prod"
else
  echo "Usage: ./start.sh [dev|prod] [up|down|build]"
  echo "  dev   - Development environment (port 5441)"
  echo "  prod  - Production environment (port 5432)"
  echo "  up    - Start services (default)"
  echo "  down  - Stop services"
  echo "  build - Rebuild and start"
  exit 1
fi

if [ "$2" = "down" ]; then
  COMMAND="down"
elif [ "$2" = "build" ]; then
  COMMAND="up --build"
elif [ -n "$2" ] && [ "$2" != "up" ]; then
  echo "Unknown command: $2"
  echo "Available commands: up, down, build"
  exit 1
fi

# Check if env file exists
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found"
  exit 1
fi

# Run docker compose
echo "Starting ProperBackup with $ENV_FILE..."
docker compose --env-file "$ENV_FILE" $COMMAND
