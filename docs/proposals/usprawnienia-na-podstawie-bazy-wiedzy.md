# Propozycje usprawnień gemini-swarm na podstawie bazy wiedzy

Status: bramkę Jev i narzędzia P1 zaimplementowano. Launcher odmawia startu workerów bez świadomej zgody na wykonanie bez sandboxa; izolacja procesów, sieci i sekretów wymaga jeszcze rzeczywistego backendu sandboxa. Dla P2 udokumentowano ograniczenia danych o kwotach bez zmiany routingu. Eval set z archiwum jest złożony, ale bez etykiet człowieka: 33 rekordy, 0 ocen, 2 diffy ze sygnałem Jev, żaden nie jest kandydatem do auto-akceptacji. Próg `0.10` zostaje nieskalibrowany. Domyślny tryb to `auto_accept`; shadow jest tylko przy `HERDR_SWARM_JEV_MODE=shadow`. Patrz [badanie 2026-09-25](../reference/jev-eval-study.md).

## Stan obecny

`gemini-swarm` ma już izolację zmian przez worktree, etap `verify.sh`, ocenę w `critique.sh` (Jev z fallbackiem do recenzenta generatywnego) oraz archiwum przebiegów. Poniższe propozycje dotyczą przede wszystkim granic bezpieczeństwa i jakości decyzji bramki, a nie dokładania kolejnych agentów.

| Priorytet | Zmiana | Stan |
| --- | --- | --- |
| P0 | Ograniczyć uprawnienia workerów. | Częściowo. Launcher odmawia startu bez `--allow-unsandboxed`. Izolacji procesów, sieci i sekretów nie ma: Windows i herdr nie dają backendu sandboxa. Nie udawać jej wrapperem. |
| P0 | Auto-akceptacja Jev tylko przy `soundness == sound`. | Zrobione. `unknown`, `unsound` i `disabled` nie akceptują. |
| P1 | Eval set Jev i etykiety człowieka. | Zestaw jest złożony, etykiet nie ma. Próg `0.10` zostaje nieskalibrowany. Domyślny tryb to i tak `auto_accept`, na żądanie. |
| P1 | Pomiar reworku i wyniku runu. | Zrobione w zakresie, który da się zmierzyć. `scripts/bounce.sh` zapisuje `prompt.rework`. Czas człowieka, koszt i poprawki po merge zostają `unknown`, dopóki ktoś ich nie wpisze. |
| P2 | Quota-aware routing. | Nie do zrobienia. Pi nie podaje zapasu kwoty. Nie szacować go z błędów 429. |

## Zalecana kolejność

1. Model zagrożeń i świadoma zgoda na start bez sandboxa: zrobione. Backend OS: zablokowane.
2. Blokada auto-akceptacji bez `soundness == sound`: zrobione.
3. Oznaczony eval set: złożony, bez etykiet. To praca człowieka, nie skryptu.
4. Pomiar reworku: zrobione przez `bounce.sh` i `run-outcome.py`.
5. Quota-aware routing: sprawdzone, danych nie ma, routingu nie dodawać.

Nie dodawać na razie osobnego systemu kompakcji kontekstu do skryptów swarmu: zadania mają być krótkimi *slices*, a archiwizacja stanu już istnieje. Wrócić do tematu dopiero po stwierdzeniu w danych, że długość sesji jest przyczyną niepowodzeń.

## Materiały z lokalnej bazy wiedzy

- `Źródła/simonw/Wpisy/2026-08-21 Zaufanie oparte na sandboxie kontrola uprawnień agenta zamiast zaufania do model.md` — wypowiedź o granicy zaufania w środowisku wykonawczym.
- `Źródła/HamelHusain/Wpisy/2026-08-15 Model cascade próg decyzyjny wyznaczaj analizą statystyczną, a nie z założenia o.md` — próg kaskady wymaga analizy sygnału na własnych danych.
- `Źródła/kunchenguid/Wpisy/2026-09-22 Ewaluacja agentów przez wynik i wskaźnik reworku zamiast jakości promptu.md` — outcome i rework zamiast porównania promptów w izolacji.
- `Źródła/kunchenguid/Wpisy/2026-09-17 Routing modeli z uwzględnieniem pozostałego limitu kwot (quota runway).md` — uwzględnienie zapasu kwoty w wyborze modelu.

Ścieżki w tej sekcji odnoszą się do osobnego lokalnego vaulta `D:/projects/baza-wiedzy-ai-engineering`. Jego notatki są syntezami; pomysły wymagają weryfikacji w kodzie i eksperymentach na danych `gemini-swarm`.
