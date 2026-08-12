# Smart Train Combinator

Mod Factorio (Lua, **2.1 uniquement** depuis la 1.8.0). Un combinateur de gare qui
valide le tampon **dédié de chaque wagon** individuellement, au lieu de mettre tout
le stockage de la gare dans le même pot.

## Deux modules, trois modes

- **MAIN** (`smart-train-combinator`) — une ressource suivie, validation par wagon.
- **MULTI** (`stc-multi`) — jusqu'à 10 ressources, renomme la gare pour en réclamer
  une seule à la fois. Depuis la 1.9.0 il réclame **le tampon le plus vide**, pas le
  premier arrivé (plus de FIFO), et gèle son choix tant qu'un train est en route.
- **Sondes** : `stc2-buffer-probe` (générique, tampon partagé) et `stc-typed-probe`
  (fixée à une ressource, tampon indépendant). Une sonde par wagon. Les deux types
  ne se mélangent pas sur un même module.

## ⚠️ Limite Lua des 200 locales — À LIRE AVANT D'AJOUTER DU CODE

`control.lua` est à **198/200** variables locales top-level (98 fonctions + 100
constantes, ~3400 lignes).

`MAXVARS = 200` est une limite du **compilateur Lua**, par fonction — et le corps
d'un fichier est lui-même une fonction. Comme tout est déclaré au niveau du
fichier, rien ne libère jamais son slot. Dépasser = **erreur de compilation**, le
mod ne charge plus du tout :

```
too many local variables (limit is 200) in main function
```

**N'ajoute jamais un `local` au top-level de `control.lua`.** Regroupe dans une
table existante :

- `BUF` (~l.427) — helpers de tampon (`BUF.of_probe`, `BUF.share`, `BUF.units`)
- `M` (~l.106) — noms d'éléments GUI du moniteur et de l'historique

Une table ne coûte **qu'une** locale quel que soit le nombre de champs. À terme, la
vraie solution est de découper le fichier avec `require` : chaque fichier retrouve
son propre budget de 200.

## Vérifier avant de livrer

**La compilation Lua ne suffit pas.** Deux familles de bugs passent au travers :

1. **Les `style_mods` GUI** — `vertical_spacing`/`horizontal_spacing` ne vont que
   sur un `flow` ou une `table`, jamais sur un `frame` (crash flib au chargement).
2. **Les booléens** — `nil and x` retourne `nil` en Lua, pas `false`, et une
   propriété GUI comme `visible` exige un booléen (`bool expected, got nil`).
   Utilise `not not (...)` quand la source peut être nil (préférence joueur non
   initialisée, champ de table absent).

Il faut donc un **chargement en jeu** : `./build.sh link` puis recharger la partie.
Garder la console Factorio ouverte, les crashs runtime n'y apparaissent qu'à
l'exécution.

Pour un contrôle syntaxique rapide sans binaire `lua` sur la machine, on charge
`liblua5.4.so.0` via ctypes Python et on appelle `luaL_loadstring`.

## Styles GUI : data stage obligatoire

Les couleurs de lignes et le cadre d'une `table` **ne sont pas exposés sur
`LuaStyle`** au runtime (seuls `cell_padding` et `column_alignments` le sont). Tout
style de ce genre va dans `prototypes/styles.lua`, requis depuis `data.lua`.

Le moniteur utilise `stc2_grid_table` : `parent = "bordered_table"` +
`odd_row_graphical_set`, le motif des tables du gestionnaire de mods vanilla.

**`build.sh` fonctionne en allowlist** (`CONTENTS`) : tout nouveau dossier doit y
être ajouté, sinon le zip publié plante sur un `require` absent alors que le dev en
symlink fonctionne.

## Release

À chaque fix/feature : bumper `info.json`, ajouter une entrée en tête de
`changelog.txt`, puis `./build.sh package`.

- **Un seul zip** depuis la 1.8.0 (canal 2.1 unique ; le double canal 2.0/2.1 est
  abandonné, donc plus de décalage de MINOR).
- Le changelog est en **anglais**, format Factorio strict : séparateur de 99 tirets,
  `Version:` / `Date:`, sections `Features:` / `Changes:` / `Bugfixes:`, items en
  `    - ` et continuations en 6 espaces.
- Rester **concis** : décrire ce que le joueur constate, pas le cheminement interne.
  Pas de bug introduit puis corrigé dans la même session non publiée.
- Cibles : `package`, `link`, `unlink`, `install`, `clean`.

## Git

Repo perso GitHub `kardagan`, commits directs sur `main` (branches de feature
réservées aux gros chantiers). Identité locale déjà configurée en
`kardagan / 4290404+kardagan@users.noreply.github.com` — ne pas toucher à
l'identité globale, qui est celle du travail.

Jamais de trailer `Co-Authored-By`.
