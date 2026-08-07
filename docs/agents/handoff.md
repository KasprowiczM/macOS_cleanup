# Handoff — przekazanie wiedzy między sesjami

## Cel

Ten plik definiuje protokół tworzenia i używania plików handoff przy przełączaniu sesji Claude Code.

## Format pliku handoff

Tworzyć jako `docs/agents/handoff_YYYY-MM-DD.md`:

```markdown
# Handoff — [data]

## Stan zadania
- **Cel:** [co robimy]
- **Ukończono:** [lista kroków done]
- **W toku:** [aktualny krok]
- **Pozostało:** [lista TODO]

## Kluczowy kontekst
- [Które pliki były modyfikowane]
- [Które decyzje architektury podjęto]
- [Znane problemy lub pułapki]

## Następne kroki (dla następnej sesji)
1. Przeczytaj: [pliki do przeczytania]
2. Uruchom: [komendy weryfikacyjne]
3. Wykonaj: [konkretne zadanie]
```

## Kiedy tworzyć handoff

- Przed kompaktowaniem kontekstu (auto-compact lub manualnym)
- Po zakończeniu dużego bloku pracy (np. nowa kategoria czyszczenia)
- Gdy kontekst sesji przekracza ~60% okna
- Przed przełączeniem między modelami (Sonnet→Opus lub Opus→Sonnet)

## Priorytety przy kompaktowaniu

Zachowaj w podsumowaniu (w tej kolejności):
1. Zasady bezpieczeństwa (NIGDY nie usuwaj maila, keychain)
2. Ostatni stan modyfikowanych plików
3. Decyzje architekturalne sesji
4. Lista błędów i ich rozwiązań

## Szybki start nowej sesji

```
1. Przeczytaj: CLAUDE.md
2. Przeczytaj: docs/agents/handoff_YYYY-MM-DD.md (najnowszy)
3. Sprawdź: bash -n cleanup_all.sh lib/*.sh config/*.sh
4. Kontynuuj od "Następne kroki"
```
