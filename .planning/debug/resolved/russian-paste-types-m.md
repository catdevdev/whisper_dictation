---
status: resolved
trigger: "На английской раскладке диктовка вставляется правильно, а на русской вместо расшифровки вставляется только буква «м»."
created: 2026-08-13T16:30:00+03:00
updated: 2026-08-13T16:51:55+03:00
---

## Symptoms

expected: после распознавания полный текст вставляется через Command-V независимо от выбранной раскладки и остаётся в буфере
actual: с английской раскладкой вставка работает, с RussianWin появляется только строчная буква «м»
errors: видимого сообщения об ошибке нет
timeline: началось после установки исправления 2.4.1 build 241
reproduction: выбрать RussianWin, выполнить диктовку левым Option и завершить запись; вместо Paste поле получает символ с физической клавиши V

## Current Focus

hypothesis: confirmed — двухсобытийный CGEvent-path зависел от того, считает ли конкретное приложение или input method флаг Command полноценным переходом модификатора; при RussianWin физический V без принятого Command становится «м»
test: выполнен — стандартная Paste-команда Accessibility стала primary path, fallback использует Command-down/V-down/V-up/Command-up с private event state; добавлены deterministic regressions
expecting: confirmed structurally — primary path не проходит через раскладку, fallback формирует документированную полную последовательность модификатора
next_action: пользовательская проверка одной реальной диктовкой при RussianWin в исходном целевом поле

## Evidence

- timestamp: 2026-08-13T16:30:00+03:00
  checked: активный источник ввода macOS
  found: выбран Keyboard Layout RussianWin (ID 19458)
  implication: заявленная проблемная раскладка сейчас активна и подходит для проверки без изменения пользовательских настроек

- timestamp: 2026-08-13T16:30:00+03:00
  checked: `TextInsertionService.makePasteShortcutEvents` в 2.4.1
  found: создаются только V-down и V-up из `.combinedSessionState`; Command присутствует лишь как flags на этих событиях, отдельного перехода Command-down/up нет
  implication: поле может увидеть физический key code 9 как «м», если приложение или input method опирается на состояние модификатора, а не только flags события

- timestamp: 2026-08-13T16:51:55+03:00
  checked: pre-fix regression в `WhisperServicesVerification`
  found: 2.4.1 не компилируется с контрактом, требующим Command-down и Command-up вокруг V-down/V-up
  implication: тест точно ловит отсутствовавшие stateful переходы модификатора

- timestamp: 2026-08-13T16:51:55+03:00
  checked: архив предыдущей диагностики этого же проекта от 2026-05-22
  found: ранее `key code 9` также работал на английской раскладке и не работал на русской; надёжным исправлением стал Accessibility menu Paste с CGEvent fallback
  implication: независимая история воспроизведения подтверждает, что menu-command является проверенным layout-independent primary path для этой машины

- timestamp: 2026-08-13T16:51:55+03:00
  checked: Accessibility menu metadata текущего Google Chrome при RussianWin
  found: обычный Paste доступен как command character V с modifiers 0; две команды Paste and Match Style имеют modifiers 1 и 3
  implication: новый matcher выбирает именно обычный Paste и не может случайно активировать модифицированные варианты

- timestamp: 2026-08-13T16:51:55+03:00
  checked: полная signed build 2.4.2 build 242
  found: прошли 128 core, 9 app-state, 12 HUD, 74 service, 12 language и 27 Chrome checks; strict compile, codesign и designated requirement успешны
  implication: оба новых пути вставки совместимы со всем приложением и смежными функциями

- timestamp: 2026-08-13T16:51:55+03:00
  checked: установленная `/Applications/Whisper.app` после атомарного обновления и перезапуска
  found: запущен PID 74831 версии 2.4.2; установленный бинарник совпадает с dist, подпись валидна, Microphone и Accessibility возвращают TCC authValue=2
  implication: исправленная сборка реально активна и готова к пользовательской проверке без повторной выдачи разрешений

## Eliminated

- hypothesis: русский текст повреждается при записи в NSPasteboard
  evidence: service regression сохраняет и считывает полный Unicode transcript; пользователь подтверждает, что на английской раскладке тот же clipboard-first поток вставляет полный текст

## Resolution

root_cause: В 2.4.1 Command существовал только как flags на синтетических V-down/V-up из combined session state. Это не гарантировало stateful нажатие Command для каждого приложения/input method. При RussianWin приложение интерпретировало физический key code 9 как обычную букву «м», а не как Paste.
fix: Основной путь теперь находит стандартный Command-V menu item целевого приложения через Accessibility и выполняет AXPress, полностью обходя раскладку. Запасной CGEvent-path использует private event source и четыре перехода: Command-down, V-down, V-up, Command-up, с очищенным Option и гарантированным release.
verification: 262 автоматические проверки прошли; новый тест был красным до реализации и проверяет оба перехода Command, физический V, отсутствие Option и точный выбор ordinary Paste. Signed 2.4.2 установлен, запущен и сохранил Accessibility/Microphone. Финальная голосовая проверка остаётся пользовательской, поскольку внешний unsigned smoke binary не наследует TCC identity установленного Whisper.
files_changed:
  - Sources/WhisperApp/Services/TextInsertionService.swift
  - Tests/Manual/WhisperServicesVerification.swift
  - Config/Info.plist
  - README.md
