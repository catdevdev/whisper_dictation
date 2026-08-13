---
status: resolved
trigger: "Она сейчас пишет, что-то пошло не так, не удалось прочитать ключ OpenAI из связки ключей. Без проблем, но просто эта штука не пропадает как будто. И еще есть такой нюанс: монитор ввода требует доступ, но Whisper отсутствует в списке; Accessibility включён, однако приложение продолжает считать разрешение недоступным."
created: 2026-07-21T02:52:29Z
updated: 2026-07-21T05:47:21Z
---

## Current Focus

hypothesis: confirmed — recurring Accessibility denial was caused by ad-hoc CDHash-only identities, and a pinned certificate-backed designated requirement preserves the same TCC identity across changed builds
test: install changed build 214 signed by the same certificate after granting build 213, verify both permissions remain allowed, then reinstall build 213 and verify them again without another reset or grant
expecting: both changed builds have different CDHashes but the same certificate-backed designated requirement, and Microphone plus Accessibility remain allowed after each replacement
next_action: none; retain the login-keychain identity and use only the fail-closed build and guarded installer for future updates
reasoning_checkpoint:
  hypothesis: "Ad-hoc signing is the recurring environmental root cause: each changed executable has a new CDHash-only designated requirement, so a TCC/Keychain grant made to one build cannot identify the next build as the same app."
  confirming_evidence:
    - "Installed 2.1.2 build 212 is ad-hoc signed with designated requirement cdhash fc1cce684e53e202c10392eb235127df4ad4b6e7 and no TeamIdentifier; the prior installed build used cdhash 0792f561...."
    - "TCC logs explicitly compare the saved Accessibility requirement 0792f561... with current fc1cce68... and emit Failed to match existing code requirement."
    - "security find-identity -v -p codesigning reports 0 valid identities, so the current machine cannot yet produce a certificate-backed build."
    - "scripts/build-app.sh already passes WHISPER_CODESIGN_IDENTITY to codesign but defaults it to '-', which guarantees another CDHash-only identity whenever no certificate fingerprint is supplied."
    - "Apple's code-signing documentation states that ad-hoc signatures identify exactly one signed program, while new versions signed with the same identifier and designated requirement are treated as the same program; self-signed Code Signing identities are suitable for local designated-requirement continuity."
  falsification_test: "After explicit approval, two changed binaries signed with the same selected identity and bundle identifier must expose equivalent certificate-backed designated requirements and satisfy each other's designated requirement; if they remain CDHash-only or TCC still reports a requirement mismatch after one scoped reset/re-grant, the proposed permanence mechanism is false."
  fix_rationale: "Use a single protected Code Signing identity for all installed builds and select it by certificate fingerprint via the build script's existing WHISPER_CODESIGN_IDENTITY input. After installing and verifying the first certificate-backed build, reset only Accessibility for com.nekoneki.whisper-dictation.app once and re-grant it; do not reset Microphone, Keychain, other services, or all clients."
  blind_spots: "A self-signed local identity normally has no Apple TeamIdentifier, so stability must be verified from its leaf-certificate-bound designated requirement plus bundle identifier. Certificate creation/import, private-key ACL prompts, trust changes, app replacement, Keychain authorization, and TCC reset/grant all require explicit user confirmation. Certificate loss, expiry, rotation, accidental fallback to '-', or an identifier-only custom requirement would reintroduce failure or weaken identity security."
tdd_checkpoint: null

## Symptoms

expected: Keychain error clears after a successful refresh; Whisper appears in Input Monitoring and recognizes enabled Accessibility.
actual: Keychain read error remains visible; Whisper is absent from Input Monitoring; Accessibility lists Whisper enabled but app still reports setup incomplete.
errors: "Не удалось прочитать ключ OpenAI из Связки ключей."
reproduction: Launch Whisper 2.1.0, open its control center/settings, press Allow for Input Monitoring, inspect Privacy & Security lists.
started: After the 2.1.0 rebuild and ad-hoc reinstall on 2026-07-20/21.

## Eliminated

- hypothesis: the Keychain item remains unreadable after the user authorized the rebuilt app
  evidence: unified security logs show the first read invoked SecurityAgent and updated the ACL after user approval; every subsequent SecItemCopyMatching succeeds, while the same UI failure remains visible.
  timestamp: 2026-07-21T02:58:59Z

- hypothesis: the persistent Keychain message is caused by refreshReadiness not being invoked again
  evidence: ControlCenter and Settings call refreshReadiness on appearance and save/request flows call it after completion; successful refreshes update readiness, but no success path mutates the prior failure phase.
  timestamp: 2026-07-21T02:58:59Z

## Evidence

- timestamp: 2026-07-21T02:52:29Z
  checked: user screenshots
  found: Accessibility contains enabled Whisper; Input Monitoring contains no Whisper entry.
  implication: the two permission paths fail differently and must be diagnosed independently.

- timestamp: 2026-07-21T02:54:24Z
  checked: Apple DTS guidance supplied by the parent investigation (developer.apple.com/forums/thread/828052)
  found: Accessibility authorization covers both event posting and listening; an app that already requires Accessibility does not need a separate Input Monitoring grant, and CGEventTap succeeding under Accessibility is intentional.
  implication: absence from Input Monitoring is not itself a TCC registration failure; any app readiness gate that separately requires Input Monitoring is a likely product-logic defect.

- timestamp: 2026-07-21T02:54:24Z
  checked: repository state and project-defined skill discovery
  found: the worktree is an extensive in-progress migration with tracked deletions and untracked SwiftPM sources/tests; no .codex/skills or .agents/skills directory exists.
  implication: preserve all existing changes, inspect the new SwiftPM implementation as authoritative, and apply no project-specific skill rules beyond the repository RTK command requirement.

- timestamp: 2026-07-21T02:55:54Z
  checked: complete AppController.refreshReadiness and DictationPhase transition code
  found: a Keychain exception calls showFailure with the reported Russian message, but a later successful load only assigns readiness; no success branch clears that exact failure. The message persists until clearError or another dictation phase transition.
  implication: the persistent Keychain banner is a deterministic stale-state bug independent of whether the original Keychain read error was transient.

- timestamp: 2026-07-21T02:55:54Z
  checked: AppReadiness, PermissionCenter, AppController.startOptionMonitorIfPossible, and both readiness UIs
  found: canDictate requires microphone + inputMonitoring + accessibility + key; the monitor refuses to attempt CGEvent.tapCreate unless CGPreflightListenEventAccess succeeds; the UI separately requests and displays Input Monitoring as one of three permissions.
  implication: Accessibility can be enabled and the event tap can be usable while the app remains permanently setup-incomplete solely because a redundant Input Monitoring preflight is false.

- timestamp: 2026-07-21T02:55:54Z
  checked: Package.swift and existing tests
  found: only WhisperCore has an XCTest target; service verification covers Keychain round trips but there is no AppController/readiness transition coverage.
  implication: a regression seam is needed for deterministic tests without invoking real TCC or Keychain state.

- timestamp: 2026-07-21T02:58:59Z
  checked: installed /Applications/Whisper.app and safe dist/Whisper.app signature metadata
  found: both current copies have bundle identifier com.nekoneki.whisper-dictation.app and the same current ad-hoc CDHash; their designated requirement is that CDHash, with no TeamIdentifier.
  implication: the current installed build matches the local artifact, but any changed ad-hoc rebuild changes its designated requirement and requires fresh Keychain/TCC authorization.

- timestamp: 2026-07-21T02:58:59Z
  checked: counterfactual signing experiment supplied by the parent investigation
  found: an explicit identifier-only designated requirement stays stable across changed ad-hoc CDHashes, but any local impostor using that bundle identifier could satisfy it.
  implication: identifier-only ad-hoc signing is unsafe for an app holding an API key; durable authorization identity requires a stable signing certificate, while the practical unsigned-development path is one final build followed by one reauthorization.

- timestamp: 2026-07-21T02:58:59Z
  checked: unified Security/Keychain logs supplied by the parent investigation
  found: the first SecItemCopyMatching from the rebuilt app opened SecurityAgent; after the user chose Always Allow, the ACL update completed and every subsequent read succeeded without another prompt or error.
  implication: the Keychain item and current authorization are healthy; the visible Keychain error is definitively stale application phase state and must be cleared without touching the stored secret.

- timestamp: 2026-07-21T02:58:59Z
  checked: complete failure presentation path including ControlCenter, HUD, and menu-bar presentation
  found: ControlCenter renders any DictationPhase.failure indefinitely; HUD auto-dismiss only hides the panel, and menu-bar presentation continues reflecting failure. Only clearError or an unrelated later phase transition clears it.
  implication: a successful credential read must reconcile only the matching Keychain read failure back to idle so unrelated failures are preserved.

- timestamp: 2026-07-21T02:59:34Z
  checked: baseline rtk swift test
  found: swift-package aborted before compilation because the selected /Library/Developer/CommandLineTools installation lacks SWBBuildService.framework.
  implication: this is an environment/toolchain-selection failure unrelated to the app; verification must use an explicit complete Xcode toolchain if installed.

- timestamp: 2026-07-21T03:00:29Z
  checked: xcode-select path and /Applications for Xcode installations
  found: the active developer directory is /Library/Developer/CommandLineTools and no Xcode.app or Xcode-beta.app is installed.
  implication: SwiftPM cannot be used in this environment; direct swiftc verification scripts and a manual app compile are the available safe verification paths.

- timestamp: 2026-07-21T03:01:09Z
  checked: baseline scripts/test-core.sh
  found: all 77 existing pure core checks pass under direct swiftc compilation.
  implication: the repository has a clean safe-test baseline; new failures can be attributed to the regression harness or scoped changes rather than existing core behavior.

- timestamp: 2026-07-21T03:02:31Z
  checked: pre-fix scripts/test-app-state.sh regression harness
  found: compilation fails because DictationPhase has no exact-match recovery transition; the same harness also encodes that microphone + Accessibility + key must be sufficient readiness.
  implication: the regression suite is red before the fix and directly requires the missing recovery behavior without accessing Keychain or TCC.

- timestamp: 2026-07-21T03:04:10Z
  checked: post-fix scripts/test-app-state.sh
  found: all 7 new pure state checks pass, including exact-match Keychain failure recovery, preservation of unrelated/non-failure phases, and readiness from microphone + Accessibility + key.
  implication: the targeted state transitions are green without invoking real Keychain or TCC APIs.

- timestamp: 2026-07-21T03:06:30Z
  checked: full WhisperApp direct swiftc compile to .build/manual/WhisperAppVerification
  found: every app source compiles and links successfully for arm64 macOS 14 with strict concurrency, concurrency warnings, and warnings-as-errors.
  implication: the permission API removals and controller/UI changes are internally consistent across the complete executable target.

- timestamp: 2026-07-21T03:06:30Z
  checked: final safe regression suite and static scans
  found: 77 existing core checks and 7 new app-state checks pass; no Input Monitoring API, state, request, UI copy, or documentation reference remains; bash syntax and git diff whitespace validation pass.
  implication: adjacent pure behavior remains intact, the obsolete authorization path is fully removed, and the new build hook is syntactically valid.

- timestamp: 2026-07-21T03:08:46Z
  checked: parent independent verification of the scoped checks
  found: the parent independently reproduced 7/7 app-state checks, 77/77 core checks, and the clean Input Monitoring reference scan.
  implication: automated results are repeatable outside this agent's command sequence; only signed-app macOS workflow verification remains.

- timestamp: 2026-07-21T03:11:52Z
  checked: partial human verification after final 2.1.1 installation and launch (running PID 89681)
  found: setup shows only Microphone and Accessibility, key status is `Ключ сохранён`, and the stale Keychain banner is absent after SecurityAgent Always Allow.
  implication: the installed build exhibits both intended UI/state corrections; Keychain recovery now clears the exact stale failure and the redundant Input Monitoring requirement is gone.

- timestamp: 2026-07-21T03:11:52Z
  checked: final build, signature, and current TCC state reported by the parent
  found: all 77 core, 7 state, and 59 service checks pass (143 total), codesign verification passes, and the final ad-hoc identity currently has Microphone notDetermined plus Accessibility denied.
  implication: automated and signing checks are complete; the only blocked behavioral check is Option-monitor activation, which requires the user's one-time Accessibility grant for this final ad-hoc identity.

- timestamp: 2026-07-21T03:15:09Z
  checked: post-install screenshots and read-only TCC signature-validation logs supplied by the parent
  found: System Settings visibly shows Whisper enabled for Accessibility, but the app still reports Accessibility required; the installed app has current ad-hoc CDHash `0792f561ee4aac0af45b4efabe56a8c695c54df2`, while the existing Accessibility record requires old CDHash `3c84e15...`. TCC records `SecStaticCodeCheckValidity status -67050` and `Failed to match existing code requirement` for `kTCCServiceAccessibility`; the current Microphone grant succeeded at 06:14:36 local time.
  implication: the enabled Accessibility row belongs to an older ad-hoc identity and cannot authorize the installed build. The remaining check requires an explicit user-confirmed, narrowly scoped Accessibility reset/re-grant or another safe identity-preserving remedy; no TCC, Keychain, privacy-setting, or `/Applications` mutation is authorized yet.

- timestamp: 2026-07-21T03:19:34Z
  checked: independent read-only codesign inspection, running process path, and unified TCC log around the post-install grant
  found: PID 89681 is still running `/Applications/Whisper.app`; its designated requirement is exactly ad-hoc CDHash `0792f561ee4aac0af45b4efabe56a8c695c54df2`. At 06:14:36 TCC published a new Microphone record for this bundle ID, while Accessibility preflights at 06:14:53 repeatedly compared stored CDHash `3c84e15a279ffe87ec42eb595ada2535bcd4e6f2` to current CDHash `0792f561ee4aac0af45b4efabe56a8c695c54df2` and rejected the mismatch.
  implication: Microphone is already reconciled for the final build; repeating that grant or changing the app is unnecessary. The least-invasive remaining experiment is to replace only the stale Whisper Accessibility row with the unchanged installed app, after explicit user confirmation.

- timestamp: 2026-07-21T03:20:32Z
  checked: read-only TCC log tail after the last observed Accessibility denial
  found: no later Accessibility Create/Modify event exists for `com.nekoneki.whisper-dictation.app`; the newest matching events remain the two CDHash mismatch denials at 06:14:53.
  implication: there is no evidence that the current app identity has since been granted Accessibility, so the narrow stale-row replacement checkpoint remains necessary and sufficient to test the remaining workflow.

- timestamp: 2026-07-21T03:54:59Z
  checked: human decision checkpoint response
  found: the user explicitly authorized quitting current Whisper, running only `/usr/bin/tccutil reset Accessibility com.nekoneki.whisper-dictation.app`, and relaunching the unchanged `/Applications/Whisper.app` with `--open-settings`.
  implication: the bundle-and-service-scoped Accessibility mutation may proceed; rebuilding/reinstalling, modifying `/Applications`, touching Microphone/Keychain/other TCC services, or toggling Accessibility remain outside authorization.

- timestamp: 2026-07-21T03:55:36Z
  checked: pre-reset running process, installed bundle identifier, designated requirement, and executable digest
  found: PID 89681 runs `/Applications/Whisper.app/Contents/MacOS/Whisper --open-settings`; the installed bundle ID is `com.nekoneki.whisper-dictation.app`, its designated requirement remains CDHash `0792f561ee4aac0af45b4efabe56a8c695c54df2`, and the executable SHA-256 is `2ca7a7721396232965bcb644960f1e3ba2b9ba190c2dd81ab47e931f135fbef2`.
  implication: the exact authorized target is running and the installed app identity is unchanged immediately before the reset sequence.

- timestamp: 2026-07-21T03:56:11Z
  checked: scoped termination of the pre-reset app process
  found: SIGTERM was sent only to confirmed Whisper PID 89681 and the process exited before the TCC operation.
  implication: the stale Accessibility record can now be reset without a concurrently running old process instance.

- timestamp: 2026-07-21T03:57:02Z
  checked: authorized bundle-and-service-scoped TCC reset
  found: `tccutil reset Accessibility com.nekoneki.whisper-dictation.app` exited 0 and reported successful reset for that exact service and bundle; the command emitted the identical scoped success line five times.
  implication: the stale Whisper Accessibility authorization was cleared without issuing a reset for Microphone, Keychain, another TCC service, another bundle, or all clients; repeated identical output does not expand the command scope.

- timestamp: 2026-07-21T03:57:33Z
  checked: relaunch of the unchanged installed app after reset
  found: `/Applications/Whisper.app` launched successfully as PID 12064 with command line `/Applications/Whisper.app/Contents/MacOS/Whisper --open-settings`.
  implication: post-reset verification is exercising the requested installed bundle and settings flow, not a rebuilt or alternate executable.

- timestamp: 2026-07-21T04:00:44Z
  checked: post-reset TCC identity and registration logs
  found: TCC published the bundle-scoped Accessibility delete, then validated the relaunched app's current CDHash `0792f561ee4aac0af45b4efabe56a8c695c54df2` with status 0 and created a new Accessibility record for that same requirement in the denied state pending the user's toggle.
  implication: the stale `3c84e15...` identity is no longer the active blocker; the correct unchanged app is registered and only the user-controlled enable step remains.

- timestamp: 2026-07-21T04:47:21Z
  checked: read-only Info.plist, codesign metadata, and installed designated requirement for `/Applications/Whisper.app`
  found: the installed app is now version 2.1.2 build 212; it is ad-hoc signed with CDHash and designated requirement `fc1cce684e53e202c10392eb235127df4ad4b6e7`, `Signature=adhoc`, and no TeamIdentifier.
  implication: installation of another changed ad-hoc executable invalidated the just-established 2.1.1 Accessibility identity `0792f561...`; repeatedly resetting and granting each build is a temporary workaround, not a durable fix.

- timestamp: 2026-07-21T04:47:21Z
  checked: read-only `security find-identity -v -p codesigning`
  found: the login/system search list contains `0 valid identities found` for the code-signing policy.
  implication: a stable certificate-backed build cannot be produced until the user explicitly creates or imports a suitable identity and authorizes any required private-key or trust changes; no such mutation has been performed.

- timestamp: 2026-07-21T04:47:21Z
  checked: read-only unified TCC logs for current 2.1.2 Accessibility preflights
  found: TCC repeatedly emits `Failed to match existing code requirement` while comparing saved `cdhash H"0792f561..."` to current `cdhash H"fc1cce68..."`; toggling the visible row produces Modify events but subsequent preflights still reject the identity mismatch.
  implication: the current denial is conclusively a code-identity mismatch, not a missing toggle, stale app readiness cache, or need for another broad privacy reset.

- timestamp: 2026-07-21T04:47:21Z
  checked: current `scripts/build-app.sh` signing path
  found: the script sets `SIGNING_IDENTITY="${WHISPER_CODESIGN_IDENTITY:--}"`, warns when it is `-`, and passes it to `codesign --sign`; it therefore already supports a stable certificate fingerprint without an application-source change, but silently remains ad-hoc whenever the variable is omitted.
  implication: the first permanent build can use the existing hook with a pinned identity fingerprint; later hardening should make installed/release builds fail closed rather than accidentally falling back to ad-hoc, but no script change is authorized in this checkpoint.

- timestamp: 2026-07-21T04:47:21Z
  checked: Apple Code Signing Guide sections `Understanding the Code Signature`, `Code Signing Tasks`, and `Code Signing Requirement Language` (developer.apple.com)
  found: an ad-hoc signature contains no certificate and identifies exactly one signed program; versions with the same identifier and designated requirement are treated as the same program; a Certificate Assistant self-signed Code Signing identity is suitable for local designated-requirement continuity, although it is not a Developer ID distribution identity. Apple also notes that trust settings are not consulted unless the requirement explicitly uses `anchor trusted`.
  implication: the least-privilege local remedy is a dedicated, protected Code Signing identity whose leaf certificate plus bundle identifier form the stable requirement. Do not use an identifier-only requirement, do not add blanket system trust by default, and do not treat a local identity as a distributable/notarized identity.

## Final Evidence

- timestamp: 2026-07-21T05:47:21Z
  checked: dedicated login-keychain Code Signing identity and trust scope
  found: exactly one valid identity named `Whisper Local Code Signing` exists with fingerprint `B42F0A10170956F04B0A898488A17CC27D1DA507`, validity through 2036, and only Code Signing set to Always Trust. The accidentally created unrelated `Vladislav Vkus` identity was deleted and is absent.
  implication: builds can retain one certificate-backed identity without exporting a private key, storing a keychain password, or enabling blanket certificate trust.

- timestamp: 2026-07-21T05:47:21Z
  checked: final certificate-backed builds and actual TCC continuity across changed code
  found: build 213 has CDHash `00e9150f7cbcc2aea0dfd5ce673b1d4c5b133684`; test build 214 has CDHash `d62b04f3a9bd493461a004340d4434b600fa8522`; both have the identical designated requirement `identifier "com.nekoneki.whisper-dictation.app" and certificate leaf = H"b42f0a10170956f04b0a898488a17cc27d1da507"`. After installing 213, then 214, then 213 through the final installer, both Microphone and Accessibility remained allowed after every launch without another reset or grant.
  implication: the permanent identity mechanism is confirmed by the exact counterexample that repeatedly broke ad-hoc builds: changed CDHash no longer changes the identity used by TCC.

- timestamp: 2026-07-21T05:47:21Z
  checked: fail-closed build/setup/installer and fault-injection audit
  found: all 152 deterministic checks pass; build output trees reject symlink escapes; ad-hoc signing is rejected unless explicitly enabled; an existing fingerprint cannot rotate silently; the installer rejects certificate drift and invalid bundle identifiers, uses `renamex_np(RENAME_EXCL | RENAME_NOFOLLOW_ANY)`, revalidates signatures and snapshots, rolls back failed updates, removes failed fresh installs, and preserves both backup and lock if restoration itself fails.
  implication: future normal updates cannot silently fall back to a new identity or destroy the last working app during a failed transaction.

- timestamp: 2026-07-21T05:47:21Z
  checked: final installed `/Applications/Whisper.app` after the last update round trip
  found: version 2.1.3 build 213 is strictly code-signature-valid, running from `/Applications`, and its live Settings UI reports `Ключ сохранён`, Microphone `Разрешено`, and Accessibility `Распознаёт Option и вставляет текст` with a checkmark.
  implication: the requested installed state is active now, not merely represented by a build artifact or stale System Settings row.

## Human Checkpoint

type: certificate_keychain_build_install_and_tcc_consent
status: completed
decision: the user explicitly authorized the dedicated local identity, narrowly scoped trust change, build/install migration, exact Accessibility reset, relaunch, and permission grant
completed_sequence:
  1. Created and pinned one local Code Signing identity in the login keychain without exporting its private key.
  2. Built and verified a certificate-backed app with an explicit leaf-certificate designated requirement.
  3. Quit the old process, performed the explicitly authorized one-time ad-hoc migration, and reset only Accessibility for `com.nekoneki.whisper-dictation.app`.
  4. Granted the new stable identity once and confirmed Keychain, Microphone, and Accessibility readiness.
  5. Installed a changed-CDHash update and rolled back to the official build with no permission loss.
safety_outcome: no Microphone reset, broad TCC reset, Keychain item deletion, private-key export, blanket trust, or unrelated application permission mutation was performed

## Resolution

root_cause: The application-state defects were a stale Keychain failure phase and a redundant Input Monitoring readiness gate. The recurring system-permission defect was ad-hoc signing: every changed build had a new CDHash-only designated requirement, so TCC correctly treated it as a different application even though the bundle identifier and visible Accessibility row were unchanged.
fix: Reconciled the exact stale Keychain failure, removed the redundant Input Monitoring gate, and installed a stable certificate-backed identity whose designated requirement binds the Whisper bundle identifier to one pinned leaf certificate. Hardened setup, build, and installation paths to fail closed on identity drift, symlink escapes, unsafe overlap, verification failure, and transaction failure. Performed the one-time scoped Accessibility reset and grant after the old process exited.
verification: All 152 checks pass. Strict codesign verification passes for installed 2.1.3 build 213. A real 213 → 214 → 213 update round trip changed CDHash while preserving the certificate-backed designated requirement; live UI inspection after both replacements showed the saved key, Microphone permission, and Accessibility permission remained ready without another reset or grant.
files_changed:
  - Sources/WhisperApp/Application/AppState.swift
  - Sources/WhisperApp/Application/AppController.swift
  - Sources/WhisperApp/Services/PermissionCenter.swift
  - Sources/WhisperApp/Services/GlobalOptionMonitor.swift
  - Sources/WhisperApp/UI/ControlCenterView.swift
  - Sources/WhisperApp/UI/SettingsView.swift
  - Tests/Manual/WhisperAppStateVerification.swift
  - scripts/test-app-state.sh
  - scripts/build-app.sh
  - scripts/setup-local-signing.sh
  - scripts/install-app.sh
  - scripts/rename-exclusive.c
  - Config/Info.plist
  - Config/LocalCodeSigningIdentity.sha1.example
  - .gitignore
  - README.md
