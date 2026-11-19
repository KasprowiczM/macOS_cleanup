[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/pl/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Wersja 4.0.5** · Mac z procesorem Apple Silicon · macOS 11 lub nowszy · [Strona](https://macos-cleanup.64bit.site/pl/) · [Wsparcie](https://macos-cleanup.64bit.site/support) · [Licencja MIT](LICENSE) · [Zmiany](CHANGELOG.md)

Lokalne narzędzie do ostrożnego odzyskiwania miejsca na dysku w macOS. Najpierw mierzy, potem pokazuje plan i działa tylko na tym, co zatwierdzisz. Większość usunięć trafia do folderu kwarantanny, z którego da się je przywrócić. Ma interfejs w terminalu oraz zwykły tryb wiersza poleceń i nigdy nie używa `sudo`.

## Co czyści

Każda kategoria ma poziom (tier). Poziom decyduje o tym, jak narzędzie ją traktuje.

**Odtwarzalne (regenerable).** Właściciel danych odbuduje je sam. „Czyść bezpiecznie” i przebieg automatyczny obejmują tylko kategorie, których tryb to `auto`. Domyślnie jest to wyłącznie `app-caches`; każda inna kategoria odtwarzalna zaczyna w trybie `review`. Na karcie Kategorie (`m`) możesz przełączyć na `auto` kategorię odtwarzalną, która trafia do kwarantanny. `npm`, `yarn`, `pnpm` i `pip` uruchamiają narzędzie natywne i nigdy nie mogą mieć trybu `auto`.

| Kategoria | Co to jest | Cofanie |
|-----------|-----------|---------|
| `app-caches` | Pamięci podręczne aplikacji z wbudowanej listy dozwolonych | do przywrócenia |
| `xcode-derived` | Xcode DerivedData | do przywrócenia |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Pamięci podręczne kompilacji i pakietów, usuwane przez przeniesienie do kwarantanny | do przywrócenia |
| `npm`, `yarn`, `pnpm`, `pip` | Pamięci podręczne menedżerów pakietów, czyszczone przez samo narzędzie (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | trwałe |

**Do przeglądu (review).** Kosztowne do odbudowania albo widoczne dla Ciebie. Każda wymaga Twojej zgody w danej sesji. Nigdy nie wchodzą w skład przebiegu automatycznego.

| Kategoria | Co to jest | Cofanie |
|-----------|-----------|---------|
| `trash` | Zawartość Kosza | do przywrócenia |
| `user-caches` | Pozostałe elementy w `~/Library/Caches` | do przywrócenia |
| `app-caches-review` | Pamięci podręczne znanych aplikacji, które mogą trzymać dane offline lub długo się odbudowują | do przywrócenia |
| `user-logs`, `diagnostic-reports` | Stare logi i raporty awarii w Twoim folderze domowym | do przywrócenia |
| `device-support` | Stare foldery iOS Device Support (najnowszy dla każdej platformy zostaje) | do przywrócenia |
| `pnpm-stale` | Nieaktualne dane magazynu pnpm | do przywrócenia |
| `ios-backups` | Kopie zapasowe urządzeń iOS, potwierdzane pojedynczo | do przywrócenia |
| `installers` | Stare pliki DMG, PKG i ISO w Pobranych | do przywrócenia |
| `system-logs`, `tmp` | Logi systemowe i pliki tymczasowe poza folderem domowym | trwałe, tylko w trybie trwałym |
| `simulators`, `sim-runtimes` | Niedostępne symulatory i nieużywalne środowiska symulatorów (`xcrun simctl`) | trwałe |
| `brew`, `gem` | `brew cleanup --prune=all` i `gem cleanup`, które usuwają stare zainstalowane wersje | trwałe |
| `docker` | `docker system prune -f` | trwałe |
| `tm-snapshots` | Lokalne migawki Time Machine (`tmutil`); najnowsza zostaje | trwałe |

`sim-runtimes`, `docker` i `tm-snapshots` działają tylko wtedy, gdy wybierzesz je w przebiegu interaktywnym. Nigdy nie uruchamia ich „Czyść bezpiecznie” ani przebieg automatyczny.

**Tylko raport (report).** Mierzone i opisane, ale nigdy nieusuwane przez to narzędzie: `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` i `mail-downloads`.

## Jak dba o Twoje bezpieczeństwo

- **Nic się nie zmienia bez Twojej zgody.** Skan i podgląd nie dotykają Twoich plików. Domyślna odpowiedź na każde pytanie to nie.
- **Kwarantanna zamiast usuwania.** Tam, gdzie narzędzie samo przenosi pliki, przenosi je do folderu kwarantanny na tym samym dysku i zapisuje, co przeniosło, więc `restore` może je odłożyć z powrotem. Kwarantanna nie zwalnia miejsca, dopóki nie usuniesz jej na stałe.
- **Kroki trwałe są oznaczone.** Czyszczenia natywnymi narzędziami (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) nie da się cofnąć, więc nie da się ich przywrócić. Tryb trwały też usuwa na zawsze. Interfejs i pytania mówią o tym za każdym razem.
- **Lista chroniona, która pozostaje chroniona.** Mail, Wiadomości, Kalendarze, Kontakty, pęki kluczy, menedżery haseł, profile przeglądarek, Dokumenty, Biurko, biblioteki Zdjęć, Muzyki i Filmów, iCloud i inne foldery chmurowe, klucze SSH i GPG, pliki z danymi uwierzytelniającymi, `~/.config`, foldery ze źródłami i drzewa robocze Git nie są nigdy ruszane. Podobnie własny program narzędzia, jego ustawienia, stan i kwarantanna.
- **Sprawdzenie tuż przed działaniem.** Bezpośrednio przed usunięciem elementu narzędzie sprawdza, czy nadal istnieje, czy to ten sam element, który zaplanowano, czy leży w dozwolonych folderach swojej kategorii, czy nie jest w użyciu i czy nie jest zbyt świeży (jeśli ustawisz minimalny wiek).
- **Przebiegi automatyczne są wąskie.** Są domyślnie wyłączone. Po włączeniu dotykają tylko kategorii w trybie `auto` (domyślnie wyłącznie `app-caches`), wyłącznie przez kwarantannę, a potem usuwają na stałe przebiegi kwarantanny po upływie okresu przechowywania. Nie uruchamiają narzędzi natywnych i nigdy nie używają trybu trwałego.
- **Uczciwe liczby.** Wyniki pokazują szacunek (sumę rozmiarów tego, na czym działał przebieg) oraz, gdy da się to zmierzyć, rzeczywistą zmianę wolnego miejsca. Często się różnią, a interfejs wyjaśnia dlaczego. Rozmiary są podawane w jednostkach binarnych: KiB, MiB, GiB.

Kwarantanna to cofnięcie, nie kopia zapasowa. Przed pierwszym prawdziwym czyszczeniem miej aktualną kopię zapasową.

## Wymagania

- Mac z Apple Silicon i macOS 11 Big Sur lub nowszy. Kod nie blokuje komputerów Mac z procesorem Intel, ale nie są objęte oficjalnym wsparciem.
- `bash` 3.2 lub nowszy, dołączony do macOS.
- Python 3.9 lub nowszy dla interfejsu w terminalu, dla planów (`plan` i `apply`) oraz dla `migrate`. Jeśli go brakuje, uruchom `xcode-select --install`. Bez Pythona zwykły tryb wiersza poleceń nadal działa dla pozostałych poleceń.
- Terminal o rozmiarze co najmniej 40 kolumn na 12 wierszy dla interfejsu.
- Dostęp do sieci tylko na czas instalacji i dla aktualizacji, którą sam uruchamiasz poleceniem `macos-cleanup update-self`. Czyszczenie, skanowanie i przywracanie nigdy nie korzystają z sieci.

## Instalacja

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

Instalator pobiera paczkę wydania i plik `SHA256SUMS`, sprawdza sumę kontrolną, umieszcza program w `~/.local/share/macos-cleanup` i tworzy dowiązanie `~/.local/bin/macos-cleanup`. Nie wymaga `git`, nigdy nie używa `sudo`, nie zmienia Twoich ustawień, stanu ani kwarantanny, nie włącza uruchamiania automatycznego i nigdy nie rozpoczyna czyszczenia. Aby zainstalować konkretne wydanie: `install.sh --version 4.0.5`.

Jeśli wolisz sam sprawdzić pobrany plik:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/macos-cleanup-4.0.5.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Rozpakuj paczkę tylko wtedy, gdy sprawdzenie wypisze `OK`. Suma kontrolna chroni przed uszkodzonym lub niepełnym pobraniem. Wydania nie są podpisane kryptograficznie, więc suma pobrana z tego samego miejsca co paczka nie dowodzi, kto ją opublikował. Więcej opcji i ręczne kroki: [INSTALL.md](docs/user/INSTALL.md) (po angielsku).

Jeśli po instalacji powłoka nie znajduje polecenia `macos-cleanup`, otwórz nowe okno terminala i sprawdź, czy `~/.local/bin` jest w `PATH`.

## Pierwsze uruchomienie

```bash
macos-cleanup
```

W terminalu otwiera to interfejs na karcie Pulpit. Bez terminala zwykłe `macos-cleanup` to skan tylko do odczytu. Naciśnij `S`, aby przeskanować. Skan niczego nie zmienia. Naciśnij `P`, aby zobaczyć podgląd tego, co zrobiłoby czyszczenie, a potem `C`, aby wyczyścić bezpieczne kategorie, albo wybierz kategorie na karcie Kategorie i naciśnij `X`.

`mac-cleanup` to to samo polecenie co `macos-cleanup` i oba działają z dowolnego folderu. Bez argumentów każde otwiera interfejs; `--cli` uruchamia zwykły tryb terminalowy. Instalator informuje, gdy inny program w `PATH` odpowiada na którąś z tych nazw: wpisanie tej nazwy uruchomi wtedy tamten program, a nie macOS Cleanup.

Zwykły tekst zamiast interfejsu:

```bash
macos-cleanup scan
```

Zanim zrobisz cokolwiek naprawdę, uruchom `macos-cleanup doctor`, aby zobaczyć ścieżki, wolne miejsce, stan pełnego dostępu do dysku i lokalne migawki.

## Interfejs w terminalu

Siedem kart, wybieranych klawiszami `1`–`7`:

| # | Karta | Do czego służy |
|---|----------|----------------|
| 1 | Pulpit | Skan, podgląd, czyszczenie. Postęp na żywo dla każdej kategorii i wynik ostatniego przebiegu |
| 2 | Kategorie | Każda kategoria z poziomem, trybem i rozmiarem. Tu wybierasz, co czyścić |
| 3 | Kwarantanna | Przywracanie przebiegu, trwałe usuwanie przebiegu (wpisujesz końcówkę jego identyfikatora), trwałe usuwanie przeterminowanych |
| 4 | Historia | Poprzednie przebiegi i ich raporty. Zastosowanie świeżego planu |
| 5 | Ustawienia | Język i wygląd, limity bezpieczeństwa, reguły, przechowywanie, harmonogram, ścieżki, eksport i import |
| 6 | Diagnostyka | Kontrole stanu, pełny dostęp do dysku, podgląd migracji układu plików |
| 7 | Pomoc | Klawisze, poziomy, ścieżki, wersja |

Główne klawisze: strzałki przesuwają, `Enter` otwiera lub potwierdza, `Tab` zmienia panel, `Esc` cofa (lub pyta, czy przerwać działające zadanie), `1`–`7` przeskakują do karty, `?` otwiera pomoc, `L` pokazuje log, `q` kończy. `/` wyszukuje, a `s` sortuje na listach, które to oferują. Dolny wiersz zawsze pokazuje klawisze, które działają w danej chwili. Szczegóły: [USER_GUIDE.md](docs/user/USER_GUIDE.md).

## Zwykły wiersz poleceń

`macos-cleanup` z podpoleceniem nigdy nie otwiera interfejsu. Tak samo `--cli` oraz każde uruchomienie bez terminala. Zwykłe `macos-cleanup` bez terminala to skan tylko do odczytu.

```bash
macos-cleanup scan                        # zmierz, niczego nie zmieniaj
macos-cleanup plan                        # zmierz i zapisz plik planu
macos-cleanup clean --safe                # kategorie w trybie auto, po jednym pytaniu
macos-cleanup clean --only trash,npm      # dokładnie te kategorie, z pytaniem dla każdej sekcji
macos-cleanup quarantine list             # lista punktów przywracania
macos-cleanup restore latest              # przywróć ostatni przebieg
macos-cleanup quarantine purge expired --apply   # trwale usuń przeterminowane punkty przywracania
macos-cleanup doctor                      # sprawdź ten komputer
macos-cleanup history                     # lista poprzednich przebiegów
```

`scan`, `plan`, `quarantine list`, `history` i `doctor` tylko czytają. `clean`, `apply`, `restore` i `quarantine purge ... --apply` coś zmieniają. `quarantine purge` bez `--apply` tylko pokazuje podgląd. Przywracanie niczego nie nadpisuje: element, którego pierwotne miejsce jest zajęte, jest pomijany i zostaje w kwarantannie, a przywracanie kończy się wtedy ostrzeżeniem (kod wyjścia 1), nie błędem. Tabelę wszystkich poleceń i flag znajdziesz w [przewodniku](docs/user/USER_GUIDE.pl.md).

## Gdzie leżą pliki

| Co | Gdzie | Nadpisanie |
|----|-------|------------|
| Program | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Ustawienia i reguły | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Logi, raporty, plany, historia | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Kwarantanna (punkty przywracania) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

Nadpisania muszą być ścieżkami bezwzględnymi. Kwarantanna musi leżeć na tym samym dysku co Twój folder domowy. Aktualizacja wymienia tylko program. Ustawienia, stan i kwarantanna zostają.

## Uruchamianie automatyczne

Domyślnie wyłączone, a instalator nigdy ich nie włącza. Włączasz je w **Ustawieniach** albo poleceniem:

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Instaluje to jeden LaunchAgent macOS (`com.github.kasprowiczm.macos-cleanup`). Przebieg z harmonogramu robi tylko dwie rzeczy: przenosi elementy kategorii w trybie `auto` (domyślnie wyłącznie `app-caches`) do kwarantanny i usuwa na stałe przebiegi kwarantanny po upływie okresu przechowywania. Nie uruchamia żadnego narzędzia natywnego, niczego z poziomu „do przeglądu” i nigdy nie używa trybu trwałego. Zapisuje zwykły wpis w Historii.

## Aktualizacja i odinstalowanie

Aby zaktualizować, uruchom instalator ponownie albo `macos-cleanup update-self`. Poprzednia wersja zostaje obok programu jako `.previous`. Aby usunąć narzędzie:

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

Narzędzie pyta, czy zachować ustawienia i historię przebiegów, a kwarantanny nigdy nie usuwa bez `--purge-quarantine --yes`. Zobacz [UNINSTALL.md](docs/user/UNINSTALL.md) (po angielsku). Przechodzisz z wersji 3.x? Przeczytaj [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md) (po angielsku).

## Prywatność

Skanowanie, czyszczenie i przywracanie działają offline; sieć służy tylko do instalacji i do `update-self`. Narzędzie nie wysyła nigdzie ścieżek, wyników ani danych o użyciu i nie ma telemetrii. Logi, raporty i plany zostają w folderze stanu na Twoim Macu. Użyj `--redact`, aby zastąpić folder domowy znakiem `~` i pominąć nazwę użytkownika oraz hosta, zanim udostępnisz raport.

## Ograniczenia i znane braki

- Kwarantanna nie zwalnia miejsca, dopóki nie usuniesz jej na stałe, a lokalne migawki mogą jeszcze potem trzymać usunięte bloki. Miejsce wraca, gdy macOS je odzyska.
- Rozmiary to oszacowania górne. Klony APFS i współdzielone bloki nie są wykrywane.
- Bez pełnego dostępu do dysku niektórych folderów nie da się odczytać. Skan jest wtedy oznaczony jako częściowy, a te rozmiary to dolne granice.
- Czyszczenia natywnymi narzędziami i trybu trwałego nie da się cofnąć.
- Kategorie „tylko raport” nigdy nie są usuwane. Wyczyść je ich własnymi narzędziami.
- Wydania są weryfikowane sumą kontrolną, nie podpisem kryptograficznym.
- Obsługiwana konfiguracja to Apple Silicon z macOS 11 lub nowszym. Inne konfiguracje nie były testowane.

## Dokumentacja

[Przewodnik](docs/user/USER_GUIDE.pl.md) · [Instalacja](docs/user/INSTALL.md) · [Odinstalowanie](docs/user/UNINSTALL.md) · [Przejście z 3.x](docs/user/MIGRATING_FROM_V3.md) · [Zmiany](CHANGELOG.md)

## Wsparcie

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## Licencja

[MIT](LICENSE)

> **Używasz na własne ryzyko.** Narzędzie pyta, zanim zadziała, i zostawia drogę powrotną, ale żadne oprogramowanie nie jest wolne od błędów. Najpierw zrób kopię zapasową.
