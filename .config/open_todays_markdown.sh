#!/usr/bin/env bash
VAULT_DIR="$HOME/Projects/Notes"
DAILY_DIR="$VAULT_DIR/Daily Notes"
TODAY="$(date +%Y-%m-%d)"
FILE="$DAILY_DIR/$TODAY.md"

mkdir -p "$DAILY_DIR"
exec nvim "$FILE"
