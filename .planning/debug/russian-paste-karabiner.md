---
status: verifying
trigger: "Исправление 2.4.2 не помогло: при русской раскладке после диктовки по-прежнему вставляется только буква «м»; на Mac установлен Karabiner-Elements."
created: 2026-08-13T17:07:31+03:00
updated: 2026-08-13T18:07:10+03:00
---

## Symptoms

expected: распознанный текст остаётся в буфере обмена и целиком вставляется в сфокусированное поле при любой раскладке
actual: на английской раскладке вставка работает, на русской вместо текста появляется только строчная буква «м»; исправление 2.4.2 поведения не изменило
errors: видимого сообщения об ошибке нет
timeline: воспроизводится на 2.4.2 build 242 и на 2.4.3 build 243 после двух предыдущих исправлений
reproduction: выбрать русскую раскладку, сфокусировать поле, запустить диктовку Option, завершить запись

## Current Focus

hypothesis: confirmed — любой fallback на физический key code 9 остаётся зависимым от того, как приложение и remapper сохраняют Command state; при RussianWin потерянный Command превращает V в «м»
test: выполнен — fallback полностью заменён на прямой AXValue edit для native fields и targeted CGEvent с явным Unicode payload для остальных полей; V и Command не генерируются
expecting: confirmed в native и web integration probes — полный русский Unicode появляется в caret при фактически выбранной RussianWin и запущенном Karabiner
next_action: пользовательская проверка одной реальной диктовкой в исходном поле на установленной 2.4.4 build 244

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

- timestamp: 2026-08-13T17:34:32+03:00
  checked: пользовательская проверка установленной 2.4.3 build 243 в исходном поле
  found: проблема осталась без изменений
  implication: успешный Chrome probe не репрезентативен для исходного target; process-targeted Command-V всё ещё является раскладко-зависимой клавиатурной эмуляцией и не может быть основным исправлением

- timestamp: 2026-08-13T18:07:10+03:00
  checked: pure regressions для Unicode event payload и AXValue UTF-16 replacement
  found: 83 service checks проходят; fallback разбивает полный transcript без повреждения grapheme clusters, каждый key-down содержит исходный Unicode, все события адресованы captured PID, key code 9 и Command/Option отсутствуют; AX replacement корректно обрабатывает русский текст, emoji, selection и caret offsets
  implication: новый fallback структурно не может воспроизвести прежний путь, при котором RussianWin превращала физическую V в «м»

- timestamp: 2026-08-13T18:07:10+03:00
  checked: signed native integration probes в TextEdit
  found: прямой AXValue путь заменил selection и поставил caret после строки `До 👋 текст`; отдельный Unicode-event fallback вставил полную строку `Привет 👋 — Unicode`, подтверждённую чтением AXValue
  implication: оба новых fallback path сохраняют UTF-16 текст и позицию курсора в реальном native editable field

- timestamp: 2026-08-13T18:07:10+03:00
  checked: signed web integration probes в Chrome textarea/contenteditable при работающем Karabiner
  found: targeted Unicode events вставили `Привет 👋 — Unicode` в оба типа web editor; после фактического переключения input source на `com.apple.keylayout.RussianWin` contenteditable получил точную строку `Русский тест 👋`; input source затем восстановлен на ABC
  implication: тест охватывает проблемную раскладку и web controls, где AXValue намеренно не используется из-за риска обхода DOM input events

- timestamp: 2026-08-13T18:07:10+03:00
  checked: full 2.4.4 build
  found: прошли 244 Swift checks и 27 Chrome checks, strict compile и certificate-backed codesign
  implication: исправление собрано в подписанный release artifact без регрессий в смежных сервисах

## Eliminated

- hypothesis: явные Command-down/V-down/V-up/Command-up делают CGEvent fallback надёжным при любой пользовательской конфигурации
  evidence: пользователь воспроизвёл тот же символ «м» на 2.4.2, а активный Karabiner профиль перехватывает Command+V для ru/uk

- hypothesis: CGEventPostToPid сам по себе делает Command-V независимым от раскладки в исходном поле
  evidence: пользователь воспроизвёл прежний симптом на установленной 2.4.3; только отдельный Chrome address-field probe был успешным

## Resolution

root_cause:
  fallback 2.4.2/2.4.3 всё ещё синтезировал физическую клавишу V (key code 9). В исходном приложении пользователя Command state не доходил или интерпретировался иначе после обработки раскладки/remapper chain, поэтому RussianWin превращала событие в обычную букву «м». Адресация события конкретному PID не устранила зависимость от физической клавиши.
fix:
  Clipboard-first контракт сохранён, но физический Command-V полностью удалён. После обычного Accessibility Paste Whisper использует прямой AXValue replacement для native editable fields, а для web/terminal/остальных полей отправляет в captured PID текстовые CGEvent с явным Unicode payload. Ни V, ни Command/Option больше не генерируются. Маршрут вставки логируется без текста transcript для последующей диагностики конкретного target.
verification:
  83 service checks покрывают payload, PID, отсутствие key code 9/modifiers и UTF-16 caret semantics. Signed probes подтвердили русский текст и emoji в TextEdit, Chrome textarea/contenteditable и отдельно при реально активной RussianWin с работающим Karabiner. Полная сборка прошла 244 Swift + 27 Chrome checks и codesign. Финальная проверка исходного пользовательского поля ожидается.
files_changed:
  - Sources/WhisperApp/Services/TextInsertionService.swift
  - Sources/WhisperApp/Application/AppController.swift
  - Tests/Manual/WhisperServicesVerification.swift
  - Config/Info.plist
  - README.md
