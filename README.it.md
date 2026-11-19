[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Versione 4.0.5** · Mac con Apple Silicon · macOS 11 o successivo · [Sito web](https://macos-cleanup.64bit.site/) · [Supporto](https://macos-cleanup.64bit.site/support) · [Licenza MIT](LICENSE) · [Modifiche](CHANGELOG.md)

Uno strumento locale per pulire il disco con cautela su macOS. Prima misura, poi ti mostra un piano e agisce solo su ciò che approvi. La maggior parte delle rimozioni va in una cartella di quarantena da cui puoi ripristinarla. Ha un'interfaccia da terminale e una semplice modalità a riga di comando, e non usa mai `sudo`.

## Cosa pulisce

Ogni categoria ha un livello (tier). Il livello decide come lo strumento la tratta.

**Rigenerabili (regenerable).** Il proprietario dei dati li ricostruisce. «Pulisci i sicuri» e un'esecuzione automatica toccano solo le categorie la cui modalità è `auto`. Di fabbrica è soltanto `app-caches`; ogni altra categoria rigenerabile parte in `review`. Nella scheda Categorie (`m`) puoi portare a `auto` una categoria rigenerabile che va in quarantena. `npm`, `yarn`, `pnpm` e `pip` eseguono uno strumento nativo e non possono mai essere `auto`.

| Categoria | Cos'è | Annullabile |
|-----------|-------|--------------|
| `app-caches` | Cache di app presenti in un elenco di consentite integrato | ripristinabile |
| `xcode-derived` | Xcode DerivedData | ripristinabile |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Cache di compilazione e di pacchetti, rimosse spostandole in quarantena | ripristinabile |
| `npm`, `yarn`, `pnpm`, `pip` | Cache dei gestori di pacchetti, ripulite dallo strumento stesso (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | permanente |

**Da verificare (review).** Costose da ricostruire o visibili a te. Ognuna richiede il tuo consenso durante la sessione. Non fanno mai parte di un'esecuzione automatica.

| Categoria | Cos'è | Annullabile |
|-----------|-------|--------------|
| `trash` | Il contenuto del Cestino | ripristinabile |
| `user-caches` | Altri elementi di `~/Library/Caches` | ripristinabile |
| `app-caches-review` | Cache di app note che possono contenere dati offline o essere lente da ricostruire | ripristinabile |
| `user-logs`, `diagnostic-reports` | Vecchi log e rapporti di arresto anomalo nella tua cartella home | ripristinabile |
| `device-support` | Vecchie cartelle iOS Device Support (la più recente per piattaforma viene conservata) | ripristinabile |
| `pnpm-stale` | Dati obsoleti dello store di pnpm | ripristinabile |
| `ios-backups` | Backup di dispositivi iOS, confermati uno per uno | ripristinabile |
| `installers` | Vecchi file DMG, PKG e ISO in Download | ripristinabile |
| `system-logs`, `tmp` | Log di sistema e file temporanei fuori dalla tua cartella home | permanente, e solo in modalità permanente |
| `simulators`, `sim-runtimes` | Simulatori non disponibili e runtime di simulatore inutilizzabili (`xcrun simctl`) | permanente |
| `brew`, `gem` | `brew cleanup --prune=all` e `gem cleanup`, che rimuovono vecchie versioni installate | permanente |
| `docker` | `docker system prune -f` | permanente |
| `tm-snapshots` | Snapshot locali di Time Machine (`tmutil`); il più recente viene conservato | permanente |

`sim-runtimes`, `docker` e `tm-snapshots` vengono eseguite solo quando le scegli in un'esecuzione interattiva, mai da «Pulisci i sicuri» né da un'esecuzione automatica.

**Solo report (report only).** Misurate e spiegate, mai rimosse da questo strumento: `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` e `mail-downloads`.

## Come ti protegge

- **Nulla cambia finché non sei d'accordo.** Una scansione o un'anteprima non tocca mai i tuoi file. La risposta predefinita a ogni domanda è no.
- **Quarantena, non eliminazione.** Quando lo strumento sposta i file da sé, li sposta in una cartella di quarantena sullo stesso disco e registra cosa ha spostato, così `restore` può rimetterli a posto. La quarantena non libera spazio finché non la elimini definitivamente.
- **I passaggi permanenti sono etichettati.** Le pulizie con strumenti nativi (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) non si possono annullare e quindi nemmeno ripristinare. Anche la modalità permanente elimina per sempre. L'interfaccia e le domande lo dicono ogni volta.
- **Un elenco protetto che resta protetto.** Mail, Messaggi, Calendari, Contatti, portachiavi, gestori di password, profili dei browser, Documenti, Scrivania, librerie di Foto, Musica e Film, iCloud e altre cartelle cloud, chiavi SSH e GPG, file di credenziali, `~/.config`, cartelle di codice sorgente e alberi di lavoro Git non vengono mai toccati. Lo stesso vale per il programma, le impostazioni, lo stato e la quarantena di questo strumento.
- **Ricontrollato subito prima di agire.** Subito prima di rimuovere un elemento, lo strumento verifica che esista ancora, che sia lo stesso elemento pianificato, che si trovi nelle cartelle consentite della sua categoria, che non sia in uso e che non sia troppo recente se hai impostato un'età minima.
- **Le esecuzioni automatiche sono molto limitate.** Sono disattivate per impostazione predefinita. Quando le attivi, toccano solo le categorie la cui modalità è `auto` (di fabbrica solo `app-caches`), solo tramite quarantena, e poi eliminano definitivamente le esecuzioni di quarantena oltre il periodo di conservazione. Non eseguono alcuno strumento nativo e non usano mai la modalità permanente.
- **Numeri onesti.** I risultati mostrano una stima (la somma delle dimensioni di ciò su cui l'esecuzione ha agito) e, quando è misurabile, la variazione effettiva dello spazio libero. Spesso differiscono, e l'interfaccia spiega perché. Le dimensioni sono mostrate in unità binarie: KiB, MiB, GiB.

La quarantena è un annullamento, non un backup. Prima della tua prima pulizia reale fai un backup aggiornato.

## Requisiti

- Mac con Apple Silicon e macOS 11 Big Sur o successivo. I Mac Intel non sono bloccati dal codice ma sono fuori dal supporto ufficiale.
- `bash` 3.2 o successivo, incluso in macOS.
- Python 3.9 o successivo per l'interfaccia da terminale, per i piani (`plan` e `apply`) e per `migrate`. Se manca, esegui `xcode-select --install`. Senza Python la modalità a riga di comando semplice continua a funzionare per gli altri comandi.
- Un terminale di almeno 40 colonne per 12 righe per l'interfaccia.
- Accesso alla rete solo per installare e per un aggiornamento che avvii tu stesso con `macos-cleanup update-self`. Pulire, scansionare e ripristinare non usano mai la rete.

## Installazione

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

L'installer scarica il pacchetto della release e il relativo file `SHA256SUMS`, verifica il checksum, mette il programma in `~/.local/share/macos-cleanup` e collega `~/.local/bin/macos-cleanup`. Non richiede `git`, non usa mai `sudo`, non modifica mai le tue impostazioni, il tuo stato o la tua quarantena, non installa mai l'esecuzione automatica e non avvia mai una pulizia. Per installare una release specifica: `install.sh --version 4.0.5`.

Per verificare prima tu stesso il download:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/macos-cleanup-4.0.5.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Decomprimi il pacchetto solo se il controllo stampa `OK`. I checksum proteggono da un download danneggiato o incompleto. Le release non sono firmate crittograficamente, quindi un checksum ottenuto dallo stesso posto del pacchetto non dimostra chi lo ha pubblicato. Altre opzioni e passaggi manuali: [INSTALL.md](docs/user/INSTALL.md) (in inglese).

Se dopo l'installazione `macos-cleanup` non viene trovato, apri una nuova finestra di terminale e controlla che `~/.local/bin` sia nel tuo `PATH`.

## Primo avvio

```bash
macos-cleanup
```

In un terminale questo apre l'interfaccia sulla Panoramica. Senza terminale un semplice `macos-cleanup` è una scansione di sola lettura. Premi `S` per scansionare. Una scansione non cambia nulla. Premi `P` per un'anteprima di ciò che farebbe una pulizia, poi `C` per pulire le categorie sicure, oppure scegli le categorie nella scheda Categorie e premi `X`.

`mac-cleanup` è lo stesso comando di `macos-cleanup` ed entrambi funzionano da qualsiasi cartella. Senza argomenti ognuno apre l'interfaccia; `--cli` viene eseguito in modalità terminale semplice. L'installer ti avvisa quando un altro programma nel tuo `PATH` risponde a uno dei due nomi: digitare quel nome avvierebbe allora quel programma, non macOS Cleanup.

In testo semplice, invece:

```bash
macos-cleanup scan
```

Prima di qualsiasi azione reale, esegui `macos-cleanup doctor` per vedere i tuoi percorsi, lo spazio libero, lo stato dell'Accesso completo al disco e gli snapshot locali.

## L'interfaccia da terminale

Sette schede, raggiungibili con `1` a `7`:

| # | Scheda | A cosa serve |
|---|--------|--------------|
| 1 | Panoramica | Scansione, anteprima, pulizia. Avanzamento in tempo reale per categoria e risultato dell'ultima esecuzione |
| 2 | Categorie | Ogni categoria con livello, modalità e dimensione. Qui scegli cosa pulire |
| 3 | Quarantena | Ripristinare un'esecuzione, eliminare definitivamente un'esecuzione (digiti l'ultima parte del suo id), eliminare le esecuzioni scadute |
| 4 | Cronologia | Esecuzioni passate e relativi report. Applicare un piano recente |
| 5 | Impostazioni | Lingua e aspetto, limiti di sicurezza, regole, conservazione, pianificazione, percorsi, esportazione e importazione |
| 6 | Diagnostica | Controlli di stato, Accesso completo al disco, anteprima della migrazione del layout |
| 7 | Aiuto | Tasti, livelli, percorsi, versione |

Tasti principali: le frecce spostano, `Invio` (`Enter`) apre o conferma, `Tab` cambia pannello, `Esc` torna indietro (o chiede se fermare un'attività in corso), da `1` a `7` si salta a una scheda, `?` apre l'aiuto, `L` mostra il log, `q` esce. `/` cerca e `s` ordina negli elenchi che lo offrono. La riga in basso mostra sempre i tasti che funzionano in quel momento. Dettagli completi: [USER_GUIDE.md](docs/user/USER_GUIDE.md) (in inglese).

## Uso semplice da riga di comando

`macos-cleanup` con un sottocomando non apre mai l'interfaccia. Lo stesso vale per `--cli` e per qualsiasi esecuzione senza terminale. Un semplice `macos-cleanup` senza terminale è una scansione di sola lettura.

```bash
macos-cleanup scan                        # misura, non cambia nulla
macos-cleanup plan                        # misura e scrive un file di piano
macos-cleanup clean --safe                # categorie in modo auto, dopo una domanda
macos-cleanup clean --only trash,npm      # esattamente queste categorie, con una domanda per sezione
macos-cleanup quarantine list             # elenca i punti di ripristino
macos-cleanup restore latest              # rimette a posto l'ultima esecuzione
macos-cleanup quarantine purge expired --apply   # rimuove definitivamente i punti di ripristino scaduti
macos-cleanup doctor                      # controlla questo Mac
macos-cleanup history                     # elenca le esecuzioni passate
```

`scan`, `plan`, `quarantine list`, `history` e `doctor` sono di sola lettura. `clean`, `apply`, `restore` e `quarantine purge ... --apply` cambiano le cose. `quarantine purge` senza `--apply` mostra solo un'anteprima. Un ripristino non sovrascrive mai: un elemento il cui posto originale è occupato viene saltato e resta in quarantena, e il ripristino termina allora con un avviso (stato di uscita 1), non con un errore. Vedi la tabella di tutti i comandi e le opzioni nella [guida utente](docs/user/USER_GUIDE.md) (in inglese).

## Dove si trovano i file

| Cosa | Dove | Sostituibile con |
|------|------|------------------|
| Programma | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Impostazioni e regole | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Log, report, piani, cronologia | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Quarantena (punti di ripristino) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

Le sostituzioni devono essere percorsi assoluti. La quarantena deve trovarsi sullo stesso disco della tua cartella home. L'aggiornamento sostituisce solo il programma. Impostazioni, stato e quarantena restano.

## Esecuzioni automatiche

Disattivate per impostazione predefinita, e l'installer non le attiva mai. Le abiliti in **Impostazioni**, oppure con:

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Questo installa un LaunchAgent di macOS (`com.github.kasprowiczm.macos-cleanup`). Un'esecuzione pianificata fa solo due cose: sposta in quarantena gli elementi delle categorie la cui modalità è `auto` (di fabbrica solo `app-caches`) ed elimina definitivamente le esecuzioni di quarantena oltre il periodo di conservazione. Non esegue alcuno strumento nativo, nulla del livello «da verificare» e mai la modalità permanente. Scrive una normale voce nella Cronologia.

## Aggiornare e disinstallare

Esegui di nuovo l'installer, oppure `macos-cleanup update-self`, per aggiornare. La versione precedente viene conservata accanto al programma come `.previous`. Per rimuovere lo strumento:

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

Chiede se conservare le tue impostazioni e la cronologia delle esecuzioni, e non elimina mai la quarantena a meno che tu non passi `--purge-quarantine --yes`. Vedi [UNINSTALL.md](docs/user/UNINSTALL.md) (in inglese). Arrivi dalla 3.x? Leggi [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md) (in inglese).

## Privacy

Scansione, pulizia e ripristino funzionano offline; la rete è usata solo per installare e per `update-self`. Lo strumento non invia da nessuna parte percorsi, risultati o dati d'uso e non ha telemetria. Log, report e piani restano nella cartella di stato sul tuo Mac. Usa `--redact` per sostituire la tua cartella home con `~` e omettere il nome utente e dell'host prima di condividere un report.

## Limiti e lacune note

- La quarantena non libera spazio finché non la elimini definitivamente, e gli snapshot locali possono poi trattenere blocchi eliminati. Lo spazio torna quando macOS lo recupera.
- Le dimensioni sono stime per eccesso. I cloni APFS e i blocchi condivisi non vengono rilevati.
- Senza Accesso completo al disco alcune cartelle non possono essere lette. La scansione viene allora contrassegnata come parziale e quelle dimensioni sono limiti inferiori.
- Le pulizie con strumenti nativi e la modalità permanente non si possono annullare.
- Le categorie «solo report» non vengono mai rimosse. Puliscile con i loro strumenti.
- Le release sono verificate tramite checksum, non tramite firma crittografica.
- Apple Silicon con macOS 11 o successivo è la configurazione supportata. Le altre configurazioni non sono state testate.

## Documentazione

[Guida utente](docs/user/USER_GUIDE.md) · [Installazione](docs/user/INSTALL.md) · [Disinstallazione](docs/user/UNINSTALL.md) · [Migrare dalla 3.x](docs/user/MIGRATING_FROM_V3.md) · [Modifiche](CHANGELOG.md) (tutti in inglese)

## Supporto

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## Licenza

[MIT](LICENSE)

> **Usalo a tuo rischio.** Lo strumento è costruito per chiedere prima di agire e per lasciare aperta la via del ritorno, ma nessun software è privo di errori. Fai prima un backup.
