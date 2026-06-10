[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

<p align="center">
  <img src="assets/macos-cleanup-logo.png" alt="macOS Cleanup Logo" width="350" />
</p>

# macOS Cleanup — Nettoyeur de Système Professionnel

> **Outil de nettoyage professionnel pour macOS** — plus sûr que les applications commerciales, entièrement transparent, avec un contrôle total de l'utilisateur sur ce qui est supprimé.

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>

## Qu'est-ce que ce projet ?

`cleanup_all.sh` est un script bash conçu pour les utilisateurs avancés de macOS qui :

- **Analyse** le système et identifie ce qui peut être supprimé en toute sécurité
- **Vous informe** des conséquences de chaque opération avant de l'exécuter
- **Attend votre consentement** — la réponse par défaut est toujours NON
- **Déplace les données utilisateur en quarantaine** dans les modes de nettoyage, rendant l'annulation possible
- **Ne touche jamais** aux données de messagerie, mots de passe, cookies, profils de navigateur ou documents

## Prérequis

- macOS 10.15 Catalina ou plus récent (y compris Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (préinstallé sur macOS)
- Python 3.10+ pour les outils auxiliaires `dev-sync/` et l'analyse sûre de `plan.json` dans `apply --from-plan`
- Facultatif : `bc` (pour les calculs de taille), `mdfind` (Spotlight, préinstallé)

## Installation

### Test Rapide — Installateur en une ligne

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

L'installateur **clone uniquement le dépôt et affiche les prochaines étapes** — il ne supprime rien ni ne lance le nettoyage. Il s'installe dans `~/Dev_Env/macOS_cleanup` par défaut (modifiez via `MACOS_CLEANUP_DIR=...`). Vous préférez d'abord examiner le code ? Téléchargez et inspectez [`install.sh`](install.sh) avant exécution.

### Installation Manuelle

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Utilisation

### 1. Première Exécution Recommandée — Analyse (dry-run)

```bash
bash cleanup_all.sh
```

Le script va analyser votre système, vous montrer ce qui peut être nettoyé, et demander si vous souhaitez continuer. **Rien n'est supprimé sans votre consentement.**

### 2. Nettoyage Interactif Complet

```bash
bash cleanup_all.sh --interactive
```

Passe en revue chaque catégorie, explique ce dont il s'agit, les conséquences de la suppression, et demande votre permission. Le nettoyage réel par défaut fonctionne en mode `--quarantine` : les chemins d'accès de l'utilisateur sont déplacés vers `~/Library/Application Support/macOS_cleanup/quarantine` au lieu d'être immédiatement supprimés.

Si vous souhaitez libérer de l'espace de manière permanente immédiatement après l'analyse, lancez le mode permanent :

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Nettoyage Automatique des Éléments Sûrs

```bash
bash cleanup_all.sh --auto-safe
```

Par défaut, ceci ne met en quarantaine que les caches d'applications explicitement connus comme étant à faible risque. Les éléments de niveau supérieur dans `~/Library/Caches` sont signalés à la décision de l'utilisateur car ils pourraient inclure de gros caches hors ligne que les applications devraient retélécharger. Les fichiers temporaires et les chemins en dehors de `$HOME` nécessitent le mode `--permanent` car il n'existe pas de rollback par quarantaine logique pour eux :

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Tout le reste est soumis à votre décision.

### 4. Catégorie Spécifique

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analyser / planifier / appliquer

```bash
# Alias lisible pour les workflows d'agents/opérateurs
bash cleanup_all.sh analyze

# Analyse + plan structurel JSON
bash cleanup_all.sh plan

# Exécuter le plan : uniquement SAFE par défaut
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Simuler l'exécution du plan
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` contient des opérations avec `id`, chemin ou commande, catégorie, classe `SAFE`/`REVIEW`/`DANGEROUS`, taille estimée, description des conséquences et recommandation. `apply --from-plan` n'exécute jamais `DANGEROUS` ; `REVIEW` est ignoré à moins d'ajouter `--include-review` et de passer par la confirmation interactive.

### 6. Mode Non interactif (CI/Automatisation)

```bash
# Analyse sans invites
bash cleanup_all.sh --dry-run --non-interactive

# Auto-safe sans confirmation manuelle (uniquement éléments explicitement sûrs)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Récupération réelle d'espace pour l'automatisation : uniquement après un --permanent conscient
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Lancer une catégorie spécifique sans invites
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` exécute le script sans lire l'entrée depuis TTY.
Par sécurité, chaque question est traitée comme `non` par défaut.
`--yes` confirme uniquement les opérations à faible risque ; les catégories moyennes/hautes nécessitent le mode interactif.

### 7. Avec Exclusion de Chemin

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Quarantaine, Restauration et Purge

```bash
# Lister les exécutions en quarantaine sauvegardées
bash cleanup_all.sh --list-quarantine

# Restaurer la dernière exécution ou un manifeste spécifique
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Prévisualiser la suppression permanente de la quarantaine
bash cleanup_all.sh --purge-quarantine latest

# Libérer réellement l'espace pris par la quarantaine
bash cleanup_all.sh --purge-quarantine latest --apply

# Purger les exécutions plus anciennes que la période de rétention
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

La quarantaine fournit un rollback mais ne libère pas d'espace disque par elle-même. Vous ne récupérez de l'espace qu'après `--permanent` ou un `--purge-quarantine ... --apply` ultérieur.

### 9. Sortie JSON — Résultats Lisibles par Machine (`--json`)

```bash
# Sortie analytique (dry-run) au format JSON sur stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Combiner avec un tube (la sortie humaine va dans stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# Sauvegarder JSON dans un fichier et ignorer le rapport Markdown
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

L'indicateur `--json` redirige toute la sortie lisible (bannières, sections, résumés) vers **stderr** et émet un seul objet JSON vers **stdout** à la fin de l'exécution. L'objet contient :

| Champ | Description |
|-------|-------------|
| `mode` | Mode d'exécution (`dry-run`, `plan`, `apply-plan`, etc.) |
| `dry_run` | `true` / `false` |
| `categories` | Tableau des catégories actives |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `quarantined_bytes`, `skipped_items`, `user_decisions_needed` |
| `plan` | Compteurs pour opérations `SAFE`/`REVIEW`/`DANGEROUS` et octets |
| `artifacts` | Chemins d'accès vers `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Nombre d'éléments ignorés |
| `user_decisions` | Liste des descriptions d'éléments nécessitant une décision |

L'indicateur fonctionne avec tous les modes (`dry-run`, `plan`, `apply`, `--auto-safe`, etc.) et est sûr pour `--non-interactive` et CI. Il ne modifie aucun comportement s'il n'est pas fourni.

## Catégories Disponibles

| Catégorie | Contenus |
|-----------|----------|
| `trash` | Contenu de ~/.Trash |
| `system` | Caches système, vieux fichiers /tmp et /private/tmp |
| `user-caches` | ~/Library/Caches (caches d'applications utilisateur) |
| `logs` | Anciens journaux d'application et système |
| `app-leftovers` | Rapport heuristique des restes ; aucune suppression automatique par défaut |
| `dev` | Xcode DerivedData, simulateurs, caches npm/pip/brew/docker |
| `time-machine` | Instantanés TM locaux + sauvegardes iOS |
| `large-files` | Anciens fichiers DMG/PKG/ISO dans ~/Downloads |

## Modèle de Sécurité

### Philosophie : Consentement Éclairé

Le script fonctionne sur un modèle de **consentement éclairé** :

```
Analyser → Montrer les résultats → Expliquer les conséquences → Avertissements → Attendre le consentement → Agir
```

Le langage cible UX/DX décrit ce flux comme **analyser → planifier → appliquer** :

- `analyze` — dry-run sans mutation, ex., `bash cleanup_all.sh --dry-run`
- `plan` — rapport Markdown, journal JSONL et liste d'éléments nécessitant une décision
- `apply` — action réelle après consentement : `apply --from-plan`, `--interactive`, `--auto-safe`, ou `--purge-quarantine ... --apply`

Modèle détaillé pour les opérateurs et les agents : `docs/ux_dx_safety_model.md`.

### Ce qui n'est JAMAIS Touché

- `~/Library/Mail` — Données Apple Mail et tous clients de messagerie
- `~/Library/Containers/com.apple.mail` et les espaces locaux Outlook/Spark/Thunderbird
- `~/Library/Keychains` — Trousseaux macOS
- Profils de navigateurs (Chrome, Firefox, Edge, Safari) — cookies, mots de passe, signets
- Gestionnaires de mots de passe (1Password, Bitwarden, LastPass)
- `~/Documents`, `~/Desktop`
- Bibliothèque Photos, Bibliothèque Musique
- Profils de provisionnement et certificats de développeur
- Données de conteneurs sandbox d'applications système
- Clés SSH/GPG et magasins d'identifiants

### Niveaux de Sécurité des Règles

- `SAFE` — artefacts reproductibles, par ex., caches d'applications précisément connus ; peut entrer dans `--auto-safe`, passe toujours par des garde-fous
- `REVIEW` — nécessite un plan et une décision de l'utilisateur, par ex., caches généraux, logs, artefacts de build, sauvegardes iOS
- `DANGEROUS` — données utilisateur, identité, profils, messagerie, mots de passe ; non supprimés automatiquement

L'actuel `cleanup_rules.yaml` conserve les valeurs techniques `safe`, `ask`, `never`. Le mappage UX/DX correspond à `SAFE`, `REVIEW`, `DANGEROUS`.

### Journalisation et Rollback (Annulation)

Chaque rapport sauvegarde un résumé machine du plan dans `reports/journal_*.jsonl` (`report_generated`, `category_total`). Les opérations `safe_remove()` réelles ajoutent des événements d'exécution, ex., `quarantined`, `deleted`, `skipped_non_user_scope`. Les commandes natives contrôlées, telles que `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, et `tmutil deletelocalsnapshots` ajoutent des événements `native_command` car elles n'ont pas l'annulation de quarantaine. La quarantaine génère également `reports/restore_*.tsv`, qui est utilisé par `--restore`. Le processus de restauration refuse de récupérer en dehors du répertoire utilisateur, vers des chemins protégés, à travers des répertoires liés par symlink ou à partir de fichiers extérieurs au répertoire de quarantaine.

La quarantaine est une annulation, pas une sauvegarde. Avant le premier nettoyage réel, l'utilisateur devrait quand même avoir une sauvegarde système récente. La messagerie et les profils de navigateurs sont gérés uniquement à titre de lignes directrices : des caches peuvent être signalés, mais les données de comptes, sessions, cookies, signets et bases de messages locales sont tenus à l'écart du nettoyage automatique.

## Structure du Projet

```
macOS_cleanup/
├── cleanup_all.sh          # Script principal — point d'entrée
├── cleanup_rules.yaml      # Base de connaissances : règles par application
├── config/
│   └── defaults.sh         # Configuration par défaut, seuils d'âge, chemins protégés
├── lib/
│   ├── common.sh           # Logging, formatage, safe_remove(), protection des chemins
│   ├── policy.sh           # Analyseur de politique YAML et mappage SAFE/REVIEW/DANGEROUS
│   ├── analyzer.sh         # Analyse du système (toutes les fonctions analyze_*)
│   ├── cleaner.sh          # Moteur de nettoyage (toutes les fonctions clean_*)
│   ├── planner.sh          # plan.json et apply --from-plan
│   ├── interactive.sh      # Invites utilisateur et confirmations
│   └── reporter.sh         # Générateur de rapports Markdown
├── docs/
│   ├── rules_design.md     # Documentation de la structure des règles
│   └── ux_dx_safety_model.md # Modèle SAFE/REVIEW/DANGEROUS et analyze/plan/apply
├── tests/                  # Scénarios de test
└── AGENTS.md               # Le rôle des agents IA dans le projet
```

## Rapports et Journaux

Après chaque exécution, le script génère :

- **Log** : `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — journal complet des opérations
- **Rapport** : `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Résumé Markdown
- **Plan** : `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — plan structurel `SAFE`/`REVIEW`/`DANGEROUS`
- **Journal** : `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — plan machine et journal d'audit
- **Manifeste de restauration** : `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — chemins nécessaires pour le rollback de quarantaine

```bash
# Ouvrir le dernier rapport
open reports/$(ls -t reports/ | head -1)
```

## Extension et Configuration

### Ajout d'une Nouvelle Application à la Base de Règles

Modifiez `cleanup_rules.yaml` et ajoutez une entrée selon ce schéma :

```yaml
- name: "Nom App"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Description de ce que c'est et si c'est sûr"
```

### Changement des Seuils d'Âge

Modifiez `config/defaults.sh` :

```bash
LOG_MAX_AGE_DAYS=30       # Logs de plus de N jours
TMP_MAX_AGE_HOURS=24      # Fichiers tmp de plus de N heures
DMG_MAX_AGE_DAYS=30       # DMG/PKG dans ~/Downloads
```

## Avertissement

> **Utilisez ce script à vos propres risques.** Le script est conçu avec la sécurité à l'esprit et demande toujours avant de supprimer, mais aucun logiciel n'est exempt de bugs. Assurez-vous d'avoir une sauvegarde récente avant d'exécuter dans un mode autre que dry-run pour la première fois.

---

Projet : `macOS_cleanup` | Version : 2.1.0 | Licence : MIT
