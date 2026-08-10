#!/usr/bin/env bash
#
# build.sh — packaging Smart Train Combinator pour Factorio 2.1.
#
# Un seul zip : info.json est la source de vérité (version, factorio_version,
# bornes base/flib) et est embarqué tel quel.
#
# Convention de version : semver continu, sans décalage. Le mod a longtemps été
# publié sur DEUX canaux, le minor encodant la version du jeu (minor pair = 2.0,
# minor impair = 2.1 dérivé avec minor+1). Depuis la 1.8.0 le support 2.0 est
# abandonné : plus qu'un canal, donc plus de delta de minor. La 1.8.0 part
# délibérément au-dessus du dernier 2.1 publié (1.7.1) pour que la mise à jour
# soit bien vue par les joueurs déjà sur le canal 2.1.
#
# Usage :
#   ./build.sh package        # génère dist/..._<version>.zip
#   ./build.sh link           # lien symbolique dev: ~/.factorio/mods/<mod> -> ce repo
#   ./build.sh unlink         # retire le lien dev
#   ./build.sh install        # package, puis copie le zip dans ~/.factorio/mods/
#   ./build.sh clean          # supprime dist/
#
# Dev recommandé : `link` une fois, puis on édite le code et on recharge Factorio.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MOD_NAME="smart-train-combinator"
DIST="$ROOT/dist"

# Fichiers/dossiers embarqués dans le zip (allowlist : on ne ship JAMAIS tmp/,
# dist/, .git, .claude, le script de build, etc.).
CONTENTS=(
  info.json
  control.lua
  data.lua
  data-final-fixes.lua
  changelog.txt
  thumbnail.png
  LICENSE
  graphics
  locale
)

# Semver du mod + version du jeu ciblée, lus dans info.json (source de vérité).
mod_version() {
  python3 -c "import json;print(json.load(open('info.json'))['version'])"
}

game_version() {
  python3 -c "import json;print(json.load(open('info.json'))['factorio_version'])"
}

package() {
  local modver; modver="$(mod_version)"
  local gamever; gamever="$(game_version)"
  local stage="$DIST/${MOD_NAME}_${modver}"

  rm -rf "$DIST"
  mkdir -p "$stage"
  for item in "${CONTENTS[@]}"; do
    [ -e "$item" ] && cp -r "$item" "$stage/"
  done

  ( cd "$DIST" && zip -rq "${MOD_NAME}_${modver}.zip" "${MOD_NAME}_${modver}" )
  rm -rf "$stage"
  echo "  → dist/${MOD_NAME}_${modver}.zip   (Factorio ${gamever})"
  echo "Packaging OK (version=${modver})."
}

install_local() {
  package
  local base; base="$(mod_version)"
  local mods="$HOME/.factorio/mods"
  local zip="$DIST/${MOD_NAME}_${base}.zip"
  if [ ! -d "$mods" ]; then
    echo "Dossier mods introuvable: $mods" >&2; exit 1
  fi
  cp "$zip" "$mods/"
  echo "Installé $zip dans $mods (Factorio prendra la version la plus haute présente)."
}

# Dev: symlink the repo into the mods folder so edits are live (no rebuild).
# Removes any packaged zip of this mod from mods/ first, so it can't shadow the
# link (a zip with a higher version would win over the unversioned link folder).
link_dev() {
  local mods="$HOME/.factorio/mods"
  [ -d "$mods" ] || { echo "Dossier mods introuvable: $mods" >&2; exit 1; }
  rm -f "$mods/${MOD_NAME}_"*.zip
  ln -sfn "$ROOT" "$mods/$MOD_NAME"
  echo "Lien dev : $mods/$MOD_NAME -> $ROOT"
  echo "(zips ${MOD_NAME}_*.zip retirés de mods/ pour ne pas masquer le lien)"
}

unlink_dev() {
  local mods="$HOME/.factorio/mods"
  if [ -L "$mods/$MOD_NAME" ]; then
    rm -f "$mods/$MOD_NAME"; echo "Lien dev retiré : $mods/$MOD_NAME"
  else
    echo "Aucun lien dev à retirer."
  fi
}

case "${1:-package}" in
  package) package ;;
  link)    link_dev ;;
  unlink)  unlink_dev ;;
  install) install_local ;;
  clean)   rm -rf "$DIST"; echo "dist/ supprimé." ;;
  *) echo "Usage: $0 {package|link|unlink|install|clean}" >&2; exit 1 ;;
esac
