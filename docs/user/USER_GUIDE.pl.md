# Przewodnik użytkownika (polski)

**macOS Cleanup 4.0.2** · Mac z Apple Silicon · macOS 11 lub nowszy

## Co robi

macOS Cleanup mierzy, co można wyczyścić na Twoim Macu, pokazuje plan i działa tylko na tym, co zatwierdzisz. Ma dwa oblicza: interfejs w terminalu (`macos-cleanup`) i zwykły tryb wiersza poleceń (`macos-cleanup scan`, `macos-cleanup clean` itd.). Oba uruchamiają ten sam silnik i pokazują te same fakty.

Czyszczenie przebiega zawsze tą samą drogą:

```
pomiar  ->  plan  ->  Twoja zgoda  ->  działanie  ->  raport
```

Pomiar niczego nie zmienia. Działanie dotyczy tylko elementów, które zatwierdziłeś, a każdy z nich jest sprawdzany jeszcze raz tuż przed dotknięciem.

## Czego nigdy nie robi

- Nigdy nie używa `sudo` i nigdy nie prosi o hasło.
- Nigdy nie rusza listy chronionej: Poczty, Wiadomości, Kalendarzy, Kontaktów, pęków kluczy, menedżerów haseł, profili przeglądarek, Dokumentów, Biurka, bibliotek Zdjęć, Muzyki i Filmów, iCloud i innych folderów synchronizowanych z chmurą, kluczy SSH i GPG, plików z danymi uwierzytelniającymi, `~/.config`, folderów ze źródłami, drzew roboczych Git (poza Koszem) oraz własnego programu narzędzia, jego ustawień, stanu i kwarantanny.
- Nigdy nie usuwa kategorii „tylko raport” (zobacz [Poziomy](#poziomy)).
- Skanowanie, czyszczenie i przywracanie nigdy nie korzystają z sieci. Sieć służy tylko do instalacji i do aktualizacji, którą sam uruchamiasz poleceniem `macos-cleanup update-self` (albo przyciskiem sprawdzania aktualizacji na karcie Pomoc).
- Nigdy nie uruchamia narzędzia natywnego ani kategorii z poziomu „do przeglądu” w przebiegu automatycznym.

## Poziomy

| Poziom | Znaczenie | Tryb domyślny | W „Czyść bezpiecznie” | W przebiegu automatycznym |
|--------|-----------|---------------|----------------|---------------------------|
| Odtwarzalny (regenerable) | Właściciel danych odbuduje je sam | `review`; `app-caches` to `auto` | tylko kategorie w trybie `auto` | tylko kategorie w trybie `auto`, wyłącznie przez kwarantannę |
| Do przeglądu (review) | Kosztowne do odbudowania albo widoczne dla Ciebie | `review` | nie, pyta o każdą kategorię | nigdy |
| Tylko raport (report) | Mierzone i opisane, nigdy nieusuwane | `skip` | nie | nie |

Każda kategoria ma też stan cofania:

| Oznaczenie | Znaczenie |
|------------|-----------|
| `restorable` | Przeniesione do kwarantanny. `restore` odkłada je z powrotem. |
| `permanent` | Usunięte przez narzędzie natywne albo w trybie trwałym. Nie da się tego przywrócić. |
| `not removed` | Tylko raport. |

Domyślnie tylko `app-caches` ma tryb `auto`. Na karcie Kategorie (`m`) możesz przełączyć na `auto` każdą inną kategorię odtwarzalną, która trafia do kwarantanny. `npm`, `yarn`, `pnpm` i `pip` uruchamiają narzędzie natywne i nigdy nie mogą mieć trybu `auto`.

Czyszczenia narzędziami natywnymi są trwałe: `npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`. `system-logs` i `tmp` leżą poza folderem domowym i można je usunąć tylko w trybie trwałym, więc w domyślnym trybie kwarantanny są pomijane z powodem „wymaga trybu trwałego” (`needs_permanent`). `sim-runtimes`, `docker` i `tm-snapshots` działają tylko w przebiegu interaktywnym, które sam rozpoczynasz.

Pełną listę kategorii według poziomów znajdziesz w [README](../../README.pl.md#co-czyści). Można ją też wypisać razem z poziomem i bieżącym trybem każdej kategorii: `bash cleanup_all.sh --cli --list-categories`. Z `--json` dostajesz także rozmiary z ostatniego skanu.

## Otwieranie interfejsu

```bash
macos-cleanup
```

`mac-cleanup` to to samo polecenie co `macos-cleanup` i oba działają z dowolnego folderu. Bez argumentów każde otwiera interfejs; `--cli` uruchamia zwykły tryb terminalowy. Instalator informuje, gdy inny program w `PATH` odpowiada na którąś z tych nazw: wpisanie tej nazwy uruchomi wtedy tamten program, a nie macOS Cleanup.

W terminalu otwiera to interfejs na karcie Pulpit. W skrypcie, przez SSH bez terminala albo gdy wyjście jest przekierowane, dostajesz zwykły tekst. Inne sposoby wejścia:

```bash
macos-cleanup ui categories      # otwórz od razu wybraną kartę
macos-cleanup --tui              # wymagaj interfejsu; bez terminala kończy się kodem 2
```

`ui` przyjmuje `dashboard`, `categories`, `quarantine`, `history`, `settings`, `diagnostics` lub `help`. Okno musi mieć co najmniej 40 kolumn na 12 wierszy. Jeśli brakuje Pythona 3.9 lub nowszego albo `TERM` ma wartość `dumb`, zwykłe uruchomienie wraca do trybu tekstowego z jednym wierszem wyjaśnienia, a `--tui` kończy się kodem 2.

Klawisze działające wszędzie:

| Klawisz | Działanie |
|---------|-----------|
| Strzałki | Ruch |
| `Enter` | Otwórz lub potwierdź |
| `Tab` | Następny panel |
| `Esc` | Wróć, zamknij okno dialogowe albo przerwij działające zadanie (najpierw pyta) |
| `1`–`7` | Przejdź do karty |
| `L` | Pokaż pełny log |
| `?` | Pomoc dla bieżącej karty |
| `q` | Zakończ |

`/` wyszukuje, a `s` sortuje na listach, które to oferują (Kategorie, Ustawienia i zawartość przebiegu kwarantanny). Działa też mysz. Dolny wiersz zawsze wymienia klawisze, które działają w danej chwili.

## Karty

### 1. Pulpit

**Strefy.** Karta podsumowania ostatniego przebiegu (szacunek, pomiar, kwarantanna), panel przebiegu z jednym wierszem na kategorię (symbol stanu, nazwa, postęp, rozmiar), panel elementów wybranej kategorii i log.

| Klawisz | Działanie | Zmienia pliki? |
|---------|-----------|----------------|
| `S` | Skan | nie |
| `P` | Podgląd: zbuduj plan i pokaż, co zrobiłoby czyszczenie | nie |
| `C` | Czyść bezpiecznie: kategorie w trybie `auto`. Okno dialogowe podaje reguły i pyta najpierw | tak |
| `X` | Czyść wybrane: kategorie zaznaczone na karcie Kategorie. Okno dialogowe je wymienia i pyta najpierw | tak |
| `Esc` | Zatrzymaj działające zadanie (najpierw pyta) | zatrzymuje je |

Klawisze działają też małymi literami. Po przebiegu pokazuje się strona wyniku; klawisze akcji czekają, aż zamkniesz ją klawiszem `Esc` (albo przyciskiem Gotowe), i mówi o tym dolny wiersz klawiszy. Karta wyniku pokazuje „szacunek X, pomiar Y” i wyjaśnia, skąd różnica. Zobacz [Uczciwe liczenie miejsca](#uczciwe-liczenie-miejsca).

### 2. Kategorie

**Strefy.** Lista (kategoria, plakietka poziomu, tryb, rozmiar, oznaczenie cofania) i panel szczegółów (czym jest, jakie foldery obejmuje, polecenie natywne, jeśli jest, największe elementy z ostatniego planu).

| Klawisz | Działanie |
|---------|-----------|
| `Space` | Zaznacz lub odznacz |
| `a` | Zaznacz wszystkie kategorie odtwarzalne |
| `n` | Odznacz wszystko |
| `s` | Sortuj listę |
| `/` | Szukaj |
| `m` | Przełącz tryb: `auto`, `review`, `skip`. Zapisywane w `category-modes.tsv` |
| `Enter` | Pokaż szczegóły |
| `X` | Wyczyść zaznaczone kategorie |

Tryby w skrócie: `auto` oznacza, że „Czyść bezpiecznie” może ją objąć; `review` — że zawsze jest pytanie; `skip` — że nigdy nie jest przetwarzana. Ustawienie `auto` dla kategorii z poziomu „do przeglądu” jest zapisywane, ale interfejs pokazuje wtedy „zgoda nadal wymagana”: kategorie tego poziomu nigdy nie działają bez Twojego potwierdzenia.

### 3. Kwarantanna

**Strefy.** Lista przebiegów (identyfikator, wiek, rozmiar, liczba elementów, stan manifestu, przeterminowany) i panel zawartości z pierwszymi 200 wierszami manifestu wybranego przebiegu.

| Klawisz | Działanie | Uwagi |
|---------|-----------|-------|
| `r` | Przywróć wybrany przebieg albo zaznaczone elementy | Najpierw podgląd (co wróci, co zostanie pominięte). Jego przycisk Run to jedyne potwierdzenie; domyślnie zaznaczone jest Cancel |
| `p` | Usuń wybrany przebieg | Trwałe. Na potwierdzenie wpisujesz końcówkę identyfikatora przebiegu (cyfry po ostatnim podkreślniku) albo cały identyfikator |
| `E` | Usuń wszystkie przeterminowane przebiegi | Trwałe. Najpierw okno dialogowe |
| `o` | Pokaż folder przebiegu w Finderze | Tylko odczyt |

W panelu zawartości `Space` zaznacza element, `a` zaznacza wszystkie widoczne, `n` czyści zaznaczenie, a `r` przywraca zaznaczone elementy (cały przebieg, gdy nic nie zaznaczono). Przywracanie niczego nie nadpisuje: element, którego pierwotne miejsce jest zajęte, jest pomijany i zostaje w kwarantannie. Stan manifestu to `ok`, `legacy` (lista przywracania przeniesiona z 3.x) albo `missing` (nie ma z czego przywracać).

### 4. Historia

**Strefy.** Lista przebiegów, panel podsumowania i przeglądarka raportu.

| Klawisz | Działanie | Uwagi |
|---------|-----------|-------|
| `Enter` | Otwórz raport | Tylko odczyt |
| `A` | Zastosuj ten plan | Tylko dla planu młodszego niż 24 godziny. Wybierasz same elementy bezpieczne albo bezpieczne plus do przeglądu; każdy element do przeglądu jest pytany jeszcze raz |
| `f` | Filtruj według typu przebiegu | |
| `y` | Skopiuj ścieżkę raportu | |
| `o` | Pokaż folder przebiegu w Finderze | Tylko odczyt |

### 5. Ustawienia

Sekcje: wygląd, bezpieczeństwo, reguły, wydajność, historia, harmonogram, ścieżki, system. `Enter` edytuje wiersz, `Space` przełącza wiersz włącz/wyłącz, lewo i prawo zmieniają liczbę lub wybór, `d` przywraca jedno ustawienie do wartości domyślnej, `/` wyszukuje. Eksport, import i reset to wiersze w sekcji System. Każdy wiersz opisano w części [Ustawienia](#ustawienia).

### 6. Diagnostyka

**Strefy.** Lista kontroli i panel faktów, z `macos-cleanup doctor`.

| Klawisz | Działanie |
|---------|-----------|
| `F` | Otwórz panel „Pełny dostęp do dysku” w Ustawieniach systemowych |
| `M` | Pokaż wynik `macos-cleanup migrate --preview` |
| `u` | Pokaż ścieżki, których nie dało się odczytać |
| `P` | Pokaż ścieżki chronione |
| `r` | Odśwież kontrole |

### 7. Pomoc

Klawisze, krótkie wyjaśnienie poziomów, Twoje ścieżki, wersja i licencja. `U` sprawdza, czy jest nowsze wydanie, gdy o to poprosisz (to jedyna rzecz w interfejsie, która korzysta z sieci), i proponuje instalację.

## Przeprowadzanie czyszczenia

**Czyść bezpiecznie** (`C` albo `macos-cleanup clean --safe`) zadaje jedno pytanie, a potem przetwarza każdą kategorię w trybie `auto`, dla elementów, których polityka nie ocenia jako niebezpieczne. Domyślna odpowiedź to nie. Domyślnie jest to tylko `app-caches`; pozostałe kategorie odtwarzalne zaczynają w trybie `review`, a te, które trafiają do kwarantanny, możesz przełączyć na `auto` na karcie Kategorie. Kategorie z narzędziami natywnymi (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `docker` i pozostałe) nigdy nie wchodzą do Czyść bezpiecznie ani do przebiegu automatycznego.

**Czyść wybrane** (`X` albo `--only`) przetwarza dokładnie wybrane kategorie. W interfejsie zgodę wyrażasz w oknie dialogowym, a silnik jest potem uruchamiany tylko dla tych kategorii. W zwykłym wierszu poleceń `clean --only <identyfikatory>` zadaje jedno pytanie dla każdej sekcji, której dotyka.

**Czyszczenie** bez żadnej z tych opcji (`macos-cleanup clean`) przechodzi po kolei przez sekcje, wyjaśnia każdą i pyta. Kategorie z poziomu „do przeglądu” zawsze pytają.

Przed przebiegiem zmieniającym pliki narzędzie sprawdza, czy nie działa inny taki przebieg (wykluczają się nawzajem), ostrzega, gdy nie wykryje świeżej kopii zapasowej, a przy braku pełnego dostępu do dysku ostrzega, że skan jest częściowy.

## Wiersz poleceń

Każde podpolecenie `macos-cleanup` odpowiada jednemu wywołaniu silnika. Możesz też używać silnika bezpośrednio: `bash cleanup_all.sh --cli ...` z folderu programu.

| Polecenie | Co robi | Tylko odczyt? |
|-----------|---------|---------------|
| `macos-cleanup` | Interfejs w terminalu albo zwykły przebieg próbny bez terminala | tak |
| `macos-cleanup ui [karta]` | Interfejs na wybranej karcie | tak |
| `macos-cleanup scan [opcje]` | Przebieg próbny: zmierz i zaraportuj | tak |
| `macos-cleanup plan [opcje]` | Zmierz i zapisz plik planu | tak |
| `macos-cleanup clean [opcje]` | Czyszczenie interaktywne | nie |
| `macos-cleanup clean --safe [opcje]` | Kategorie w trybie `auto`, po jednym pytaniu | nie |
| `macos-cleanup apply --from-plan PLIK [opcje]` | Zastosuj wcześniej zapisany plan | nie |
| `macos-cleanup restore PRZEBIEG` | Przywróć przebieg z kwarantanny (`PRZEBIEG` to identyfikator, `latest` albo plik manifestu) | nie |
| `macos-cleanup quarantine list` | Lista punktów przywracania | tak |
| `macos-cleanup quarantine purge WYBÓR` | Podgląd usunięcia. `WYBÓR` to `latest`, identyfikator, `all` albo `expired` | tak |
| `macos-cleanup quarantine purge WYBÓR --apply` | Trwale usuń te przebiegi | nie |
| `macos-cleanup history [--json] [--limit N]` | Poprzednie przebiegi | tak |
| `macos-cleanup doctor [--json]` | Kontrole stanu | tak |
| `macos-cleanup schedule install\|remove\|status [--time HH:MM] [--weekday DZIEŃ] [--yes]` | Zarządzanie uruchamianiem automatycznym. `install` pokazuje, co zapisze, i pyta najpierw (`--yes` pomija pytanie). `status` tylko czyta | install i remove zmieniają plik LaunchAgent |
| `macos-cleanup migrate --preview\|--apply\|--undo MANIFEST` | Skopiuj dane z 3.x do nowego układu. `--preview` tylko czyta | `--apply` i `--undo` kopiują pliki |
| `macos-cleanup update-self [--check\|--rollback]` | Sprawdź nowsze wydanie, zainstaluj je albo wróć do poprzedniej wersji. Nigdy nie uruchamia się samo | `--check` tylko czyta |
| `macos-cleanup uninstall [--dry-run] [--purge-data]` | Usuń narzędzie | `--dry-run` tylko czyta |
| `macos-cleanup version`, `macos-cleanup help` | Wersja i pomoc | tak |

„Tylko odczyt” znaczy, że polecenie nigdy nie zmienia Twoich plików. Każdy przebieg i tak zapisuje własny folder w katalogu stanu.

### Flagi silnika

Działają w `bash cleanup_all.sh` i tam, gdzie mają sens, są przekazywane przez podpolecenia.

| Flaga lub tryb | Tylko odczyt? | Znaczenie |
|----------------|---------------|-----------|
| `--dry-run`, `analyze` | tak | Zmierz i zaraportuj. Wygrywa z każdą flagą, która coś zmienia |
| `plan` | tak | Zmierz i zapisz `plan.json` w folderze przebiegu |
| `apply --from-plan PLIK` | nie | Zastosuj plan. Domyślnie elementy bezpieczne |
| `--interactive` | nie | Pytaj o każdą sekcję |
| `--auto-safe` | nie | Kategorie w trybie `auto`, po jednym pytaniu |
| `--category NAZWA[,NAZWA]` | — | Ogranicz do sekcji (`trash`, `user-caches`, `logs`, `system`, `dev`, `app-leftovers`, `time-machine`, `large-files`) lub identyfikatorów kategorii |
| `--only ID[,ID]` | — | Ogranicz dokładnie do tych identyfikatorów kategorii. Działa z każdym trybem |
| `--include NAZWA` | — | To samo co `--category` |
| `--exclude ŚCIEŻKA` | — | Nigdy nie dotykaj tej ścieżki (można powtarzać). Czyta też `excludes.txt` |
| `--restore PRZEBIEG\|PLIK\|latest` | nie | Przywróć z kwarantanny. Z `--dry-run` tylko pokazuje, co by wróciło, a co zostałoby pominięte (z `--json` w formacie JSON) |
| `--list-quarantine` | tak | Lista punktów przywracania. Z `--json` w formacie JSON |
| `--purge-quarantine latest\|ID\|all\|expired` | podgląd | Podgląd usunięcia. Z `--apply` wykonuje je naprawdę. `--retention-days N` określa, co jest przeterminowane |
| `--apply` | nie | Wykonaj usunięcie naprawdę |
| `--prune-artifacts` | nie | Usuń stare foldery przebiegów z katalogu stanu. Nigdy nie rusza kwarantanny |
| `--quarantine` | — | Przenoś usuwane elementy do kwarantanny (domyślnie) |
| `--permanent` | nie | Usuwaj na zawsze, po tych samych kontrolach. Zobacz ostrzeżenie niżej |
| `--include-review` | — | Pozwól `apply --from-plan` objąć elementy z poziomu „do przeglądu”. Pyta ponownie o każdy |
| `--require-typing-path` | — | Każdy element do przeglądu w `apply --from-plan` pyta o pełną ścieżkę zamiast tak/nie |
| `--plan-file PLIK` | — | Gdzie `plan` zapisuje plan |
| `--non-interactive` | — | Nigdy nie czytaj z terminala. Każde pytanie dostaje odpowiedź nie |
| `--yes` | — | Z `--non-interactive` zatwierdza tylko kategorie bezpieczne |
| `--unattended` | nie | Tego używa przebieg automatyczny. Wymusza `--non-interactive --quarantine`. Odmawia z `--permanent`, `--include-review` i `--interactive` |
| `--json` | — | Wypisz podsumowanie przebiegu jako JSON na standardowe wyjście |
| `--redact` | — | Zastąp folder domowy znakiem `~`. Pomiń użytkownika i host |
| `--plain`, `--quiet`, `--no-color`, `--log-level POZIOM`, `--lang KOD` | — | Sterowanie wyjściem |
| `--explain` | tak | Wyjaśnij, co narzędzie robi i dlaczego |
| `--doctor` | tak | Kontrole stanu. Z `--json` w formacie JSON |
| `--history` | tak | Poprzednie przebiegi. Z `--json` w formacie JSON |
| `--list-categories` | tak | Kategorie z poziomem i trybem. Z `--json` w formacie JSON, który zawiera też rozmiary z ostatniego skanu |
| `--schedule install\|remove\|status`, `--time HH:MM` | install, remove | Zarządzanie uruchamianiem automatycznym |
| `--cli` | — | Nigdy nie otwieraj interfejsu |
| `--tui` | tak | Wymagaj interfejsu. Bez terminala kończy się kodem 2 |
| `--version`, `--help` | tak | Wersja (`macos-cleanup 4.0.2`) i pomoc |

**`--permanent` usuwa na zawsze.** Niczego nie da się przywrócić. Przebieg automatyczny nigdy go nie używa, a jest to ustawienie, które trzeba wybrać świadomie (`remove_mode`). Nawet wtedy folder, którego nie da się w pełni odczytać, nie jest usuwany w trybie trwałym.

### Plany

`macos-cleanup plan` zapisuje plik planu w folderze przebiegu. `apply --from-plan` przyjmuje tylko plan zapisany przez to narzędzie, na tym Macu i dla tego użytkownika, młodszy niż 24 godziny, którego wpisy leżą w dozwolonych folderach swoich kategorii. Plan edytowany ręcznie, z innego Maca lub od innego użytkownika, z wersji 3.x albo zbyt stary jest odrzucany z kodem 2. Plan jest podpisany kluczem, który narzędzie trzyma w swoim folderze stanu. Chroni to przed pomyłkami. Nie chroni przed kimś, kto już kontroluje Twoje konto.

Apply nigdy nie wykonuje elementów ocenionych jako niebezpieczne. Elementy z poziomu „do przeglądu” działają tylko z `--include-review`, a każdy element jest pytany jeszcze raz (pytanie tak/nie albo jego pełna ścieżka z `--require-typing-path`). `sim-runtimes`, `docker` i `tm-snapshots` w ogóle nie da się zastosować z pliku planu i są pomijane z powodem „plan odrzucony” (`plan_rejected`). Dla nich użyj przebiegu interaktywnego.

### Kody wyjścia

| Kod | Znaczenie |
|-----|-----------|
| 0 | Gotowe |
| 1 | Przebieg się zakończył, ale coś się nie udało, `doctor` znalazł problem albo przywracanie lub usuwanie nie objęło każdego wpisu. Przywracanie, które tylko pominęło elementy z zajętym pierwotnym miejscem, kończy się ostrzeżeniem i też zwraca 1 |
| 2 | Błędne użycie, odrzucona kombinacja opcji, nieprawidłowe ustawienie, odrzucony plan albo `--tui` bez terminala |
| 3 | Ta wersja macOS nie jest obsługiwana |
| 130 | Przerwano |

## Ustawienia

Ustawienia leżą w `settings.conf` w folderze konfiguracji, w wierszach `KLUCZ=WARTOŚĆ`. Plik jest czytany jak zwykłe dane i nigdy nie jest uruchamiany jak skrypt, a przyjmowane są tylko klucze z poniższej tabeli. Interfejs edytuje ten sam plik, więc wartość możesz ustawić tam albo edytować plik.

Pierwszeństwo, od najsilniejszego: flaga wiersza poleceń, zmienna środowiskowa `MACOS_CLEANUP_*`, zmienna środowiskowa w starym stylu (zobacz [Zmienne środowiskowe](#zmienne-środowiskowe)), `settings.conf`, wartość wbudowana.

| Ustawienie (klucz w `settings.conf`) | Wartości | Domyślnie | Co robi |
|--------------------------------------|----------|-----------|---------|
| `MACOS_CLEANUP_LANG` | `en`, `pl`, `de`, `es`, `fr`, `it`, `pt` | język systemu, jeśli obsługiwany, w przeciwnym razie `en` | Język interfejsu i komunikatów |
| `MACOS_CLEANUP_REMOVE_MODE` | `quarantine`, `permanent` | `quarantine` | Dokąd trafiają usuwane elementy. `permanent` prosi o potwierdzenie w interfejsie |
| `MACOS_CLEANUP_QUARANTINE_RETENTION_DAYS` | 1–365 | 30 | Jak stary musi być przebieg kwarantanny, by uznać go za przeterminowany |
| `MACOS_CLEANUP_RECENT_DAYS` | 0–90 | 0 | Pomijaj elementy zmienione w ostatnich N dniach. 0 wyłącza |
| `MACOS_CLEANUP_BACKUP_MAX_AGE_DAYS` | 1–90 | 14 | Jak stara może być ostatnia kopia zapasowa, zanim pojawi się ostrzeżenie |
| `MACOS_CLEANUP_REDACT` | `true`, `false` | `false` | To samo co `--redact` dla każdego przebiegu |
| `MACOS_CLEANUP_LOG_MAX_AGE_DAYS` | 1–365 | 30 | Minimalny wiek starych logów |
| `MACOS_CLEANUP_DMG_MAX_AGE_DAYS` | 1–365 | 30 | Minimalny wiek instalatorów w Pobranych |
| `MACOS_CLEANUP_DEVICE_SUPPORT_MIN_AGE_DAYS` | 30–720 | 180 | Minimalny wiek folderów iOS Device Support |
| `MACOS_CLEANUP_HOME_TOP_TIMEOUT` | 1–120 sekund | 20 | Limit czasu informacyjnej listy największych folderów domowych |
| `MACOS_CLEANUP_ARTIFACT_RETENTION_DAYS` | 0–365 | 30 | Jak długo `--prune-artifacts` zachowuje foldery przebiegów. 0 wyłącza czyszczenie |
| `MACOS_CLEANUP_SCHEDULE_TIME` | `HH:MM` | `10:30` | Pora dnia przebiegu automatycznego |
| `MACOS_CLEANUP_SCHEDULE_WEEKDAY` | `daily`, `mon`–`sun` | `sun` | Dzień przebiegu automatycznego |

Interfejs trzyma też ustawienia wyglądu (motyw, kolor akcentu, gęstość, symbole ASCII, mysz, panel pomocy, animacja, automatyczna zmiana rozmiaru okna, domyślna akcja pulpitu i styl potwierdzeń) w `tui-settings.json`. Nie wpływają one na silnik.

Gdy pole wyszukiwania ma fokus (Kategorie, Ustawienia), cały wiersz jest podświetlony, a każdy klawisz, także cyfry, wpisuje się do niego. `Esc` czyści wpisany tekst, drugie `Esc` opuszcza pole, a wiersz klawiszy mówi, które z tych dwóch zrobi.

Akcje na karcie Ustawienia: edycja listy wykluczeń, natychmiastowe czyszczenie starych folderów przebiegów, instalacja lub usunięcie uruchamiania automatycznego, eksport, import, reset.

### Tryby kategorii (`category-modes.tsv`)

Jeden wiersz na każdą zmienioną kategorię, rozdzielany tabulatorami: `id`, `mode`, `source`. Tryb to `auto`, `review` lub `skip`. Karta Kategorie zapisuje ten plik po naciśnięciu `m`. Możesz też edytować go ręcznie.

```
npm	skip	user
trash	review	user
```

### Własne reguły (`rules.local.yaml`)

Dołączony plik reguł ocenia ścieżki jako `safe`, `ask` lub `never`. Aby zmienić to dla siebie, utwórz w folderze konfiguracji `rules.local.yaml` o takim samym układzie. Może on tylko uczynić narzędzie ostrożniejszym: podnieść ścieżkę z `safe` do `ask` lub `never` albo dodać wpis `never`. Nigdy nie obniży oceny. Nieprawidłowy plik jest ignorowany z ostrzeżeniem i obowiązują reguły dołączone do programu.

### Wykluczenia (`excludes.txt`)

Jedna ścieżka w wierszu. Dozwolone jest `~`, a `#` zaczyna komentarz. Wykluczone ścieżki nie są ruszane w żadnym trybie. `--exclude ŚCIEŻKA` dodaje kolejne na jeden przebieg.

```
# zostaw mój cache kompilacji
~/Library/Caches/my-build-tool
```

## Cykl życia kwarantanny i przywracanie

1. **Przeniesienie.** Usunięcie w trybie kwarantanny to zmiana nazwy (przeniesienie) do folderu kwarantanny, więc jest szybkie i nie zajmuje dodatkowego miejsca. Dlatego kwarantanna musi leżeć na tym samym dysku co Twój folder domowy; jeśli nie, tryb kwarantanny jest odrzucany.
2. **Zapis.** Każdy przebieg dostaje własny folder nazwany identyfikatorem przebiegu. Zawiera przeniesione elementy, `manifest.tsv` (co skąd pochodzi), `journal.jsonl` (co w tym przebiegu przeniesiono, przywrócono lub usunięto) i `run-info.json`.
3. **Przywracanie.** `macos-cleanup restore PRZEBIEG` odkłada elementy na dawne miejsce. `PRZEBIEG` to identyfikator, `latest` (najnowszy przebieg, w którym jest jeszcze coś do przywrócenia) albo plik manifestu. Przywracanie odmawia zapisu poza Twoim folderem domowym, na ścieżki chronione, przez dowiązania symboliczne w folderach nadrzędnych oraz z plików spoza folderu kwarantanny. Element, którego pierwotne miejsce jest zajęte, jest pomijany i zostaje w kwarantannie zamiast zostać nadpisany; przywracanie kończy się wtedy ostrzeżeniem, a polecenie kodem 1.
4. **Opróżnione przebiegi znikają.** Gdy przywracanie nie zostawia w przebiegu kwarantanny żadnego pliku, pusty folder przebiegu jest usuwany z kwarantanny. Przywracanie zostaje w Historii. Przebieg, w którym został choć jeden element (na przykład pominięty, bo jego miejsce było zajęte), zostaje.
5. **Przeterminowanie.** Przebieg starszy niż okres przechowywania (domyślnie 30 dni) jest oznaczany jako przeterminowany. Nic nie jest usuwane automatycznie poza krokiem czyszczenia w przebiegu automatycznym.
6. **Usunięcie.** `macos-cleanup quarantine purge WYBÓR --apply` usuwa cały folder przebiegu razem z jego manifestem. Po usunięciu nie ma już z czego przywracać. Bez `--apply` dostajesz tylko podgląd.

```bash
macos-cleanup quarantine list
macos-cleanup restore latest
macos-cleanup quarantine purge latest
macos-cleanup quarantine purge latest --apply
macos-cleanup quarantine purge expired --apply
```

`quarantine list` pokazuje stan manifestu dla każdego przebiegu: `ok`, `legacy` albo `missing`. Przebiegi utworzone w 3.x pozostają możliwe do przywrócenia; zobacz [MIGRATING_FROM_V3.md](MIGRATING_FROM_V3.md) (po angielsku).

Kwarantanna to cofnięcie Twoich ostatnich decyzji, nie kopia zapasowa Maca.

## Uczciwe liczenie miejsca

Narzędzie pokazuje dwie liczby i nie udaje, że to jedna.

- **Szacunek (estimated)** to suma rozmiarów elementów, na których działał przebieg (dla skanu lub podglądu: wszystko, co znalazł skan). Rozmiary są podawane w jednostkach binarnych: KiB, MiB, GiB. To górna granica: narzędzie nie widzi, że klony APFS współdzielą bloki, więc te same dane mogą zostać policzone więcej niż raz.
- **Pomiar (measured)** to zmiana wolnego miejsca na dysku, odczytana przed przebiegiem i ponownie po nim. Po usunięciu narzędzie chwilę czeka i odczytuje jeszcze raz, aż dwa odczyty się zgodzą, bo APFS oddaje miejsce asynchronicznie. Pomiar jest pokazywany tylko wtedy, gdy udało się go wykonać.

Często się różnią, a karta wyniku mówi dlaczego:

- **Kwarantanna niczego nie zwalnia.** Przeniesienie pliku w obrębie dysku nie zwalnia jego bloków. Miejsce wraca po usunięciu kwarantanny.
- **Lokalne migawki trzymają usunięte bloki.** Migawki Time Machine i systemowe zachowują dane, których nie ma już w Twoich plikach. Narzędzie pokazuje liczbę migawek obok zmierzonej wartości.
- **Klony współdzielą bloki.** Usunięcie jednej kopii sklonowanego pliku zwalnia niewiele albo nic, dopóki istnieje druga kopia.
- **APFS odzyskuje miejsce z opóźnieniem.** Wolne miejsce może jeszcze rosnąć przez jakiś czas po usunięciu.
- **Miejsce do zwolnienia (purgeable).** macOS może oznaczyć część miejsca jako do zwolnienia. Narzędzie pokazuje je tylko wtedy, gdy zgłasza je `diskutil`, co zależy od wersji macOS.

Szacunek dla skanu, który nie mógł wszystkiego odczytać, jest oznaczany jako częściowy i dla tych folderów jest dolną granicą.

Skan nigdy nie czeka na jedno zawieszone narzędzie. Każdy zewnętrzny program, który uruchamia (pomiary rozmiarów, `find`, `df`, `diskutil`, `mdfind`, menedżery pakietów, `brew`, `docker`, `tmutil`, `xcrun`), ma limit czasu, a sprawdzenie, które go przekroczy, liczy się jako „nie zmierzono”, nigdy jako 0 bajtów. Czas, jaki zajęła każda kategoria, jest zapisywany w `engine.log` przebiegu (`scan time: <kategoria> <sekundy>s`) i w jego zdarzeniach.

## Pełny dostęp do dysku

macOS ukrywa niektóre foldery (dane Safari, Mail, Wiadomości i inne) przed programami bez pełnego dostępu do dysku. Narzędzie nie ma sposobu, by zapytać macOS, czy ma dostęp, więc sprawdza kilka chronionych miejsc, wypisując same nazwy i nigdy nie czytając zawartości plików: `~/Library/Mail`, `~/Library/Safari`, `~/Library/Application Support/com.apple.TCC` oraz, jako słabszą wskazówkę, `~/Library/Containers` (tylko listę nazw). Wynik to `granted`, `denied` albo `unknown`. Nigdy nie zagląda do prywatnych folderów wewnątrz kontenerów innych aplikacji, bo to powoduje wyświetlenie przez macOS okna z prośbą o zgodę.

Gdy dostępu brakuje, narzędzie ostrzega raz, oznacza skan jako częściowy i działa dalej. Nigdy nie próbuje obejść ograniczenia. Folder, którego nie da się w pełni odczytać, nie jest usuwany w trybie trwałym.

Aby nadać dostęp: otwórz Ustawienia systemowe, przejdź do Prywatność i ochrona, potem Pełny dostęp do dysku i dodaj swoją aplikację terminala. W interfejsie karta Diagnostyka, a na niej `F`, otwiera ten panel. Potem uruchom terminal ponownie. Pełny dostęp do dysku jest opcjonalny: narzędzie działa bez niego, z mniej kompletnymi liczbami.

## Uruchamianie automatyczne

Domyślnie wyłączone. Instalator nigdy ich nie włącza.

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Zapisuje to plik `~/Library/LaunchAgents/com.github.kasprowiczm.macos-cleanup.plist`. Dzień tygodnia pochodzi z `--weekday` albo z ustawienia `MACOS_CLEANUP_SCHEDULE_WEEKDAY` (domyślnie niedziela), a godzina z `--time` lub `MACOS_CLEANUP_SCHEDULE_TIME`. Jeśli Mac o tej porze śpi, przebieg nastąpi po jego wybudzeniu. Działa z niskim priorytetem.

Przebieg z harmonogramu robi tylko to:

1. Przenosi elementy do kwarantanny, wyłącznie z kategorii w trybie `auto` (domyślnie tylko `app-caches`) oznaczonych do użycia bez nadzoru i nigdy elementów ocenionych jako niebezpieczne.
2. Usuwa przebiegi kwarantanny po upływie okresu przechowywania.

Nigdy nie uruchamia narzędzia natywnego (`npm`, `pnpm`, `pip`, `brew`, `docker`, `simctl`, `tmutil`), nie dotyka poziomu „do przeglądu”, nie używa trybu trwałego i nigdy nie zadaje pytań. Zostawia zwykły wpis w Historii. Ponieważ może ruszać pliki bez nadzoru, włącz je dopiero po tym, jak sam sprawdzisz narzędzie ręcznie.

## Rozwiązywanie problemów

| Problem | Co zrobić |
|---------|-----------|
| `macos-cleanup: command not found` | Otwórz nowy terminal. Sprawdź, czy `~/.local/bin` jest w `PATH`. W razie potrzeby uruchom instalator ponownie |
| Wpisanie `macos-cleanup` lub `mac-cleanup` uruchamia inny program | Inny program wcześniej w `PATH` ma tę nazwę (instalator podaje plik). Usuń go lub zmień mu nazwę albo uruchom `~/.local/bin/macos-cleanup` pełną ścieżką |
| Interfejs się nie otwiera | Potrzebuje terminala, `TERM` innego niż `dumb` i Pythona 3.9 lub nowszego. `macos-cleanup scan` działa bez niego. `--tui` kończy się kodem 2, gdy nie może wystartować |
| „Another run is active” (działa inny przebieg) | Przebiegi zmieniające pliki wykluczają się nawzajem, także z przebiegiem wersji 3.x. Poczekaj na jego koniec. Blokada pozostawiona przez przerwany przebieg jest odzyskiwana automatycznie |
| Skan pokazuje „partial” (częściowy) | Nie udało się odczytać niektórych folderów. Zobacz [Pełny dostęp do dysku](#pełny-dostęp-do-dysku) |
| Pomiar jest znacznie niższy niż szacunek | Zobacz [Uczciwe liczenie miejsca](#uczciwe-liczenie-miejsca). Sprawdź `macos-cleanup quarantine list` i `macos-cleanup doctor` pod kątem migawek |
| Kategoria została pominięta z podanym powodem | Powód jest w raporcie. `in_use` — program-właściciel był uruchomiony; `too_recent` — element zmienił się w ramach Twojego minimalnego wieku; `needs_permanent` — leży poza Twoim folderem domowym; `protected_path` — jest na liście chronionej |
| Plan odrzucony | Plan jest zbyt stary, z 3.x, edytowany albo z innego Maca lub od innego użytkownika. Uruchom `macos-cleanup plan` ponownie |
| Ustawienie jest ignorowane | Ścieżka względna w zmiennej `MACOS_CLEANUP_*` to błąd (kod 2). Wartości w `settings.conf` spoza powyższej tabeli są ignorowane |
| Tryb kwarantanny jest odrzucany | Folder kwarantanny leży na innym dysku niż Twój folder domowy. Przenieś go z powrotem, używając `MACOS_CLEANUP_QUARANTINE_DIR` |
| Chcę zobaczyć wszystko, co narzędzie wie | `macos-cleanup doctor` |

Gdzie są raporty: każdy przebieg ma folder w `~/.local/state/macos-cleanup/runs/<identyfikator>/` z plikami `report.md`, `run.json`, `plan.json`, `journal.jsonl` i `engine.log`. W interfejsie karta Historia, a na niej `o`, pokazuje ten folder w Finderze.

## Zmienne środowiskowe

Ustawienia i nadpisania używają prefiksu `MACOS_CLEANUP_`. Nadpisania ścieżek muszą być bezwzględne.

| Zmienna | Znaczenie |
|---------|-----------|
| `MACOS_CLEANUP_HOME` | Folder programu |
| `MACOS_CLEANUP_CONFIG_DIR` | Folder ustawień |
| `MACOS_CLEANUP_STATE_DIR` | Folder stanu |
| `MACOS_CLEANUP_QUARANTINE_DIR` | Folder kwarantanny. Jego ostatni człon musi brzmieć `quarantine` |
| `MACOS_CLEANUP_LEGACY_DIR` | Gdzie `migrate` szuka folderu z wersji 3.x |
| `MACOS_CLEANUP_LANG` i pozostałe nazwy ustawień | Zobacz [Ustawienia](#ustawienia) |

Stare nazwy nadal czytane w 4.x: `LANG_CODE`, `QUARANTINE_ROOT`, `ARTIFACT_RETENTION_DAYS`, `HOME_TOP_DIRS_TIMEOUT`, `LOGS_DIR`, `REPORTS_DIR`, `RULES_FILE`. `LOGS_DIR` i `REPORTS_DIR` są przestarzałe i przy użyciu trafiają do logu. `AUTO_YES` i `REMOVE_MODE` ze środowiska są ignorowane z jednym ostrzeżeniem, bo zgoda pochodzi teraz wyłącznie z flag i `settings.conf`. `NON_INTERACTIVE` nadal jest respektowana z uwagą o wycofaniu, ponieważ może tylko zmniejszyć interaktywność przebiegu.
