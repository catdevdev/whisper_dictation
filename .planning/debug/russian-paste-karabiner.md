---
status: verifying
trigger: "Исправление 2.4.2 не помогло: при русской раскладке после диктовки по-прежнему вставляется только буква «м»; на Mac установлен Karabiner-Elements."
created: 2026-08-13T17:07:31+03:00
updated: 2026-08-13T17:21:48+03:00
---

## Symptoms

expected: распознанный текст остаётся в буфере обмена и целиком вставляется в сфокусированное поле при любой раскладке
actual: на английской раскладке вставка работает, на русской вместо текста появляется только строчная буква «м»; исправление 2.4.2 поведения не изменило
errors: видимого сообщения об ошибке нет
timeline: воспроизводится и на 2.4.2 build 242 после предыдущего исправления
reproduction: выбрать русскую раскладку, сфокусировать поле, запустить диктовку Option, завершить запись

## Current Focus

hypothesis: confirmed — приложения без доступного Paste menu получают fallback через глобальный HID stream; Karabiner обрабатывает его до приложения назначения, поэтому синтетический V может прийти без ожидаемого Command state
test: выполнен — тот же Command-down/V-down/V-up/Command-up отправлен напрямую PID Chrome при активной RussianWin и работающем Karabiner
expecting: confirmed — целевое поле получает полный текст из pasteboard, а глобальные Karabiner rules не участвуют
next_action: пользовательская проверка одной реальной диктовкой в исходном поле на установленной 2.4.3

## Evidence

- timestamp: 2026-08-13T17:07:31+03:00
  checked: пользовательская проверка установленной Whisper 2.4.2
  found: прежний симптом «м» полностью сохранился
  implication: прежняя структурная проверка не доказала, что primary menu path реально выполняется в исходном поле; debug-сессия была закрыта преждевременно

- timestamp: 2026-08-13T17:07:31+03:00
  checked: активный профиль Karabiner-Elements
  found: профиль `Default profile` содержит русско-украинские Colemak-DH правила для Command+V; device-specific правило преобразует физический V с Command в D с Command, а общие правила также обрабатывают V при ru/uk
  implication: CGEvent fallback не является независимым от пользовательской раскладки и remapper-а, даже если события содержат Command flags

- timestamp: 2026-08-13T17:21:48+03:00
  checked: подписанный тем же designated requirement Accessibility probe против frontmost kitty
  found: probe имеет AX trust; focused AXTextArea не позволяет менять AXSelectedText/AXValue/AXSelectedTextRange, а menu tree из 195 элементов вообще не содержит Paste; production service возвращает keyboardShortcutPaste
  implication: fallback является обязательным для реальных приложений вроде kitty, поэтому одного menu-path недостаточно

- timestamp: 2026-08-13T17:21:48+03:00
  checked: CoreGraphics SDK contract и соседний SelectedTextService
  found: CGEventPost вводит событие в глобальный stream выбранного tap location, а CGEventPostToPid адресует stream конкретного приложения; SelectedTextService уже использует postToPid для targeted Command-C
  implication: targeted posting является существующим проектным паттерном и убирает Karabiner из маршрута вставки без изменения пользовательской конфигурации

- timestamp: 2026-08-13T17:21:48+03:00
  checked: signed targeted integration probe в реальном Chrome address field
  found: при активной Keyboard Layout RussianWin (ID 19458) и запущенном Karabiner поле получило полную строку `WHISPER_TARGETED_Ж`; тестовую вкладку затем закрыли, clipboard восстановлен
  implication: process-targeted Command-V сохраняет Unicode paste и не превращается в «м» в Chromium при фактической проблемной среде

- timestamp: 2026-08-13T17:21:48+03:00
  checked: full 2.4.3 build and installed application
  found: прошли 237 Swift и 27 Chrome checks, strict compile и certificate-backed codesign; установлен и запущен build 243, installed executable SHA-256 совпадает с dist
  implication: исправление находится в реально запущенном приложении и не нарушило смежные функции

## Eliminated

- hypothesis: явные Command-down/V-down/V-up/Command-up делают CGEvent fallback надёжным при любой пользовательской конфигурации
  evidence: пользователь воспроизвёл тот же символ «м» на 2.4.2, а активный Karabiner профиль перехватывает Command+V для ru/uk

## Resolution

root_cause:
  Accessibility menu Paste недоступен в части приложений, поэтому Whisper 2.4.2 переходил к глобальному `.cghidEventTap`. Этот stream проходит через Karabiner до целевого приложения; активные ru/uk Colemak rules обрабатывают V/Command и могут оставить приложению обычный физический V, который RussianWin переводит в «м».
fix:
  Fallback больше не публикует события в глобальный HID stream. Полная последовательность Command-down/V-down/V-up/Command-up направляется через CGEventPostToPid строго в захваченный PID приложения назначения; clipboard-first и Accessibility menu primary path сохранены.
verification:
  76 service checks подтверждают четыре события и один captured PID. Полная сборка имеет 264 проверки. Signed UI probe вставил `WHISPER_TARGETED_Ж` целиком в реальный Chrome при RussianWin и запущенном Karabiner. Финальная проверка исходного пользовательского поля ожидается.
files_changed:
  - Sources/WhisperApp/Services/TextInsertionService.swift
  - Tests/Manual/WhisperServicesVerification.swift
  - Config/Info.plist
  - README.md
