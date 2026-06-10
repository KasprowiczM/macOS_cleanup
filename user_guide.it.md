[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — Guida Utente

Questo documento presuppone che tu non debba conoscere la struttura di `~/Library` o il funzionamento delle cache. L'obiettivo è recuperare spazio in modo sicuro senza eliminare e-mail, password, documenti, profili del browser, progetti e impostazioni delle applicazioni.

## La Regola d'Oro

Non eseguire la pulizia "alla cieca". Fai sempre prima un'analisi:

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Questo non elimina nulla. Lo script mostrerà:

- quanto spazio può essere potenzialmente recuperato,
- quali elementi sono `SAFE` (sicuri),
- quali elementi richiedono `REVIEW` (revisione),
- quali elementi sono `DANGEROUS` (pericolosi) e non verranno eliminati automaticamente.

## Classi di Rischio

| Classe | Significato | Cosa fa lo script |
|-------|------------|----------------|
| `SAFE` | Dati ricreabili: cache di app, cache di build, vecchi log, tmp. | Può eliminarli in `auto-safe` o eseguirli da un piano. Per impostazione predefinita li mette in quarantena per i file utente. |
| `REVIEW` | Lo spazio può essere recuperato, ma potrebbe esserci un costo: nuovo download, avvio più lento, perdita di log diagnostici, stato dell'emulatore. | Viene mostrato nel piano. Non viene eliminato automaticamente senza una decisione consapevole. |
| `DANGEROUS` | Posta, profili del browser, password, documenti, impostazioni, dati di applicazioni attive. | Solo report o blocco. Non elimina mai automaticamente. |

Se non capisci un elemento nel report, trattalo come `REVIEW` o `DANGEROUS`.

## Backup e Quarantena

La pulizia reale richiede un backup Time Machine recente. Se lo script non riesce a verificarlo, la pulizia verrà bloccata. Puoi forzare l'esecuzione tramite:

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

Usalo solo se accetti consapevolmente il rischio.

La quarantena non libera spazio immediatamente. Per impostazione predefinita, i file utente finiscono in:

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

Recupererai spazio solo tramite `--permanent` o un'epurazione successiva:

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Ripristino:

```bash
bash cleanup_all.sh --restore latest
```

## Flusso di Lavoro Più Sicuro

### 1. Analisi

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Leggi il report in `reports/report_*.md`.

### 2. Piano JSON

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

Il piano viene salvato in `reports/plan_*.json`. Ogni operazione ha un `id`, `risk`, `path`, `description` e `recommendation`.

### 3. Pulizia Più Sicura

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

Questo pulisce solo le cache delle app esplicitamente conosciute come `SAFE`. Se non c'è un backup verificato:

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Revisione Interattiva per Elementi Più Grandi

```bash
bash cleanup_all.sh --interactive
```

Lo script mostrerà la categoria, le dimensioni, le conseguenze e farà una domanda. La risposta predefinita è sempre `no`.

## Cosa può essere eliminato senza grosse conseguenze

I seguenti elementi sono solitamente `SAFE`, ma potrebbero comunque causare un primo avvio più lento dell'app:

- Cache di Slack/Teams/Discord: l'app ricreerà le risorse web e le miniature.
- `Cache` e `Code Cache` di VS Code/Cursor: l'editor ricostruirà la cache; i progetti e le impostazioni rimangono.
- `Cache` standard di Spotify: musica/podcast verranno scaricati di nuovo.
- Cache di Zoom: non elimina le registrazioni da `Documents/Zoom`.
- Xcode DerivedData: Xcode ricostruirà i progetti da zero.
- Cache npm/pnpm/yarn/pip/Homebrew: le dipendenze verranno scaricate di nuovo.
- vecchi log: perdi la cronologia diagnostica, ma non i dati dell'app.
- vecchi file `/tmp`: temporanei, di solito macOS li pulisce da solo.

## Cosa Richiede Analisi

### `~/Library/Caches` Generale

Lo script mostra gli elementi di primo livello di `~/Library/Caches` come `REVIEW`, perché non tutte le cache sono economiche da ricreare. Alcune app conservano enormi dati offline, mappe, media, modelli IA o cache di lavoro lì.

Cosa controllare:

- riconosci l'app dal nome della cartella?
- l'app ha dati offline?
- accetti di riscaricare gigabyte di dati?
- non stai lavorando offline in questo momento?

### JetBrains

La cache di JetBrains può essere grande. L'eliminazione non cancella i progetti, ma l'IDE ricostruirà i suoi indici. Questo può richiedere molto tempo e affaticare la CPU. Elimina solo quando hai tempo per la reindicizzazione.

### Cache Media di Adobe

Non elimina i progetti sorgente o i media, ma Premiere/After Effects potrebbero dover rigenerare anteprime, adeguare audio/video e cache. Elimina solo se hai i media originali e accetti una prima apertura del progetto più lenta.

### Figma

La cache è solitamente ricreabile, ma può influire sulla riapertura di file di grandi dimensioni e sul lavoro offline. Preferisci la revisione.

### Spotify PersistentCache

Può significare dati di streaming/offline più grandi. L'eliminazione potrebbe forzare un nuovo download. La normale `Spotify Cache` è più sicura della `PersistentCache`.

### Supporto Dispositivi Xcode

Sono simboli di debug per dispositivi iOS/watchOS/tvOS. Xcode li scaricherà di nuovo quando colleghi un dispositivo con una determinata versione del sistema operativo. Elimina solo se non esegui il debug di vecchi dispositivi o se hai tempo e internet.

### Archivi Xcode

Gli archivi `.xcarchive` potrebbero essere necessari per l'App Store, la simbolizzazione degli arresti anomali e la ricreazione delle build. Lo script li riporta e basta. Eliminali manualmente dall'Organizer di Xcode dopo un controllo.

### Docker

`docker system prune -f` elimina immagini, contenitori fermati, reti e cache di build. Non elimina i volumi, ma i contenitori fermati potrebbero contenere stati che non hai ancora spostato in un volume. Controlla:

```bash
docker ps -a
docker system df
```

### Android AVD

Gli emulatori Android possono contenere stati locali di app di test. Elimina tramite l'Android Studio Device Manager, non tramite un `rm` manuale se non sei sicuro.

### Maven `~/.m2/repository`

Potrebbe contenere artefatti compilati localmente non disponibili su internet. Lo script lo tratta come "solo revisione".

### Backup iOS

Sono copie di iPhone/iPad. Elimina solo se hai un backup iCloud recente o un nuovo backup nel Finder.

### Local Snapshot di Time Machine

macOS li elimina automaticamente quando ha bisogno di spazio. La pulizia manuale ha senso solo se capisci che stai perdendo i punti di ripristino locali.

## Cosa lo Script NON Elimina Automaticamente

### Apple Mail

`~/Library/Mail` e `~/Library/Containers/com.apple.mail` possono contenere messaggi, allegati, account POP, indici e archivi locali. Lo script mostra solo le dimensioni e le aree più grandi.

Azioni sicure:

- in Mail.app, elimina i messaggi grandi,
- svuota il Cestino e la Posta indesiderata in Mail.app,
- controlla gli allegati,
- esporta le caselle di posta locali prima dell'intervento manuale.

### Browser

I profili Chrome/Firefox/Safari/Edge/Brave contengono cookie, sessioni, password, cronologia, segnalibri ed estensioni. Lo script non li elimina.

Cancella i dati dei siti tramite l'interfaccia utente:

- Safari: Impostazioni -> Privacy -> Gestisci dati siti web.
- Chrome/Brave/Edge: `chrome://settings/clearBrowserData`.
- Firefox: Impostazioni -> Privacy e sicurezza -> Cookie e dati dei siti web.

L'eliminazione dei cookie potrebbe disconnetterti dai siti web.

### Supporto Applicazioni e Preferenze

`~/Library/Application Support` e `~/Library/Preferences` spesso contengono database, impostazioni, licenze, progetti locali e configurazioni. Lo script non elimina i dati delle app attive. I rimasugli delle app disinstallate vengono solo segnalati.

## Come Leggere `plan.json`

Esempio:

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

Interpretazione:

- `SAFE`: può essere eseguito tramite `apply --from-plan`.
- `REVIEW`: richiede una decisione manuale.
- `DANGEROUS`: non verrà eseguito.
- `native_command`: lo script eseguirà uno strumento come `brew cleanup`; di solito senza ripristino dalla quarantena.
- `report_only`: solo informazioni, nessuna eliminazione.

## Esempi di Decisioni

| Situazione | Decisione |
|----------|---------|
| Vuoi recuperare rapidamente un po' di spazio senza rischi | `--auto-safe` |
| Hai molta cache npm/pnpm e internet | pulisci la categoria `dev` dopo la revisione |
| Hai un grande profilo Chrome/Firefox | non eliminare manualmente, usa l'interfaccia utente del browser |
| Grande `~/Library/Mail` | pulisci da Mail.app, non tramite lo script |
| Grandi `Xcode Archives` | controlla in Xcode Organizer |
| Nessun backup Time Machine | non eseguire un apply reale a meno che tu non usi consapevolmente `--allow-no-backup` |

## Comandi Utili

```bash
# Analizza tutto
bash cleanup_all.sh --dry-run --non-interactive --no-color

# Piano JSON
bash cleanup_all.sh plan --non-interactive --no-color

# Solo cache sviluppatore
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Pulizia più sicura
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interattivo, con domande complete
bash cleanup_all.sh --interactive

# Simula l'esecuzione del piano
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Ripristina dalla quarantena
bash cleanup_all.sh --restore latest

# Libera spazio dalla quarantena dopo la verifica
bash cleanup_all.sh --purge-quarantine latest --apply
```

## Quando Interrompere

Interrompi e non confermare la pulizia se:

- non hai un backup,
- non capisci il percorso,
- si riferisce a posta, browser, password, documenti o impostazioni,
- stai diagnosticando un arresto anomalo e hai bisogno dei log,
- l'app ha dati offline che non vuoi riscaricare.

La pulizia sicura consiste nel recuperare spazio da dati ricreabili, non nell'eliminare tutto ciò che è grande.
