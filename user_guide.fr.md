[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — Guide de l'Utilisateur

Ce document suppose que vous n'avez pas besoin de connaître la structure de `~/Library` ou le fonctionnement des caches. Le but est de récupérer de l'espace en toute sécurité sans supprimer les e-mails, mots de passe, documents, profils de navigateur, projets et paramètres d'application.

## La Règle d'Or

Ne lancez pas le nettoyage « à l'aveugle ». Faites toujours une analyse d'abord :

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Ceci ne supprime rien. Le script affichera :

- la quantité d'espace pouvant potentiellement être récupérée,
- quels éléments sont `SAFE` (sûrs),
- quels éléments nécessitent un `REVIEW` (examen),
- quels éléments sont `DANGEROUS` (dangereux) et ne seront pas supprimés automatiquement.

## Classes de Risque

| Classe | Signification | Ce que fait le script |
|-------|------------|----------------|
| `SAFE` | Données recréables : caches d'application, caches de compilation, anciens logs, tmp. | Peut être supprimé en `auto-safe` ou exécuté à partir d'un plan. Envoie en quarantaine par défaut pour les fichiers utilisateur. |
| `REVIEW` | De l'espace peut être récupéré, mais avec un coût éventuel : re-téléchargement, démarrage plus lent, perte de logs de diagnostic, état d'émulateurs. | Apparaît dans le plan. Non supprimé automatiquement sans une décision consciente. |
| `DANGEROUS` | Mails, profils de navigateur, mots de passe, documents, paramètres, données d'applications actives. | Rédige seulement un rapport ou bloque. Ne supprime jamais automatiquement. |

Si vous ne comprenez pas un élément dans le rapport, traitez-le comme `REVIEW` ou `DANGEROUS`.

## Sauvegarde et Quarantaine

Le nettoyage réel nécessite une sauvegarde Time Machine récente. Si le script ne peut pas la vérifier, le nettoyage sera bloqué. Vous pouvez forcer l'exécution via :

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

N'utilisez ceci que si vous acceptez consciemment le risque.

La quarantaine ne libère pas l'espace immédiatement. Par défaut, les fichiers de l'utilisateur vont dans :

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

Vous ne récupérerez l'espace que par `--permanent` ou une purge ultérieure :

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Restaurer :

```bash
bash cleanup_all.sh --restore latest
```

## Flux de Travail le Plus Sûr

### 1. Analyse

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Lisez le rapport dans `reports/report_*.md`.

### 2. Plan JSON

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

Le plan est enregistré dans `reports/plan_*.json`. Chaque opération possède un `id`, `risk`, `path`, `description`, et `recommendation`.

### 3. Nettoyage le Plus Sûr

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

Ceci nettoie uniquement les caches d'applications explicitement connus comme étant `SAFE`. S'il n'y a pas de sauvegarde vérifiée :

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Examen Interactif pour les Éléments plus Importants

```bash
bash cleanup_all.sh --interactive
```

Le script montrera la catégorie, la taille, les conséquences, et posera la question. La réponse par défaut est toujours `no`.

## Ce qui peut être supprimé sans conséquences majeures

Les éléments suivants sont généralement `SAFE`, mais peuvent quand même causer un premier démarrage d'application plus lent :

- Caches de Slack/Teams/Discord : l'application recréera les ressources web et les miniatures.
- `Cache` et `Code Cache` de VS Code/Cursor : l'éditeur reconstruira le cache ; les projets et les paramètres restent.
- `Cache` Spotify standard : la musique/les podcasts se retéléchargeront.
- Cache Zoom : ne supprime pas les enregistrements de `Documents/Zoom`.
- Xcode DerivedData : Xcode reconstruira les projets de zéro.
- Caches npm/pnpm/yarn/pip/Homebrew : les dépendances se retéléchargeront.
- anciens logs : vous perdez l'historique de diagnostic, mais pas les données de l'application.
- anciens fichiers `/tmp` : temporaires, macOS les nettoie généralement lui-même.

## Ce qui Nécessite une Analyse

### Général `~/Library/Caches`

Le script montre les éléments de premier niveau de `~/Library/Caches` comme `REVIEW`, car tous les caches ne sont pas peu coûteux à recréer. Certaines applications conservent de grandes données hors ligne, des cartes, des médias, des modèles IA, ou des caches de travail ici.

Ce qu'il faut vérifier :

- reconnaissez-vous l'application par le nom de son dossier,
- l'application a-t-elle des données hors ligne,
- acceptez-vous de retélécharger des gigaoctets de données,
- n'êtes-vous pas en train de travailler hors ligne actuellement.

### JetBrains

Le cache de JetBrains peut être volumineux. La suppression n'efface pas les projets, mais l'IDE reconstruira ses index. Cela peut prendre beaucoup de temps et solliciter le processeur. Ne supprimez que lorsque vous avez le temps pour une ré-indexation.

### Cache Média Adobe

Ne supprime pas les projets sources ou les médias, mais Premiere/After Effects pourraient avoir besoin de regénérer les aperçus, conformer l'audio/vidéo, et les caches. Ne supprimez que si vous avez les médias originaux et acceptez une première ouverture de projet plus lente.

### Figma

Le cache est généralement recréable, mais peut affecter la réouverture de fichiers volumineux et le travail hors ligne. Préférez un examen.

### Spotify PersistentCache

Peut signifier des données de streaming/hors ligne plus importantes. La suppression peut forcer de nouveaux téléchargements. Le `Spotify Cache` normal est plus sûr que `PersistentCache`.

### Support de Périphérique Xcode

Ce sont des symboles de débogage pour les appareils iOS/watchOS/tvOS. Xcode les téléchargera de nouveau lorsque vous connecterez un appareil avec une version OS donnée. Ne supprimez que si vous ne déboguez pas d'anciens appareils ou si vous avez le temps et internet.

### Archives Xcode

Les archives `.xcarchive` peuvent être nécessaires pour l'App Store, la symbolisation des plantages, et la recréation des builds. Le script les rapporte seulement. Supprimez manuellement depuis Xcode Organizer après vérification.

### Docker

`docker system prune -f` supprime les images, les conteneurs arrêtés, les réseaux et les caches de build. Il ne supprime pas les volumes, mais les conteneurs arrêtés peuvent contenir un état que vous n'avez pas encore déplacé vers un volume. Vérifiez :

```bash
docker ps -a
docker system df
```

### Android AVD

Les émulateurs Android peuvent contenir des états d'applications de test locales. Supprimez via Android Studio Device Manager, pas via `rm` manuel si vous n'êtes pas sûr.

### Maven `~/.m2/repository`

Peut contenir des artefacts compilés localement non disponibles sur internet. Le script traite cela comme "examen uniquement".

### Sauvegardes iOS

Ce sont des copies d'iPhone/iPad. Ne supprimez que si vous avez une sauvegarde iCloud récente ou une nouvelle sauvegarde Finder.

### Snapshots locaux de Time Machine

macOS les supprime automatiquement lorsqu'il a besoin d'espace. Le nettoyage manuel n'a de sens que si vous comprenez que vous perdez des points de restauration locaux.

## Ce que le Script NE supprime PAS Automatiquement

### Apple Mail

`~/Library/Mail` et `~/Library/Containers/com.apple.mail` peuvent contenir des messages, pièces jointes, comptes POP, index, et archives locales. Le script ne montre que les tailles et les zones les plus volumineuses.

Actions sûres :

- dans Mail.app, supprimez les messages volumineux,
- videz la Corbeille et le Courrier indésirable dans Mail.app,
- vérifiez les pièces jointes,
- exportez les boîtes aux lettres locales avant une intervention manuelle.

### Navigateurs

Les profils de Chrome/Firefox/Safari/Edge/Brave contiennent les cookies, sessions, mots de passe, l'historique, les signets et extensions. Le script ne les supprime pas.

Effacez les données de sites via l'UI :

- Safari : Paramètres -> Confidentialité -> Gérer les données de sites web.
- Chrome/Brave/Edge : `chrome://settings/clearBrowserData`.
- Firefox : Paramètres -> Vie privée et sécurité -> Cookies et données de sites.

La suppression des cookies peut vous déconnecter des sites web.

### Support d'Application et Préférences

`~/Library/Application Support` et `~/Library/Preferences` contiennent souvent des bases de données, paramètres, licences, projets locaux et configurations. Le script ne supprime pas les données d'applications actives. Les restes d'applications désinstallées sont seulement rapportés.

## Comment Lire `plan.json`

Exemple :

```json
{
  "id": "op-0007",
  "category": "app-caches",
  "risk": "SAFE",
  "action": "remove_path",
  "path": "/Users/me/Library/Caches/com.spotify.client",
  "estimated_bytes": 532000000,
  "description": "Spotify cache: streaming cache muzyki/podcastów.",
  "recommendation": "SAFE: można usunąć przez auto-safe..."
}
```

Interprétation :

- `SAFE` : peut être exécuté via `apply --from-plan`.
- `REVIEW` : nécessite une décision manuelle.
- `DANGEROUS` : ne sera pas exécuté.
- `native_command` : le script exécutera un outil comme `brew cleanup` ; généralement sans rollback de quarantaine.
- `report_only` : information seulement, aucune suppression.

## Exemples de Décisions

| Situation | Décision |
|----------|---------|
| Vous voulez récupérer rapidement de l'espace sans risque | `--auto-safe` |
| Vous avez beaucoup de cache npm/pnpm et internet | nettoyez la catégorie `dev` après examen |
| Vous avez un grand profil Chrome/Firefox | ne supprimez pas manuellement, utilisez l'UI du navigateur |
| Gros `~/Library/Mail` | nettoyez depuis Mail.app, pas via le script |
| Grosses `Archives Xcode` | vérifiez dans Xcode Organizer |
| Pas de sauvegarde Time Machine | ne faites pas un apply réel à moins d'utiliser consciemment `--allow-no-backup` |

## Commandes Utiles

```bash
# Tout analyser
bash cleanup_all.sh --dry-run --non-interactive --no-color

# Plan JSON
bash cleanup_all.sh plan --non-interactive --no-color

# Uniquement le cache développeur
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Nettoyage le plus sûr
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interactivement, avec questions complètes
bash cleanup_all.sh --interactive

# Simuler l'exécution du plan
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Restaurer depuis la quarantaine
bash cleanup_all.sh --restore latest

# Libérer l'espace de la quarantaine après vérification
bash cleanup_all.sh --purge-quarantine latest --apply
```

## Quand Annuler

Annulez et ne confirmez pas le nettoyage si :

- vous n'avez pas de sauvegarde,
- vous ne comprenez pas le chemin,
- cela concerne la messagerie, les navigateurs, mots de passe, documents ou paramètres,
- vous êtes en plein diagnostic d'un plantage et avez besoin des logs,
- l'application possède des données hors ligne que vous ne souhaitez pas retélécharger.

Le nettoyage sûr consiste à récupérer de l'espace à partir de données recréables, non pas à supprimer tout ce qui est volumineux.
