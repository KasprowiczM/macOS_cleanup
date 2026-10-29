[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — instrukcja obsługi dla użytkownika

Ten dokument zakłada, że nie musisz znać struktury `~/Library` ani działania cache. Celem jest bezpieczne odzyskanie miejsca, bez kasowania poczty, haseł, dokumentów, profili przeglądarek, projektów i ustawień aplikacji.

## Najważniejsza zasada

Nie uruchamiaj czyszczenia „w ciemno”. Najpierw zrób analizę:

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

To niczego nie usuwa. Skrypt pokaże:

- ile miejsca potencjalnie można odzyskać,
- które elementy są `SAFE`,
- które wymagają `REVIEW`,
- które są `DANGEROUS` i nie będą automatycznie usuwane.

## Klasy ryzyka

| Klasa | Co oznacza | Co robi skrypt |
|-------|------------|----------------|
| `SAFE` | Dane odtwarzalne: cache aplikacji, build cache, stare logi, tmp. | Może usunąć w `auto-safe` albo wykonać z planu. Dla plików użytkownika domyślnie używa kwarantanny. |
| `REVIEW` | Da się odzyskać miejsce, ale może być koszt: ponowne pobieranie, wolniejszy start, utrata logów diagnostycznych, stan emulatora. | Pokazuje w planie. Nie usuwa automatycznie bez świadomej decyzji. |
| `DANGEROUS` | Poczta, profile przeglądarek, hasła, dokumenty, ustawienia, dane aktywnych aplikacji. | Tylko raportuje albo blokuje. Nie usuwa automatycznie. |

Jeśli nie rozumiesz pozycji w raporcie, traktuj ją jako `REVIEW` albo `DANGEROUS`.

## Backup i kwarantanna

Realne czyszczenie wymaga świeżego backupu Time Machine. Jeżeli skrypt nie potrafi go potwierdzić, zablokuje czyszczenie. Możesz wymusić działanie przez:

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

Używaj tego tylko, jeśli świadomie akceptujesz ryzyko.

Kwarantanna nie zwalnia miejsca od razu. Domyślnie pliki użytkownika trafiają do:

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

Odzyskasz miejsce dopiero przez `--permanent` albo późniejszy purge:

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Restore:

```bash
bash cleanup_all.sh --restore latest
```

## Najbezpieczniejszy workflow

### 1. Analiza

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Przeczytaj raport w `reports/report_*.md`.

### 2. Plan JSON

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

Plan zapisuje `reports/plan_*.json`. Każda operacja ma `id`, `risk`, `path`, `description` i `recommendation`.

### 3. Najbezpieczniejsze czyszczenie

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

To czyści tylko jawnie znane `SAFE` cache aplikacji. Jeśli brak potwierdzonego backupu:

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Interaktywny przegląd większych rzeczy

```bash
bash cleanup_all.sh --interactive
```

Skrypt pokaże kategorię, rozmiar, konsekwencje i pytanie. Domyślna odpowiedź to zawsze `nie`.

## Co można usuwać bez większych konsekwencji

Poniższe rzeczy są zwykle `SAFE`, ale nadal mogą spowodować wolniejszy pierwszy start aplikacji:

- Slack/Teams/Discord cache: aplikacja odtworzy web assets i miniatury.
- VS Code/Cursor `Cache` i `Code Cache`: edytor odbuduje cache; projekty i ustawienia zostają.
- Spotify zwykły `Cache`: muzyka/podcasty pobiorą się ponownie.
- Zoom cache: nie usuwa nagrań z `Documents/Zoom`.
- Xcode DerivedData: Xcode przebuduje projekty od zera.
- npm/pnpm/yarn/pip/Homebrew cache: zależności pobiorą się ponownie.
- stare logi: tracisz historię diagnostyczną, ale nie dane aplikacji.
- stare pliki `/tmp`: tymczasowe, macOS zwykle czyści je sam.

## Co wymaga analizy

### Ogólne `~/Library/Caches`

Skrypt pokazuje top-level elementy `~/Library/Caches` jako `REVIEW`, bo nie wszystkie cache są równie tanie do odtworzenia. Niektóre aplikacje trzymają tam duże dane offline, mapy, media, modele AI albo cache robocze.

Co sprawdzić:

- czy znasz aplikację po nazwie folderu,
- czy aplikacja nie ma danych offline,
- czy akceptujesz ponowne pobranie gigabajtów danych,
- czy nie jesteś w trakcie pracy offline.

### JetBrains

Cache JetBrains może być duży. Usunięcie nie kasuje projektów, ale IDE odbuduje indeksy. To może potrwać długo i obciążyć CPU. Usuń, gdy masz czas na ponowną indeksację.

### Adobe Media Cache

Nie usuwa źródłowych projektów ani mediów, ale Premiere/After Effects mogą ponownie generować podglądy, conform audio/video i cache. Usuń tylko, jeśli masz oryginalne media i akceptujesz dłuższe pierwsze otwarcie projektu.

### Figma

Cache jest zwykle odtwarzalny, ale może wpłynąć na ponowne otwieranie dużych plików i pracę offline. Preferuj review.

### Spotify PersistentCache

Może oznaczać większe dane streaming/offline. Usunięcie może wymusić ponowne pobieranie. Zwykły `Spotify Cache` jest bezpieczniejszy niż `PersistentCache`.

### Xcode Device Support

To symbole debugowania dla urządzeń iOS/watchOS/tvOS. Xcode pobierze je ponownie po podłączeniu urządzenia z daną wersją systemu. Usuń tylko, jeśli nie debugujesz starych urządzeń albo masz czas i internet.

### Xcode Archives

Archiwa `.xcarchive` mogą być potrzebne do App Store, symbolizacji crashy i odtworzenia buildów. Skrypt tylko raportuje. Usuwaj ręcznie z Xcode Organizer po sprawdzeniu.

### Środowiska uruchomieniowe symulatora

Środowiska (runtimes), które `simctl` oznacza jako bezużyteczne, leżą w magazynie zarządzanym przez system. Skrypt nigdy nie usuwa ich przez `rm`: w trybie `--interactive` po Twojej zgodzie uruchamia `xcrun simctl runtime delete --unusable` i pomija ten krok, gdy działa Xcode, Simulator lub xcodebuild. Plany tylko je raportują. Xcode może pobrać środowisko ponownie. Sprawdź:

```bash
xcrun simctl runtime delete --unusable --dry-run
```

### Docker

`docker system prune -f` usuwa obrazy, zatrzymane kontenery, sieci i build cache. Nie usuwa wolumenów, ale zatrzymane kontenery mogą zawierać stan, którego jeszcze nie przeniosłeś do wolumenu. Sprawdź:

```bash
docker ps -a
docker system df
```

### Android AVD

Emulatory Android mogą zawierać lokalny stan aplikacji testowych. Usuń przez Android Studio Device Manager, nie przez ręczne `rm`, jeśli nie jesteś pewien.

### Maven `~/.m2/repository`

Może zawierać lokalnie zbudowane artefakty, których nie ma w internecie. Skrypt traktuje to jako review-only.

### Backupy iOS

To kopie iPhone/iPad. Usuwaj tylko, jeśli masz aktualny backup iCloud albo nowy backup w Finderze.

### Time Machine local snapshots

macOS usuwa je automatycznie, gdy potrzebuje miejsca. Ręczne czyszczenie ma sens tylko, gdy rozumiesz, że tracisz lokalne punkty przywracania.

## Czego skrypt nie usuwa automatycznie

### Apple Mail

`~/Library/Mail` i `~/Library/Containers/com.apple.mail` mogą zawierać wiadomości, załączniki, konta POP, indeksy i lokalne archiwa. Skrypt tylko pokazuje rozmiary i największe obszary.

Bezpieczne działania:

- w Mail.app usuń duże wiadomości,
- opróżnij Kosz i Spam w Mail.app,
- sprawdź załączniki,
- wyeksportuj lokalne skrzynki przed ręczną ingerencją.

### Przeglądarki

Profile Chrome/Firefox/Safari/Edge/Brave zawierają cookies, sesje, hasła, historię, zakładki i rozszerzenia. Skrypt ich nie usuwa.

Czyść dane stron przez UI:

- Safari: Settings -> Privacy -> Manage Website Data.
- Chrome/Brave/Edge: `chrome://settings/clearBrowserData`.
- Firefox: Settings -> Privacy & Security -> Cookies and Site Data.

Usunięcie cookies może wylogować Cię ze stron.

### Application Support i Preferences

`~/Library/Application Support` i `~/Library/Preferences` często zawierają bazy danych, ustawienia, licencje, lokalne projekty i konfiguracje. Skrypt nie usuwa aktywnych danych aplikacji. Pozostałości po aplikacjach są tylko raportowane.

## Jak czytać `plan.json`

Przykład:

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

Interpretacja:

- `SAFE`: można wykonać przez `apply --from-plan`.
- `REVIEW`: wymaga ręcznej decyzji.
- `DANGEROUS`: nie zostanie wykonane.
- `native_command`: skrypt uruchomi narzędzie typu `brew cleanup`; zwykle bez rollbacku kwarantanny.
- `report_only`: tylko informacja, bez usuwania.

## Przykładowe decyzje

| Sytuacja | Decyzja |
|----------|---------|
| Chcesz szybko odzyskać trochę miejsca bez ryzyka | `--auto-safe` |
| Masz dużo npm/pnpm cache i internet | wyczyść kategorię `dev` po review |
| Masz duży Chrome/Firefox profile | nie usuwaj ręcznie, użyj UI przeglądarki |
| Duży `~/Library/Mail` | czyść z Mail.app, nie przez skrypt |
| Duże `Xcode Archives` | sprawdź Xcode Organizer |
| Brak backupu Time Machine | nie rób realnego apply, chyba że świadomie używasz `--allow-no-backup` |

## Komendy pod ręką

```bash
# Analiza wszystkiego
bash cleanup_all.sh --dry-run --non-interactive --no-color

# Plan JSON
bash cleanup_all.sh plan --non-interactive --no-color

# Tylko developer cache
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Najbezpieczniejsze czyszczenie
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interaktywnie, z pełnymi pytaniami
bash cleanup_all.sh --interactive

# Symulacja wykonania planu
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Odtworzenie z kwarantanny
bash cleanup_all.sh --restore latest

# Zwolnienie miejsca z kwarantanny po sprawdzeniu
bash cleanup_all.sh --purge-quarantine latest --apply
```

## Kiedy przerwać

Przerwij i nie potwierdzaj czyszczenia, jeśli:

- nie masz backupu,
- nie rozumiesz ścieżki,
- dotyczy to poczty, przeglądarki, hasła, dokumentów albo ustawień,
- jesteś w trakcie diagnozowania awarii i potrzebujesz logów,
- aplikacja ma dane offline, których nie chcesz pobierać od nowa.

Bezpieczne czyszczenie polega na odzyskiwaniu miejsca z danych odtwarzalnych, nie na usuwaniu wszystkiego, co jest duże.
