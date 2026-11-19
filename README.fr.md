[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Version 4.0.4** · Mac Apple Silicon · macOS 11 ou ultérieur · [Site web](https://macos-cleanup.64bit.site/) · [Assistance](https://macos-cleanup.64bit.site/support) · [Licence MIT](LICENSE) · [Modifications](CHANGELOG.md)

Un outil local pour nettoyer le disque avec soin sous macOS. Il mesure d'abord, vous montre un plan et n'agit que sur ce que vous approuvez. La plupart des suppressions vont dans un dossier de quarantaine d'où vous pouvez les restaurer. Il dispose d'une interface terminal et d'un mode ligne de commande simple, et n'utilise jamais `sudo`.

## Ce qu'il nettoie

Chaque catégorie a un niveau (tier). Le niveau détermine la façon dont l'outil la traite.

**Régénérables (regenerable).** Le propriétaire des données les reconstruit. « Nettoyer (sûr) » et une exécution automatique ne touchent que les catégories dont le mode est `auto`. En configuration d'origine, il s'agit uniquement de `app-caches` ; toute autre catégorie régénérable démarre en `review`. Dans l'onglet Catégories (`m`), vous pouvez passer en `auto` une catégorie régénérable qui va en quarantaine. `npm`, `yarn`, `pnpm` et `pip` lancent un outil natif et ne peuvent jamais être en `auto`.

| Catégorie | Ce que c'est | Annulation |
|-----------|--------------|------------|
| `app-caches` | Caches d'applications figurant sur une liste d'autorisation intégrée | restaurable |
| `xcode-derived` | Xcode DerivedData | restaurable |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Caches de compilation et de paquets, supprimés en les déplaçant en quarantaine | restaurable |
| `npm`, `yarn`, `pnpm`, `pip` | Caches de gestionnaires de paquets, nettoyés par l'outil lui-même (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | définitif |

**Examen (review).** Coûteuses à reconstruire ou visibles pour vous. Chacune demande votre accord pendant la session. Elles ne font jamais partie d'une exécution automatique.

| Catégorie | Ce que c'est | Annulation |
|-----------|--------------|------------|
| `trash` | Le contenu de la Corbeille | restaurable |
| `user-caches` | Autres éléments de `~/Library/Caches` | restaurable |
| `app-caches-review` | Caches d'applications connues pouvant contenir des données hors ligne ou être longs à reconstruire | restaurable |
| `user-logs`, `diagnostic-reports` | Anciens journaux et rapports de plantage dans votre dossier personnel | restaurable |
| `device-support` | Anciens dossiers iOS Device Support (le plus récent par plateforme est conservé) | restaurable |
| `pnpm-stale` | Données obsolètes du magasin pnpm | restaurable |
| `ios-backups` | Sauvegardes d'appareils iOS, confirmées une par une | restaurable |
| `installers` | Anciens fichiers DMG, PKG et ISO dans Téléchargements | restaurable |
| `system-logs`, `tmp` | Journaux système et fichiers temporaires hors de votre dossier personnel | définitif, et uniquement en mode définitif |
| `simulators`, `sim-runtimes` | Simulateurs indisponibles et environnements d'exécution de simulateur inutilisables (`xcrun simctl`) | définitif |
| `brew`, `gem` | `brew cleanup --prune=all` et `gem cleanup`, qui suppriment d'anciennes versions installées | définitif |
| `docker` | `docker system prune -f` | définitif |
| `tm-snapshots` | Instantanés locaux Time Machine (`tmutil`) ; le plus récent est conservé | définitif |

`sim-runtimes`, `docker` et `tm-snapshots` ne s'exécutent que lorsque vous les choisissez dans une exécution interactive, jamais depuis « Nettoyer (sûr) » ni dans une exécution automatique.

**Rapport seul (report only).** Mesurées et expliquées, jamais supprimées par cet outil : `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` et `mail-downloads`.

## Comment il vous protège

- **Rien ne change tant que vous n'êtes pas d'accord.** Une analyse ou un aperçu ne touche jamais vos fichiers. La réponse par défaut à chaque question est non.
- **Quarantaine, pas suppression.** Quand l'outil déplace lui-même des fichiers, il les déplace dans un dossier de quarantaine sur le même disque et note ce qu'il a déplacé, afin que `restore` puisse les remettre en place. La quarantaine ne libère aucun espace tant que vous ne la purgez pas.
- **Les étapes définitives sont signalées.** Les nettoyages par outil natif (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) ne peuvent pas être annulés, donc pas restaurés. Le mode définitif supprime lui aussi définitivement. L'interface et les questions le disent à chaque fois.
- **Une liste protégée qui le reste.** Mail, Messages, Calendrier, Contacts, trousseaux, gestionnaires de mots de passe, profils de navigateur, Documents, Bureau, photothèques, bibliothèques Musique et Films, iCloud et autres dossiers cloud, clés SSH et GPG, fichiers d'identifiants, `~/.config`, dossiers de code source et arbres de travail Git ne sont jamais touchés. Pas plus que le programme, les réglages, l'état et la quarantaine de cet outil.
- **Revérifié juste avant d'agir.** Juste avant de supprimer un élément, l'outil vérifie qu'il existe toujours, qu'il s'agit bien de l'élément prévu, qu'il se trouve dans les dossiers autorisés de sa catégorie, qu'il n'est pas utilisé et qu'il n'est pas trop récent si vous avez fixé un âge minimal.
- **Les exécutions automatiques sont étroitement limitées.** Elles sont désactivées par défaut. Lorsque vous les activez, elles ne touchent que les catégories dont le mode est `auto` (à l'origine seulement `app-caches`), uniquement via la quarantaine, puis purgent les exécutions de quarantaine dont la durée de conservation est dépassée. Elles n'exécutent aucun outil natif et n'utilisent jamais le mode définitif.
- **Des chiffres honnêtes.** Les résultats affichent une estimation (la somme des tailles de ce sur quoi l'exécution a agi) et, quand c'est mesurable, la variation réelle de l'espace libre. Les deux diffèrent souvent, et l'interface explique pourquoi. Les tailles sont affichées en unités binaires : KiB, MiB, GiB.

La quarantaine est une annulation, pas une sauvegarde. Faites une sauvegarde à jour avant votre premier vrai nettoyage.

## Prérequis

- Mac Apple Silicon sous macOS 11 Big Sur ou ultérieur. Les Mac Intel ne sont pas bloqués par le code mais sont hors du périmètre de l'assistance officielle.
- `bash` 3.2 ou ultérieur, fourni avec macOS.
- Python 3.9 ou ultérieur pour l'interface terminal, pour les plans (`plan` et `apply`) et pour `migrate`. S'il manque, exécutez `xcode-select --install`. Sans Python, le mode ligne de commande simple continue de fonctionner pour les autres commandes.
- Un terminal d'au moins 40 colonnes sur 12 lignes pour l'interface.
- Accès réseau uniquement pour installer et pour une mise à jour que vous lancez vous-même avec `macos-cleanup update-self`. Nettoyer, analyser et restaurer n'utilisent jamais le réseau.

## Installation

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

Le programme d'installation télécharge le paquet de la version et son fichier `SHA256SUMS`, vérifie la somme de contrôle, place le programme dans `~/.local/share/macos-cleanup` et crée le lien `~/.local/bin/macos-cleanup`. Il n'a pas besoin de `git`, n'utilise jamais `sudo`, ne modifie jamais vos réglages, votre état ni votre quarantaine, n'installe jamais l'exécution automatique et ne lance jamais de nettoyage. Pour installer une version précise : `install.sh --version 4.0.4`.

Pour vérifier d'abord le téléchargement vous-même :

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.4/macos-cleanup-4.0.4.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.4/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Ne décompressez le paquet que si la vérification affiche `OK`. Les sommes de contrôle protègent contre un téléchargement endommagé ou incomplet. Les versions ne sont pas signées cryptographiquement ; une somme de contrôle récupérée au même endroit que le paquet ne prouve donc pas qui l'a publié. Autres options et étapes manuelles : [INSTALL.md](docs/user/INSTALL.md) (en anglais).

Si `macos-cleanup` est introuvable ensuite, ouvrez une nouvelle fenêtre de terminal et vérifiez que `~/.local/bin` figure dans votre `PATH`.

## Premier lancement

```bash
macos-cleanup
```

Dans un terminal, cela ouvre l'interface sur le Tableau de bord. Sans terminal, un simple `macos-cleanup` est une analyse en lecture seule. Appuyez sur `S` pour analyser. Une analyse ne change rien. Appuyez sur `P` pour un aperçu de ce que ferait un nettoyage, puis sur `C` pour nettoyer les catégories sûres, ou choisissez des catégories dans l'onglet Catégories et appuyez sur `X`.

`mac-cleanup` est la même commande que `macos-cleanup`, et les deux fonctionnent depuis n'importe quel dossier. Sans argument, chacune ouvre l'interface ; `--cli` s'exécute en mode terminal simple. Le programme d'installation vous prévient lorsqu'un autre programme de votre `PATH` répond à l'un des deux noms : saisir ce nom lancerait alors ce programme, et non macOS Cleanup.

En texte simple, à la place :

```bash
macos-cleanup scan
```

Avant toute action réelle, exécutez `macos-cleanup doctor` pour voir vos chemins, l'espace libre, l'état de l'Accès complet au disque et les instantanés locaux.

## L'interface terminal

Sept onglets, accessibles avec `1` à `7` :

| # | Onglet | À quoi il sert |
|---|--------|----------------|
| 1 | Tableau de bord | Analyser, aperçu, nettoyer. Progression en direct par catégorie et résultat de la dernière exécution |
| 2 | Catégories | Chaque catégorie avec son niveau, son mode et sa taille. C'est ici que vous choisissez ce qu'il faut nettoyer |
| 3 | Quarantaine | Restaurer une exécution, purger une exécution (vous saisissez la fin de son identifiant), purger les exécutions expirées |
| 4 | Historique | Exécutions passées et leurs rapports. Appliquer un plan récent |
| 5 | Réglages | Langue et apparence, limites de sécurité, règles, conservation, planification, chemins, export et import |
| 6 | Diagnostic | Contrôles d'état, Accès complet au disque, aperçu de la migration de l'arborescence |
| 7 | Aide | Touches, niveaux, chemins, version |

Touches principales : les flèches déplacent, `Entrée` (`Enter`) ouvre ou confirme, `Tab` change de panneau, `Échap` (`Esc`) revient en arrière (ou demande s'il faut arrêter une tâche en cours), `1` à `7` sautent vers un onglet, `?` ouvre l'aide, `L` affiche le journal, `q` quitte. `/` recherche et `s` trie dans les listes qui le proposent. La ligne du bas affiche toujours les touches qui fonctionnent à cet instant. Détails complets : [USER_GUIDE.md](docs/user/USER_GUIDE.md) (en anglais).

## Utilisation simple en ligne de commande

`macos-cleanup` avec une sous-commande n'ouvre jamais l'interface. Il en va de même pour `--cli` et pour toute exécution sans terminal. Un simple `macos-cleanup` sans terminal est une analyse en lecture seule.

```bash
macos-cleanup scan                        # mesurer, ne rien changer
macos-cleanup plan                        # mesurer et écrire un fichier de plan
macos-cleanup clean --safe                # catégories en mode auto, après une question
macos-cleanup clean --only trash,npm      # exactement ces catégories, avec une question par section
macos-cleanup quarantine list             # lister les points de restauration
macos-cleanup restore latest              # remettre en place la dernière exécution
macos-cleanup quarantine purge expired --apply   # supprimer définitivement les points de restauration expirés
macos-cleanup doctor                      # vérifier ce Mac
macos-cleanup history                     # lister les exécutions passées
```

`scan`, `plan`, `quarantine list`, `history` et `doctor` sont en lecture seule. `clean`, `apply`, `restore` et `quarantine purge ... --apply` modifient des choses. `quarantine purge` sans `--apply` ne fait qu'un aperçu. Une restauration n'écrase jamais rien : un élément dont l'emplacement d'origine est occupé est ignoré et reste en quarantaine, et la restauration se termine alors par un avertissement (code de sortie 1), pas par un échec. Voir le tableau de toutes les commandes et options dans le [guide de l'utilisateur](docs/user/USER_GUIDE.md) (en anglais).

## Où se trouvent les fichiers

| Quoi | Où | Remplacement |
|------|----|--------------|
| Programme | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Réglages et règles | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Journaux, rapports, plans, historique | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Quarantaine (points de restauration) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

Les remplacements doivent être des chemins absolus. La quarantaine doit se trouver sur le même disque que votre dossier personnel. Une mise à jour ne remplace que le programme. Les réglages, l'état et la quarantaine restent.

## Exécutions automatiques

Désactivées par défaut, et le programme d'installation ne les active jamais. Vous les activez dans **Réglages**, ou avec :

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Cela installe un LaunchAgent macOS (`com.github.kasprowiczm.macos-cleanup`). Une exécution planifiée ne fait que deux choses : elle déplace en quarantaine des éléments des catégories dont le mode est `auto` (à l'origine seulement `app-caches`), et elle purge les exécutions de quarantaine dont la durée de conservation est dépassée. Elle n'exécute aucun outil natif, rien du niveau « examen » et jamais le mode définitif. Elle écrit une entrée normale dans l'Historique.

## Mettre à jour et désinstaller

Relancez le programme d'installation, ou `macos-cleanup update-self`, pour mettre à jour. La version précédente est conservée à côté du programme sous le nom `.previous`. Pour supprimer l'outil :

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

Il demande s'il faut conserver vos réglages et l'historique de vos exécutions, et ne supprime jamais la quarantaine sauf si vous passez `--purge-quarantine --yes`. Voir [UNINSTALL.md](docs/user/UNINSTALL.md) (en anglais). Vous venez de la version 3.x ? Lisez [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md) (en anglais).

## Confidentialité

L'analyse, le nettoyage et la restauration fonctionnent hors ligne ; le réseau n'est utilisé que pour installer et pour `update-self`. L'outil n'envoie nulle part de chemins, de résultats ni de données d'utilisation, et n'a pas de télémétrie. Les journaux, rapports et plans restent dans le dossier d'état sur votre Mac. Utilisez `--redact` pour remplacer votre dossier personnel par `~` et omettre votre nom d'utilisateur et d'hôte avant de partager un rapport.

## Limites et lacunes connues

- La quarantaine ne libère aucun espace tant que vous ne la purgez pas, et les instantanés locaux peuvent ensuite retenir des blocs supprimés. L'espace revient quand macOS le récupère.
- Les tailles sont des estimations par excès. Les clones APFS et les blocs partagés ne sont pas détectés.
- Sans l'Accès complet au disque, certains dossiers ne peuvent pas être lus. L'analyse est alors marquée partielle et ces tailles sont des bornes inférieures.
- Les nettoyages par outil natif et le mode définitif ne peuvent pas être annulés.
- Les catégories « rapport seul » ne sont jamais supprimées. Nettoyez-les avec leurs propres outils.
- Les versions sont vérifiées par somme de contrôle, pas par signature cryptographique.
- Apple Silicon avec macOS 11 ou ultérieur est la configuration prise en charge. Les autres configurations n'ont pas été testées.

## Documentation

[Guide de l'utilisateur](docs/user/USER_GUIDE.md) · [Installation](docs/user/INSTALL.md) · [Désinstallation](docs/user/UNINSTALL.md) · [Migrer depuis la 3.x](docs/user/MIGRATING_FROM_V3.md) · [Modifications](CHANGELOG.md) (tous en anglais)

## Assistance

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## Licence

[MIT](LICENSE)

> **À utiliser à vos risques et périls.** L'outil est conçu pour demander avant d'agir et pour garder ouverte la voie du retour en arrière, mais aucun logiciel n'est exempt de bogues. Faites d'abord une sauvegarde.
