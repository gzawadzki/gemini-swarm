# Propozycje usprawnień gemini-swarm na podstawie bazy wiedzy

Status: propozycja do dyskusji. Nie jest planem wdrożenia ani potwierdzeniem skuteczności proponowanych zmian. Nie wdrożono i nie wypchnięto zmian do GitHuba.

## Stan obecny

`gemini-swarm` ma już izolację zmian przez worktree, etap `verify.sh`, ocenę w `critique.sh` (Jev z fallbackiem do recenzenta generatywnego) oraz archiwum przebiegów. Poniższe propozycje dotyczą przede wszystkim granic bezpieczeństwa i jakości decyzji bramki, a nie dokładania kolejnych agentów.

| Priorytet | Zmiana | Uzasadnienie i punkt zaczepienia |
| --- | --- | --- |
| P0 | Ograniczyć uprawnienia workerów: kontrola dostępu do plików, sieci i sekretów; wykonanie bez sandboxa tylko po świadomej decyzji. | `scripts/launch.sh` uruchamia Pi bez potwierdzania narzędzi i Codex z `--dangerously-bypass-approvals-and-sandbox`. Worktree izoluje zmiany Git, nie proces od hosta. |
| P0 | Automatyczna akceptacja Jev tylko po weryfikacji z potwierdzoną *soundness*. | `scripts/verify.sh` może zapisać `pass` przy `HERDR_SWARM_NO_SOUNDNESS=1`; `scripts/critique.sh` wymaga obecnie `verify.status == pass`, lecz nie sprawdza `soundness == sound`. Test, który nie potwierdza uruchomienia kodu z worktree, nie powinien otwierać ścieżki auto-akceptacji. |
| P1 | Utworzyć eval set dla decyzji Jev z archiwalnych diffów i ocen człowieka; najpierw tryb *shadow*. | Próg `HERDR_SWARM_JEV_ACCEPT_MAX=0.10` jest ustawieniem polityki, nie udokumentowanym tu wynikiem kalibracji na danych swarmu. Mierzyć szczególnie *false accepts* w podziale na rodzaj ryzyka i rozmiar diffu; do czasu oceny Jev nie pomija ludzkiego czytania. |
| P1 | Raportować wynik całego runu: ponowne prompty, poprawki po merge, czas człowieka, czas i koszt do poprawnego rozwiązania. | Archiwum w `scripts/lib.sh` zachowuje konfigurację, diff i werdykty bramek. To podstawa do pomiaru reworku zamiast oceniania samych promptów. |
| P2 | Dodać *quota-aware* ostrzeżenie przed startem równoległego runu, ewentualnie routing według dostępnego zapasu limitu. | Obecnie provider próbuje kolejne konto po twardym błędzie kwoty. Uprzedzanie byłoby lepsze, ale tylko jeśli Pi udostępnia wiarygodne dane o limitach; nie szacować ich z powietrza. |

## Zalecana kolejność

1. Zdefiniować model zagrożeń i ograniczyć uprawnienia workerów.
2. Zablokować auto-akceptację Jev, jeśli `soundness` nie jest `sound`; dodać testy wariantów `sound`, `unknown`, `unsound` i `disabled`.
3. Zbudować oznaczony eval set i uruchomić Jev w trybie shadow; dopiero na tej podstawie ustalać próg i zakres automatycznej akceptacji.
4. Dodać pomiar reworku i wyniku runów.
5. Sprawdzić dostępność danych o kwotach, zanim powstanie quota-aware routing.

Nie dodawać na razie osobnego systemu kompakcji kontekstu do skryptów swarmu: zadania mają być krótkimi *slices*, a archiwizacja stanu już istnieje. Wrócić do tematu dopiero po stwierdzeniu w danych, że długość sesji jest przyczyną niepowodzeń.

## Materiały z lokalnej bazy wiedzy

- `Źródła/simonw/Wpisy/2026-08-21 Zaufanie oparte na sandboxie kontrola uprawnień agenta zamiast zaufania do model.md` — wypowiedź o granicy zaufania w środowisku wykonawczym.
- `Źródła/HamelHusain/Wpisy/2026-08-15 Model cascade próg decyzyjny wyznaczaj analizą statystyczną, a nie z założenia o.md` — próg kaskady wymaga analizy sygnału na własnych danych.
- `Źródła/kunchenguid/Wpisy/2026-09-22 Ewaluacja agentów przez wynik i wskaźnik reworku zamiast jakości promptu.md` — outcome i rework zamiast porównania promptów w izolacji.
- `Źródła/kunchenguid/Wpisy/2026-09-17 Routing modeli z uwzględnieniem pozostałego limitu kwot (quota runway).md` — uwzględnienie zapasu kwoty w wyborze modelu.

Ścieżki w tej sekcji odnoszą się do osobnego lokalnego vaulta `D:/projects/baza-wiedzy-ai-engineering`. Jego notatki są syntezami; pomysły wymagają weryfikacji w kodzie i eksperymentach na danych `gemini-swarm`.
