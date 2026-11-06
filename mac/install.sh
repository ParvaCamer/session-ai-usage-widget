#!/bin/bash
# Installe Claude Usage sur macOS 13 ou plus : compile depuis les sources, puis copie dans Applications.
set -euo pipefail

REPO="ParvaCamer/session-ai-usage-widget"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Il faut d'abord les outils de ligne de commande Apple."
  echo "Valide la fenêtre qui s'ouvre, puis relance cette commande une fois l'installation terminée."
  xcode-select --install
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Téléchargement des sources..."
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$WORK" --strip-components=1

echo "Compilation..."
bash "$WORK/mac/build.sh"

pkill -x ClaudeUsage 2>/dev/null || true
rm -rf "/Applications/Claude Usage.app"
cp -R "$WORK/mac/Claude Usage.app" /Applications/

open "/Applications/Claude Usage.app"
echo "Installé. Clique sur le widget pour te connecter à claude.ai."
