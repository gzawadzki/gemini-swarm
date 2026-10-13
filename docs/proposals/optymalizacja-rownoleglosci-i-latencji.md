# Diagnoza i plan optymalizacji: Równoległość i latencja wykonania zadań w gemini-swarm

**Data:** 2026-09-24

**Status:** Krok 1 wdrożony (2026-09-25). Krok 2 wdrożony jako instrukcja koordynatora, nie jako nowy format `tasks.json`: effort `medium` dla slice’ów mechanicznych, Contract-First, fan-out 2–4 zadań i fale w `SKILL.md` oraz `docs/reference/task-definition.md`.

**Powiązane pliki:** `scripts/launch.sh`, `scripts/lib.sh`, `scripts/critique.sh`, `scripts/status.sh`, `SKILL.md`, `.env`

---

## 1. Zidentyfikowane problemy

1. **Mało zadań jest przekazywanych równolegle do swarmu:**
   - Koordynatorzy (modele LLM) mają tendencję do szeregowania pracy (uruchamianie po jednym zadaniu), zamiast wykorzystywać potencjał jednoczesnej pracy wielu agentów.
2. **Długi czas przejścia całej ścieżki w podzadaniu:**
   - Pojedyncze podzadanie (slice) spędza zbyt wiele minut w potoku (`launch` $\to$ `worker` $\to$ `verify` $\to$ `critique` $\to$ `review`), co przy sekwencyjnym podejściu sumuje się do wielkich opóźnień.

---

## 2. Szczegółowa diagnoza techniczna

### A. Przyczyny niskiej równoległości (Fan-Out)

1. **Asekuracyjna dekompozycja i pozorne zależności (False Dependency Trap):**
   - Modele orkiestrujące nadinterpretują regułę zależności zadań z `SKILL.md` (*„When tasks genuinely depend on each other, run the upstream one...”*).
   - Zamiast odizolować zależności, orkiestrator traktuje zadania jako ściśle sekwencyjne (np. schemat $\to$ logika $\to$ endpoint $\to$ testy), uruchamiając je po kolei.
   - **Brak wzorca Contract-First:** Zamiast najpierw zdefiniować i zamrozić interfejsy/typy w gałęzi bazowej, orkiestrator czeka na pełne wdrożenie pierwszego modułu.
2. **Kognitywny koszt fazy Recon dla batcha zadań:**
   - `SKILL.md` bezwzględnie wymaga zdefiniowania `files` oraz `pitfalls` dla każdego zadania przed wygenerowaniem `tasks.json`.
   - Dla orkiestratora przygotowanie kompletnego reconu dla 3–4 zadań naraz jest obciążające, więc wybiera prostszą ścieżkę: recon 1 zadania $\to$ start $\to$ czekanie.
3. **Sekwencyjna pętla startowa w `scripts/launch.sh`:**
   - Pętla startowa w `launch.sh` wykonuje synchronicznie dla każdego zadania:
     `herdr worktree create` $\to$ `herdr agent start` $\to$ **blokujące oczekiwanie na gotowość TUI (`agent_ready`) do 60s** $\to$ prompt.
   - Uruchomienie 4 agentów w jednym batchu potrafi zająć 1–2 minuty na samym sekwencyjnym czekaniu na TUI przed wysłaniem pierwszego promptu.
4. **Płaska struktura `tasks.json` i brak wsparcia dla fal (Waves):**
   - Narzędzia nie wspierają naturalnego definiowania etapów/fal zadań (np. Fala 1: 3 zadania równoległe $\to$ integracja $\to$ Fala 2: 2 zadania zależne).

---

### B. Przyczyny długiego czasu przejścia podzadania (Latencja)

1. **Krytyczne wąskie gardło w `scripts/critique.sh` (Zysk do urwania: 60–150 sekund na zadanie):**
   - **Niewczytywany plik `.env`:** W repozytorium znajduje się `.env` z ustawieniem `HERDR_SWARM_JEV_AUTO_ACCEPT=1`. Jednak żaden ze skryptów (`lib.sh`, `critique.sh`, `launch.sh`) nie wczytuje pliku `.env` (`source .env`). W rezultacie zmienna środowiskowa nie istnieje w procesie bash, a `JEV_MODE` zawsze przyjmuje domyślną wartość `shadow`.
   - **Wymuszony fallback do recenzenta generatywnego:** W trybie `shadow` Jev wykonuje zapytanie sieciowe, ale skrypt bezwarunkowo przechodzi do recenzenta generatywnego.
   - **Eskalacja do modelu Pro z High Thinking:** Gdy workerem jest domyślny `gemini-3.8-flash-high`, funkcja `critique_model_for` wymusza użycie modelu alternatywnego:
     `CRITIQUE_ALT_MODEL = gemini-3.1-pro-high`.
   - **Narzut procesu:** `critique.sh` uruchamia proces `pi -p --no-session` z modelem Gemini 3.1 Pro i `thinking: high`. Cold-start Node/Pi oraz generowanie recenzji z głębokim rozumowaniem trwa **od 60 do 180 sekund**!
   - *Dla porównania:* Poprawnie działający Jev `auto_accept` weryfikuje diff w **1–2 sekundy** przez zapytanie HTTP curl.
2. **Domyślny maksymalny poziom myślenia workera (`thinking: high`):**
   - Domyślny model to `gemini-3.8-flash-high`.
   - Dla prostych, mechanicznych plasterków kodu (np. dodanie stałej, drobna modyfikacja funkcji, prosty test), model potrafi spędzić 30–60 sekund na wewnętrznym myśleniu przed podjęciem jakiejkolwiek akcji narzędziowej.
3. **Cold-start workera i oczekiwanie na gotowość TUI w `launch.sh`:**
   - Inicjalizacja procesu `pi` w herdr pane i wejście w stan gotowości interfejsu TUI (`agent_ready`) zajmuje średnio 10–25 sekund.
4. **Pasywne odpytywanie (Polling Latency):**
   - Koordynator nie otrzymuje sygnału o zakończeniu pracy workera, lecz sprawdza stan za pomocą `scripts/status.sh` co 30–60 sekund. Tworzy to martwy czas oczekiwania pomiędzy ukończeniem pracy przez workera a uruchomieniem bramki.

---

## 3. Plan wdrożenia usprawnień (Action Plan)

### Krok 1: Optymalizacje w skryptach wykonawczych (`scripts/`) — wdrożone

1. **Automatyczne wczytywanie `.env` w `scripts/lib.sh`:** zrobione. `load_dotenv` czyta repozytorjne `.env`, jeśli zmienna nie jest już w środowisku. Testy mogą to wyłączyć przez `HERDR_SWARM_DOTENV=0`.
2. **Optymalizacja parametrów recenzenta generatywnego:** zrobione. Domyślny `CRITIQUE_EFFORT` to `medium`. Gdy Jev nie zatwierdzi diffa napisanego przez domyślny model krytyki, fallback to `gemini-3.8-flash-medium`, nie `gemini-3.1-pro-high`.
3. **Zrównoleglenie fazy startowej w `scripts/launch.sh`:** zrobione. Start zadań nie czeka na TUI poprzedniego agenta przed startem następnego.
4. **Narzędzie blokującego oczekiwania (`scripts/wait.sh`):** zrobione.

---

### Krok 2: Usprawnienia w instrukcjach orkiestracji (`SKILL.md`) — wdrożone

1. **Wzorzec „Contract-First & Fan-Out by Default”:** zrobione w kroku 1b skilla. Interfejs, którego jeszcze nie ma, idzie do commita bazowego jako sygnatury i stuby. Potem 2–4 zadania o rozłącznych `files` w jednym `tasks.json`.
2. **Elastyczny dobór poziomu myślenia (`effort`):** zrobione węziej niż propozycja. Mechaniczne slice’y idą na `gemini-3.8-flash` z effort `medium`. `low` nie jest tym ustawieniem. Zwykła, niemechaniczna praca Pi zostaje na `gemini-3.8-flash-high` (ADR 0003).
3. **Fale zadań:** zrobione jako instrukcja, nie jako pole w `tasks.json`. Fala to bieżący plik zadań. Następna fala to nowy plik odpalony z bazy po integracji poprzedniej.
