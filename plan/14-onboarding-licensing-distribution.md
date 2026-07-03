# 14. Onboarding, licence et distribution

> Rédigé le 3 juillet 2026. Conforme à `plan/01-architecture.md` (décisions A7, A11 ; module `LicensingKit` ; séquence de démarrage §4.3) et à `plan/02-data-model.md` (§6 `TrialState`, `LicenseState`, `LicenseReceipt` ; §6.1 `AppSettings`). Source de recherche : `plan/research/distribution-licensing.md` (citée ci-après « recherche D-L »). Convention : **[VÉRIFIÉ]** = adossé à une source primaire de la recherche ; **[HYPOTHÈSE — à valider]** = à confirmer en implémentation (renvoi au numéro d'hypothèse de la recherche D-L).

---

## 1. Objectif & périmètre

Ce document spécifie tout ce qui entoure le produit lui-même : la **première expérience** (fenêtre welcome guidée), le **modèle économique** (essai 48 h → licence one-time 15 $, « No subscription, ever. »), les **mises à jour** (Sparkle, checks horaires, fenêtre What's New) et la **chaîne de distribution** (signature, notarisation, DMG, appcast, CI GitHub Actions, page de téléchargement).

Sections d'`AGENTPEEK_FEATURES.md` couvertes :
- **§11 Onboarding & Licensing** en totalité : welcome guidé, choix trial/licence au premier lancement, essai 2 jours, licence 15 $ (1 licence = 1 Mac, réactivation après migration, fenêtre d'activation avec carte + champ inline, déblocage immédiat, écran d'achat à expiration sans redémarrage, anti-triche horloge, transmission limitée à clé + machine ID + version), DMG signé/notarisé sur `…/download/latest`, mises à jour Sparkle.
- **§9 Notifications** (partiel) : « prompts de mise à jour avec l'icône de l'app ; fenêtre What's New validable avec Entrée ».
- **§10 Settings → About** (partiel) : vérification de mises à jour (checks horaires, Sparkle), réglage Update.
- **§2.1** (partiel) : installation des hooks au premier lancement avec statut « Ready » — l'onboarding réutilise le moteur spécifié dans `plan/03-integration-claude-code.md` et `plan/04-integration-cursor.md` ; ici, seule l'orchestration UX est spécifiée.
- **§12 Privacy** (partiel) : réseau limité, activation ne transmettant que clé + machine ID + version.

**Décision business ouverte, architecture fermée.** `plan/00-vision-scope.md` (R8, T8) laisse ouverte la question « distribution publique payante ou privée gratuite ». Ce document spécifie l'architecture de licence **complète** (c'est le clone fidèle), mais l'isole intégralement dans `LicensingKit` derrière un unique drapeau de build (`REQ-LIC-28`) : la désactiver ne retire ni l'onboarding, ni Sparkle, ni le pipeline de release. Conséquence sur les priorités : l'onboarding est **P0** (REQ-VIS-23), tout le licensing est **P1** (REQ-VIS-27/28), la page de download **P2**.

Hors périmètre ici : le contenu des hooks installés (fichiers 03/04), l'onglet Doctor (fichier dédié), les surfaces notch/menu bar (05/06), la gestion des notifications au-delà de la demande d'autorisation (fichier dédié).

---

## 2. Exigences détaillées

### A. Onboarding (fenêtre welcome)

- **REQ-LIC-01 (P0)** — Au premier lancement (ni `TrialState`, ni reçu de licence, ni marqueur `onboardingCompleted` en UserDefaults), AgentDash affiche la fenêtre Welcome **avant** toute autre interaction : `NSWindow` régulière, centrée, activée via `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront(_:)` malgré `LSUIElement` [HYPOTHÈSE D-L n°9 — comportement à confirmer sur macOS 26]. Le notch et le status item peuvent déjà être visibles, mais aucun prompt actionnable n'est présenté tant que l'onboarding n'est pas terminé ou fermé.
- **REQ-LIC-02 (P0)** — Étape 1 « Welcome » : nom de l'app, tagline, visuel du notch, bouton `Continue` déclenchable avec Entrée (`.keyboardShortcut(.defaultAction)`). Aucune donnée demandée.
- **REQ-LIC-03 (P0)** — Étape 2 « Connect your agents » : une carte par agent (Claude Code, Cursor) avec détection à l'affichage **et re-vérifiée à chaque retour sur l'étape** : Claude Code = existence de `~/.claude/` ; Cursor = existence de `~/.cursor/` ou de l'app (`~/Applications`/`/Applications` via `NSWorkspace.urlForApplication(withBundleIdentifier:)`). États de carte : `Not detected` (avec lien d'installation web), `Detected` (bouton `Install hooks`), `Ready`.
- **REQ-LIC-04 (P0)** — Le bouton `Install hooks` appelle **le même moteur** `HooksInstaller` (protocole `DashCore`, implémentations `AgentClaude`/`AgentCursor`) que Settings → General → Agent hooks et que Doctor. Le statut ne passe à `Ready` qu'après vérification effective : ① entrées AgentDash présentes et intactes dans `~/.claude/settings.json` / `~/.cursor/hooks.json` ; ② binaire `~/.agentdash/bin/agentdash-hook` présent et de hash conforme ; ③ socket joignable (auto-ping local aller-retour). Échec → état `error` avec message court + bouton `Retry` ; jamais de blocage de la progression.
- **REQ-LIC-05 (P0)** — Étape 3 « Notifications » : écran d'explication (valeur : être prévenu des demandes d'approbation, des seuils d'usage atteints et des fins de tâche — texte canonique fixé par `12-notifications.md` §4.3) **avant** l'appel `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` [VÉRIFIÉ — bonne pratique et API]. Boutons `Enable Notifications` et `Skip`. Refus ou Skip → progression normale ; la demande reste re-proposable depuis Settings → Notifications (avec deep-link vers Réglages Système si le statut est `denied`).
- **REQ-LIC-06 (P1)** — Étape 4 « Launch at login » : toggle **désactivé par défaut** (consentement explicite requis par les guidelines Apple [VÉRIFIÉ]) ; activation via `SMAppService.mainApp.register()` ; tout affichage ultérieur de ce réglage relit l'état réel `SMAppService.mainApp.status` (jamais de cache — `AppSettings.launchAtLogin` n'est qu'une intention).
- **REQ-LIC-07 (P1)** — Étape 5 « Unlock » (visible seulement si `LICENSING_ENABLED`) : deux actions — `Start free trial` (crée le `TrialState`, ferme l'onboarding, état `.trial`) et `Enter license key` (déplie le champ de clé inline + bouton `Activate` ; une activation réussie ferme l'onboarding en état `.licensed`). Textes canoniques de `00-vision-scope.md` §4.
- **REQ-LIC-08 (P0)** — Parcours minimal ≤ 3 interactions jusqu'à la première session visible (REQ-VIS-23) : `Continue` → `Install hooks` (Claude) → `Start free trial` (ou fin d'onboarding si licensing désactivé). Chaque étape est passable (`Skip`/`Continue`), l'onboarding est fermable (⌘W / bouton de fermeture → équivaut à tout passer) et **n'est jamais le seul chemin** : chaque action est rejouable depuis Settings [VÉRIFIÉ — HIG Onboarding].
- **REQ-LIC-09 (P1)** — Consentement Sparkle intégré : case `Automatically check for updates` pré-cochée sur l'étape 5 (ou 4 si licensing désactivé) ; à la fermeture de l'onboarding, `updater.automaticallyChecksForUpdates` est réglé programmatiquement → le prompt de permission séparé de Sparkle ne s'affiche jamais [VÉRIFIÉ — mécanisme ; réglage exact à valider, recherche D-L §1.7].
- **REQ-LIC-10 (P0)** — Drapeau `LICENSING_ENABLED` à `NO` : l'étape 5 disparaît, aucun code trial/achat n'est exécuté, `onboardingCompleted` est posé à la fin de l'étape 4.

### B. Essai gratuit 48 h

- **REQ-LIC-11 (P1)** — `Start free trial` crée le `TrialState` (`02-data-model.md` §6) et le persiste en **double stockage** : Keychain (`kSecClassGenericPassword`, service `com.<org>.agentdash.license`, account `trial-state`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) **et** fichier scellé HMAC-SHA256 sous `~/Library/Application Support/` (emplacement neutre). Au lancement, **fusion pessimiste** : `trialStart` le plus ancien, `highWaterMark` et `elapsedSeconds` les plus grands ; un stockage manquant est recréé depuis l'autre (auto-réparation) ; les deux absents = essai jamais démarré.
- **REQ-LIC-12 (P1)** — Anti-rollback (la faille v0.2.9 d'AgentPeek est fermée dès la v1) : ① `highWaterMark` ne recule jamais ; ② deltas de temps mesurés via `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` (≡ `mach_continuous_time()`, court pendant le sommeil) [VÉRIFIÉ] — jamais `CLOCK_MONOTONIC` POSIX (suit les reculs d'horloge sur macOS [VÉRIFIÉ]) ; ③ accumulateur `elapsedSeconds` incrémenté uniquement par des deltas positifs ; delta négatif ⇒ ré-ancrage (traité comme un reboot). Expiration : `expired = (effectiveNow ≥ trialStart + 48 h) || (elapsedSeconds ≥ 48 h)` — le plus défavorable gagne. Test : reculer l'horloge de 24 h ne rajoute pas une seconde d'essai.
- **REQ-LIC-13 (P1)** — Trois déclencheurs de réévaluation : battement 60 s (timer mutualisé, `01-architecture.md` §5.2), timer armé sur l'échéance exacte (`trialStart + 48 h − effectiveNow`), et `NSWorkspace.didWakeNotification` (les timers ne tirent pas pendant le sommeil [VÉRIFIÉ]). Le battement persiste le `highWaterMark` et `elapsedSeconds` (écriture ≤ 1/min).
- **REQ-LIC-14 (P1)** — À expiration : bascule **immédiate et sans redémarrage** — `LicenseStore.state = .trialExpired`, le notch se verrouille (pill grisée, prompts inline désactivés, décisions relâchées vers les dialogues natifs des agents), la fenêtre d'achat s'ouvre au premier plan. Testable en réglant un essai de 2 minutes en build Debug.
- **REQ-LIC-15 (P1)** — Détection de manipulation : `wallClock < highWaterMark − 120 s` sur ≥ 3 battements consécutifs, ou HMAC invalide sur **les deux** stockages ⇒ `state = .tampered` : écran d'achat avec bandeau « System clock looks inconsistent… » ; jamais de crash ni de reset de l'essai. Tolérances : correction NTP ≤ 2 min ignorée ; fuseaux horaires sans effet (tout en temps absolu UTC).
- **REQ-LIC-16 (P2)** — Ancrage réseau opportuniste : l'en-tête HTTP `Date` des réponses **déjà** émises (appcast Sparkle, Worker de licence) est traité comme high-water mark supplémentaire ; aucune requête additionnelle n'est créée (promesse privacy intacte) [HYPOTHÈSE de conception, recherche D-L §3.2].
- **REQ-LIC-17 (P1)** — Pendant l'essai, l'app est 100 % fonctionnelle (toutes les features, sessions illimitées). Le temps restant est affiché dans Settings → About (« Free trial — 36h left ») et sur l'étape Unlock/écran d'achat ; en dessous de 12 h restantes, une **bannière in-app** « Trial ending soon » apparaît dans Settings → About et sur l'écran Unlock/achat. **Aucune notification système** n'est postée : le catalogue des `NotificationKind` est fermé (12 · REQ-NOT-07, `02-data-model.md` §5) et ce cas n'en fait pas partie.

### C. Licence one-time 15 $

- **REQ-LIC-18 (P1)** — Format de clé : chaîne délivrée par Lemon Squeezy — format UUID v4 attendu [HYPOTHÈSE D-L — format exact à confirmer à la création du produit LS]. Le champ de saisie est tolérant : trim des espaces et retours, insensible à la casse, collage multi-lignes accepté ; `Activate` actif dès que le champ est non vide ; aucune validation de forme bloquante côté client (le serveur tranche).
- **REQ-LIC-19 (P1)** — Activation en ligne : `POST <worker>/v1/activate` avec **exactement trois champs** — `license_key`, `machine_id` (= `SHA-256(IOPlatformUUID + sel applicatif)` hex, jamais l'UUID brut [VÉRIFIÉ — API IOKit publique ; politique de hachage tranchée]), `app_version`. Aucune autre donnée (vérifiable au proxy — REQ-VIS-12). Réponse : reçu `{keyHash, machineIdHash, instanceID, issuedAt, licenseVersion}` + signature Ed25519.
- **REQ-LIC-20 (P1)** — Vérification **offline-first** : à chaque lancement, la signature du reçu est vérifiée avec la clé publique Ed25519 embarquée (`Curve25519.Signing`, CryptoKit — macOS 10.15+ [VÉRIFIÉ]) et `receipt.machineIdHash` doit égaler le hash local. Le lancement n'exige **jamais** le réseau.
- **REQ-LIC-21 (P1)** — Stockage : Keychain (même service, account `license-receipt`) + copie fichier scellée HMAC (secours), conformément à `02-data-model.md` §8. La clé n'apparaît jamais en clair dans les logs ; l'UI l'affiche masquée (`••••-…-` + 4 derniers caractères).
- **REQ-LIC-22 (P1)** — Déblocage **immédiat** : pendant l'appel, le champ affiche un spinner ; en cas de succès, `state = .licensed` propage réactivement (notch déverrouillé, fenêtre d'achat fermée) sans redémarrage. Erreurs typées affichées inline sous le champ : `invalidKey`, `activationLimitReached`, `network`, `serverError`.
- **REQ-LIC-23 (P1)** — 1 licence = 1 Mac Apple Silicon : `activation_limit = 1` sur le produit LS [VÉRIFIÉ — paramètre LS]. `activationLimitReached` affiche « This key is already active on another Mac. » + lien vers le portail client LS (libérer l'ancienne machine) et l'e-mail support.
- **REQ-LIC-24 (P1)** — Réactivation/migration : bouton `Deactivate This Mac` (carte de licence) → `POST /v1/deactivate` (libère le siège LS [VÉRIFIÉ]) + effacement du reçu local → retour à l'écran d'activation. Après migration matérielle (IOPlatformUUID différent), le reçu ne vérifie plus le hash machine → l'app retombe sur l'écran d'activation (l'essai ne se ré-arme pas) ; la même clé se réactive après libération du siège — conforme à « migration matérielle peut nécessiter une réactivation ».
- **REQ-LIC-25 (P1)** — Revalidation en arrière-plan : `POST /v1/validate` tous les 7 jours (± jitter 12 h), silencieuse, uniquement si le réseau est disponible. Échec réseau → `state = .graceOffline(receipt, since:)` avec grâce de **14 jours** depuis la dernière validation réussie, sans aucune dégradation fonctionnelle pendant la grâce ; réponse `refunded`/`disabled` → `state = .revoked(reason:)` → écran d'achat avec message explicite. [HYPOTHÈSE de conception — périodes à ajuster.]
- **REQ-LIC-26 (P1)** — Fenêtre d'activation dédiée : **carte de licence** (statut, clé masquée, date d'activation, nom de machine) + **champ de clé inline** (cf. §4.3). Trois points d'entrée : étape Unlock de l'onboarding, écran d'achat (fin d'essai), Settings → About → section License.
- **REQ-LIC-27 (P1)** — Worker Cloudflare (`worker/`, TypeScript) : trois endpoints `POST /v1/{activate,validate,deactivate}` proxifiant l'API License de Lemon Squeezy (`api.lemonsqueezy.com/v1/licenses/…` [VÉRIFIÉ]) ; sans état (aucune base) ; détient en secrets la clé privée Ed25519 de licensing (**distincte** de la clé Sparkle) et, si nécessaire, la clé API LS [HYPOTHÈSE D-L n°3 — License API peut-être appelable sans clé]. Il ne journalise ni clé ni machine ID en clair.
- **REQ-LIC-28 (P0)** — **Isolation totale de LicensingKit** : un réglage de build `LICENSING_ENABLED` (xcconfig → `SWIFT_ACTIVE_COMPILATION_CONDITIONS`) contrôle l'ensemble. À `NO` : `LicenseManager` publie `.licensed` (reçu factice local, aucune vérification), aucune UI trial/achat/activation n'existe, aucune requête vers le Worker, aucun stockage Keychain licence, l'étape Unlock disparaît. Aucun autre module ne teste la licence autrement qu'en observant `LicenseStore.state` — zéro `#if LICENSING_ENABLED` hors de `LicensingKit`, `SettingsKit` et la composition root. Test : build avec le flag off → grep du binaire sans symbole d'activation, proxy sans requête Worker.
- **REQ-LIC-29 (P1)** — La licence inclut **toutes les mises à jour futures** : ni le reçu ni l'appcast ne contiennent de borne de version ; l'écran d'achat affiche « One-time purchase of $15. All current features, unlimited sessions, and every future update. No subscription, ever. »
- **REQ-LIC-30 (P2)** — Anti-abus léger côté Worker : au plus 5 cycles activate/deactivate par clé sur 30 jours glissants ; au-delà, réponse `too_many_cycles` affichée avec renvoi au support. Volontairement minimal (produit à 15 $).

### D. Mises à jour Sparkle

- **REQ-LIC-31 (P1)** — Sparkle 2 intégré via SPM, **version épinglée `exact:`** (synchronisation framework ↔ outils CLI de la CI) [VÉRIFIÉ + décision 01-architecture §2]. UI **standard** : `SPUStandardUpdaterController` instancié dans la composition root ; pas de `SPUUserDriver` custom en v1 (l'affichage d'update dans le notch est une V2 documentée).
- **REQ-LIC-32 (P1)** — Info.plist : `SUFeedURL` (HTTPS, domaine propre), `SUPublicEDKey`, `SUEnableAutomaticChecks = YES`, **`SUScheduledCheckInterval = 3600`** (plancher légitime de Sparkle = les « checks horaires » d'AgentPeek [VÉRIFIÉ]), `SUAllowsAutomaticUpdates = YES`, `SUAutomaticallyUpdate = NO` ; `CFBundleVersion` = entier **monotone croissant** (comparé par Sparkle [VÉRIFIÉ]).
- **REQ-LIC-33 (P1)** — Réglage « Update » dans Settings → About : toggle `Automatically check for updates` (relié à `updater.automaticallyChecksForUpdates`, source de vérité Sparkle, pas de cache), bouton `Check for Updates…` (activé selon `canCheckForUpdates` observé par KVO), ligne de version (`Version 0.1.0 (42)`).
- **REQ-LIC-34 (P2)** — Canal bêta : toggle `Receive beta updates` → `SPUUpdaterDelegate.allowedChannels(for:)` renvoie `["beta"]` [VÉRIFIÉ] ; un seul appcast, items bêta marqués `<sparkle:channel>beta</sparkle:channel>`.
- **REQ-LIC-35 (P1)** — Prompts de mise à jour avec l'**icône de l'app** : l'`AppIcon` du bundle est complet (toutes tailles) ; l'UI standard de Sparkle l'affiche dans ses fenêtres — vérifié visuellement à chaque release.
- **REQ-LIC-36 (P1)** — Fenêtre **What's New** post-update (fonction maison, pas Sparkle [VÉRIFIÉ — aucune API dédiée]) : au lancement, si `CFBundleShortVersionString ≠ AppSettings.lastWhatsNewVersion` **et** que ce n'est pas le premier lancement, afficher la fenêtre avec la section du `CHANGELOG.md` embarqué correspondant à la version courante (rendu Markdown natif) ; bouton `Continue` par défaut, **validable avec Entrée** ; à la fermeture, `lastWhatsNewVersion` est mis à jour. Si la section est introuvable, la fenêtre ne s'affiche pas (marqueur mis à jour silencieusement).
- **REQ-LIC-37 (P1)** — `CHANGELOG.md` du repo = **source unique** des notes de version : la CI en extrait la section de la version pour ① le fichier `.md` homonyme du DMG consommé par `generate_appcast` (notes pré-update, Markdown supporté depuis Sparkle 2.9 / macOS 12+ [VÉRIFIÉ]) et ② la ressource embarquée dans le bundle (What's New post-update).
- **REQ-LIC-38 (P2)** — Chaque item d'appcast porte `<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>` ; le rollout progressif (`sparkle:phasedRolloutInterval`) reste désactivé par défaut.

### E. Pipeline de release

- **REQ-LIC-39 (P1)** — Signature : `xcodebuild archive` + `-exportArchive` avec `ExportOptions.plist` (`method: developer-id`) — signe l'app, le framework Sparkle et ses XPC, **et** `agentdash-hook` embarqué dans `Contents/Helpers/` [VÉRIFIÉ — voie recommandée]. Hardened runtime + `--timestamp` actifs, `com.apple.security.get-task-allow` absent en Release, aucune exception d'entitlement attendue [HYPOTHÈSE D-L §2.1]. Vérification : `codesign --verify --deep --strict --verbose=2`.
- **REQ-LIC-40 (P1)** — Séquence stricte (l'EdDSA signe l'octet-stream exact ; `stapler` modifie le fichier [HYPOTHÈSE raisonnée D-L n°11]) : ① export + signature app → ② `ditto` zip + `notarytool submit --wait` de l'**app** → ③ `stapler staple` app → ④ `create-dmg` avec l'app staplée → ⑤ `codesign` du DMG → ⑥ notarisation du DMG → ⑦ `stapler staple` DMG → ⑧ `generate_appcast` **en dernier**.
- **REQ-LIC-41 (P1)** — DMG via `create-dmg` (Homebrew) : `--volname "AgentDash"`, fenêtre 540 × 380, icône app à (140, 180), `--app-drop-link` à (400, 180) (glisser vers Applications), fond `assets/dmg-background.png` ; nommage `AgentDash-<version>.dmg`.
- **REQ-LIC-42 (P1)** — Appcast : `generate_appcast --ed-key-file <secret CI> --download-url-prefix "https://github.com/<org>/agentdash/releases/download/v<version>/" updates/` ; le dossier `updates/` contient les N dernières releases (retéléchargées par la CI) pour produire les **deltas** [VÉRIFIÉ] ; l'appcast généré est déployé sur le domaine (Cloudflare Pages).
- **REQ-LIC-43 (P1)** — Workflow GitHub Actions `release.yml` : déclenché par tag `v*`, `runs-on: macos-26` (épinglé, GA février 2026 [VÉRIFIÉ]) ; secrets : `MACOS_CERTIFICATE` (p12 base64), `MACOS_CERTIFICATE_PWD`, `MACOS_CERTIFICATE_NAME`, `KEYCHAIN_PWD`, `ASC_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY` ; keychain temporaire + `security set-key-partition-list` (indispensable en headless [VÉRIFIÉ]) ; publication `gh release create` + déploiement appcast/site via wrangler ; la clé privée écrite en fichier temporaire est supprimée dans le même step.
- **REQ-LIC-44 (P1)** — Gestion des clés : paire Sparkle générée une fois (`generate_keys`), clé privée exportée (`generate_keys -x`) vers le secret CI + sauvegarde froide (gestionnaire de mots de passe) — **sa perte casse la chaîne de mise à jour** [VÉRIFIÉ] ; clé publique figée dans l'Info.plist. Clé Ed25519 de licensing distincte, vivant uniquement dans les secrets du Worker ; sa clé publique embarquée dans `LicensingKit`. Aucune clé privée dans le repo.
- **REQ-LIC-45 (P2)** — Checklist de release incluant un test de bout en bout de la chaîne : installer la version N−1, servir l'appcast de N (stagé), vérifier proposition, téléchargement, signature EdDSA, installation, relance, What's New.
- **REQ-LIC-46 (P1)** — Versionnage : `CFBundleShortVersionString` SemVer `0.x.y` (roadmap `00-vision-scope.md`), `CFBundleVersion` compteur entier incrémenté à chaque build de release ; script `scripts/bump-version.sh` mettant à jour les deux + la section `CHANGELOG.md`.

### F. Page de téléchargement

- **REQ-LIC-47 (P2)** — Site statique (Cloudflare Pages, domaine custom) : bouton `Download for Mac`, prérequis affichés (« Apple Silicon · macOS 14+ »), consigne d'installation (« Drag AgentDash to Applications »), lien checkout Lemon Squeezy (15 $), changelog public, politique privacy (zéro analytics sur le site également).
- **REQ-LIC-48 (P2)** — `https://<domaine>/download/latest` répond en 302 vers le DMG de la dernière release (règle `_redirects` Cloudflare vers `github.com/<org>/agentdash/releases/latest/download/AgentDash.dmg` — la CI publie un asset au nom **constant** `AgentDash.dmg` en plus du DMG versionné) [HYPOTHÈSE D-L n°12 — stabilité des URL d'assets à vérifier].
- **REQ-LIC-49 (P2)** — `appcast.xml` est servi depuis **notre domaine** (jamais une URL GitHub) : `SUFeedURL` étant figée dans chaque binaire distribué, l'hébergeur des DMG peut changer sans casser les mises à jour [VÉRIFIÉ — raisonnement D-L §2.5].
- **REQ-LIC-50 (P2)** — Le site (REQ-LIC-47) héberge une **documentation utilisateur** en trois sections — Install, Configure, Troubleshoot (parité changelog v0.1.8 d'AGENTPEEK_FEATURES.md §13) — plus une page **FAQ** consolidant les limitations documentées par les autres fichiers du plan : usage Cursor « best effort » (04 §7), status item masqué par macOS (06 §5, cas 4), serveurs root invisibles (10 §5, cas 8), coexistence de hooks tiers type AgentPeek (13 · REQ-SET-63), désinstallation propre. Les liens Documentation de Settings → About (13 · REQ-SET-68) et les remèdes Doctor comportant un lien documentation pointent vers ces pages. Test : chaque renvoi « FAQ »/« documentation » des fichiers 04/06/10/13 résout vers une page existante du site.

---

## 3. Conception technique

### 3.1 LicensingKit — API publiques

```swift
// Horloge injectable (tests de rollback, sommeil, reboot — 01-architecture §9)
public protocol ClockProvider: Sendable {
    var wallClock: Date { get }
    /// clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) — insensible au wall clock, court pendant le sommeil.
    var continuousNanos: UInt64 { get }
}
public struct SystemClock: ClockProvider { /* impl Darwin */ }

public enum MachineIdentity {
    /// SHA-256(IOPlatformUUID + sel applicatif), hex minuscule. nil si IORegistry inaccessible (jamais observé).
    public static func machineIdHash() -> String?
}

/// Store observé par toute l'app (alias LicenseStore dans 01-architecture).
@MainActor @Observable
public final class LicenseManager {
    public private(set) var state: LicenseState          // 02-data-model §6
    public private(set) var trialRemaining: TimeInterval? // pour l'UI (About, écran d'achat)

    public init(clock: ClockProvider, store: SecureStateStore,
                client: ActivationClient?, appVersion: String)

    public func load()                                   // étape 1 du démarrage (01-architecture §4.3)
    public func startTrial()
    public func activate(key: String) async -> ActivationResult
    public func deactivateThisMac() async throws
    public func heartbeat()                              // 60 s + didWake + échéance exacte
    public func noteServerDate(_ date: Date)             // en-tête HTTP Date opportuniste (REQ-LIC-16)
}

public enum ActivationResult: Sendable {
    case success
    case invalidKey
    case activationLimitReached
    case tooManyCycles
    case network(underlying: String)
    case serverError(status: Int)
}

/// Double stockage scellé — interne au package, protocolisé pour les tests.
public protocol SecureStateStore: Sendable {
    func readTrial() -> (keychain: TrialState?, file: TrialState?)
    func writeTrial(_ state: TrialState) throws          // écrit les DEUX emplacements
    func readReceipt() -> (keychain: StoredReceipt?, file: StoredReceipt?)
    func writeReceipt(_ receipt: StoredReceipt) throws
    func eraseReceipt()
}
public struct StoredReceipt: Codable, Sendable {
    public var receipt: LicenseReceipt                   // 02-data-model §6
    public var licenseKey: String                        // nécessaire pour validate/deactivate
    public var lastValidatedAt: Date
}

/// Client du Worker — URLSession éphémère, timeout 15 s, aucune donnée hors contrat.
public struct ActivationClient: Sendable {
    public let baseURL: URL                              // https://license.<domaine>/v1
    public func activate(key: String, machineID: String, appVersion: String)
        async throws -> (LicenseReceipt, rawSignedPayload: Data)
    public func validate(key: String, instanceID: String, machineID: String,
                         appVersion: String) async throws -> ValidationOutcome
    public func deactivate(key: String, instanceID: String) async throws
}
public enum ValidationOutcome: Sendable { case valid(refreshed: LicenseReceipt, Data), revoked(reason: String) }
```

Vérification offline du reçu (`load()` et à chaque revalidation) :

```swift
let pub = try Curve25519.Signing.PublicKey(rawRepresentation: LicensingKeys.publicKey)
guard pub.isValidSignature(receipt.signature, for: receipt.canonicalBytes),
      receipt.machineIdHash == MachineIdentity.machineIdHash()
else { /* reçu invalide → écran d'activation, jamais de crash */ }
```

### 3.2 Algorithme du trial (pseudo-code du battement)

```
heartbeat():
  nowWall  = clock.wallClock
  nowMono  = clock.continuousNanos
  deltaMono = nowMono − lastMono                    // lastMono ré-ancré au lancement et après delta < 0
  if deltaMono < 0:  ré-ancrer (reboot / anomalie CLOCK_UPTIME_RAW signalée — D-L §3.2) ; deltaMono = 0
  state.elapsedSeconds += deltaMono / 1e9           // ne peut que croître

  if nowWall > state.highWaterMark:
      state.highWaterMark = nowWall                 // avance normale
      rollbackStrikes = 0
  else if nowWall < state.highWaterMark − 120 s:
      rollbackStrikes += 1                          // horloge reculée : on ne recrédite RIEN
      if rollbackStrikes ≥ 3: publier .tampered
  effectiveNow = max(nowWall, state.highWaterMark)  // + delta monotone depuis la dernière persistance

  persist(state)                                    // Keychain + fichier, ≤ 1 écriture/min
  if effectiveNow ≥ trialStart + 48 h || state.elapsedSeconds ≥ 48 h × 3600:
      publier .trialExpired                         // → notch verrouillé + fenêtre d'achat, même tick
```

### 3.3 Séquence d'activation

```
Utilisateur          LicenseManager        ActivationClient        Worker CF              Lemon Squeezy
   │ saisit clé            │                      │                    │                        │
   │──Activate────────────►│                      │                    │                        │
   │                       │─activate(key,mid,v)─►│──POST /v1/activate►│                        │
   │   spinner inline      │                      │                    │─POST licenses/activate►│
   │                       │                      │                    │  (key, instance_name   │
   │                       │                      │                    │        = mid)          │
   │                       │                      │                    │◄──ok + instance_id─────│
   │                       │                      │                    │ signe reçu Ed25519     │
   │                       │                      │◄─{receipt,sig,id}──│                        │
   │                       │ vérifie sig + mid    │                    │                        │
   │                       │ writeReceipt (KC+fichier)                 │                        │
   │◄──state = .licensed───│  → notch déverrouillé, fenêtre fermée — AUCUN redémarrage          │
```

Échecs : LS `invalid`/`expired` → `.invalidKey` ; limite atteinte → `.activationLimitReached` ; timeout/DNS → `.network` (l'état courant — trial ou trialExpired — est conservé, message inline « Couldn't reach the activation server. Check your connection and try again. »).

### 3.4 Onboarding — coordination

```swift
public enum OnboardingStep: Int, CaseIterable { case welcome, agents, notifications, launchAtLogin, unlock }

@MainActor @Observable
public final class OnboardingCoordinator {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var cards: [AgentSetupCard]      // Claude Code, Cursor
    public var isLicensingEnabled: Bool                  // masque .unlock si false

    public func advance() ; public func skip()
    public func refreshDetection()                       // ré-évaluée à chaque affichage de .agents
    public func installHooks(for agent: AgentKind) async // HooksInstaller + vérification Ready (REQ-LIC-04)
    public func requestNotifications() async -> Bool     // UNUserNotificationCenter
    public func setLaunchAtLogin(_ on: Bool)             // SMAppService.mainApp.register()/unregister()
    public func finish()                                 // pose onboardingCompleted, applique le consentement Sparkle
}

public struct AgentSetupCard: Identifiable, Sendable {
    public var id: AgentKind
    public var detection: AgentDetection                 // .installed(path:) / .notDetected
    public var hookStatus: HookSetupStatus               // .notInstalled / .installing / .ready / .error(String)
}
```

La vérification « Ready » enchaîne trois checks asynchrones (fichier de config relu et parsé, hash du binaire copié, auto-ping du socket) — les mêmes primitives que le Doctor, exposées par `DoctorKit`/`DashCore`, jamais dupliquées.

### 3.5 Sparkle — intégration

```swift
@MainActor
final class UpdaterCoordinator: NSObject, SPUUpdaterDelegate {
    let controller: SPUStandardUpdaterController         // startingUpdater: true
    var updater: SPUUpdater { controller.updater }

    init(settings: SettingsStore) {
        // updaterDelegate = self (canaux) ; userDriverDelegate = nil (UI standard, icône du bundle)
    }
    func checkForUpdates() { controller.checkForUpdates(nil) }   // bouton About
    // canCheckForUpdates observé par KVO → état du bouton
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        settings.betaChannel ? ["beta"] : []             // REQ-LIC-34 [VÉRIFIÉ]
    }
}
```

What's New : `WhatsNewPresenter.sectionMarkdown(for: version, in: bundledChangelog) -> AttributedString?` — parsing des titres `## v<version>` du `CHANGELOG.md` embarqué ; présentation dans une `NSWindow` SwiftUI ; `Button("Continue").keyboardShortcut(.defaultAction)`.

### 3.6 Pipeline — scripts

`scripts/release.sh` (exécutable localement et par la CI, mêmes étapes ①–⑧ que REQ-LIC-40) ; `scripts/make-dmg.sh` (create-dmg + codesign) ; `scripts/notarize.sh` (notarytool + stapler + `notarytool log` sur échec) ; `scripts/extract-changelog.sh <version>` (section Markdown → notes appcast + ressource bundle) ; `ci/ExportOptions.plist` (`method: developer-id`, `teamID`). Le workflow `ci/release.yml` orchestre : checkout → import certificat (keychain temporaire) → `release.sh` → `gh release create v<version> AgentDash-<version>.dmg AgentDash.dmg --notes-file relnotes.md` → wrangler deploy (site + appcast).

---

## 4. Spécification UX/UI

Tous les textes d'interface en anglais (fidèles à AgentPeek quand connus — textes canoniques `00-vision-scope.md` §4 ; le reste est notre rédaction, cohérente avec le ton du produit).

### 4.1 Fenêtre Welcome (onboarding)

Fenêtre 640 × 480 pt, non redimensionnable, centrée, fond `agentGlass()`. Indicateur de progression discret (points) en bas ; navigation `Continue` (défaut, Entrée) / `Skip` (texte, discret) ; bouton retour chevron dès l'étape 2.

| Étape | Contenu | Textes exacts |
|---|---|---|
| 1. Welcome | icône app, visuel du pill animé | « **Welcome to AgentDash** » · « Your coding agents, in the Mac notch. » · `Continue` |
| 2. Agents | 2 cartes verticales (icône agent, nom, statut, action) | « **Connect your agents** » · carte : « Claude Code » / « Cursor » ; statuts : « Not detected » (+ lien « How to install ») · « Detected » + bouton `Install hooks` · badge vert « **Ready** » ; erreur : « Couldn't update ~/.claude/settings.json » + `Retry` |
| 3. Notifications | illustration notification permission | « **Stay in the loop** » · « Get notified when an agent needs your approval, hits a usage threshold, or finishes a task. » (texte canonique — `12-notifications.md` §4.3) · `Enable Notifications` (défaut) · `Skip` |
| 4. Launch at login | toggle unique | « **Start AgentDash automatically?** » · toggle « Launch at login » (off) · `Continue` |
| 5. Unlock (si licensing) | deux options empilées + case update | « **Try AgentDash free for 2 days** » · bouton principal `Start free trial` · « No credit card. All features included. » · lien `Enter license key` → champ inline + `Activate` · case cochée « Automatically check for updates » |

États du bouton `Install hooks` : normal → `Installing…` (spinner) → remplacé par le badge `Ready` (vert, animation de fondu 200 ms). La carte `Not detected` est grisée, sans bouton.

### 4.2 Écran d'achat (fin d'essai — REQ-LIC-14)

Fenêtre modale 480 × 420 pt, ouverte automatiquement à l'expiration ; ré-ouvrable via la pill grisée (clic) et Settings → About.

- Titre : « **Your free trial has ended** » (ou « **Get AgentDash** » si ouvert avant expiration).
- Sous-titre : « One-time purchase of $15. All current features, unlimited sessions, and every future update. **No subscription, ever.** »
- Bouton principal : `Buy AgentDash — $15` → ouvre l'URL de checkout Lemon Squeezy dans le navigateur.
- Dessous : « Already purchased? » + champ de clé inline + `Activate` (mêmes comportements que §4.3).
- État `.tampered` : bandeau ambre « System clock looks inconsistent. Your trial has been paused — enter a license key to continue. »
- Notch pendant `trialExpired` : pill grisée (désaturée, opacité 0,6), tooltip « Trial ended — click to unlock » ; aucun prompt inline (fail-open vers les dialogues natifs des agents).

### 4.3 Fenêtre d'activation et carte de licence

- **Non activé** : champ « License key » (monospace, placeholder `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`), bouton `Activate` avec spinner intégré ; erreurs inline en rouge sous le champ : « This license key is invalid. » / « This key is already active on another Mac. » (+ lien « Manage activations ») / « Couldn't reach the activation server. Check your connection and try again. »
- **Activé — carte de licence** (aussi affichée dans Settings → About) : coche verte + « **Licensed** — Thanks for supporting AgentDash! » · « Key ••••-…-4F2A » · « Activated Jun 12, 2026 on this Mac » · bouton secondaire `Deactivate This Mac` avec confirmation (« This frees the license for another Mac. AgentDash will lock until a key is entered. » `Cancel` / `Deactivate`).
- **Grâce hors ligne** : ligne discrète « Offline — license valid, will revalidate when online. » ; **révoquée** : la carte redevient champ de saisie avec « This license was refunded or disabled. »
- Déblocage immédiat : à la réussite, la carte remplace le champ avec une animation de flip léger (250 ms) — aucune relance d'app.

### 4.4 Update et What's New

- Settings → About, section « Updates » : « Version 0.1.0 (42) » · toggle « Automatically check for updates » (checks horaires — libellé d'aide « Checks hourly. ») · toggle « Receive beta updates » (P2) · bouton `Check for Updates…`.
- Prompts Sparkle : UI standard, icône AgentDash visible (REQ-LIC-35).
- Fenêtre What's New : 460 × 520 pt, titre « **What's New in AgentDash** », sous-titre « Version 0.2.0 », corps Markdown scrollable, bouton unique `Continue` (défaut → **Entrée la valide**).

### 4.5 Page de download (P2)

Une page : hero (« Your coding agents, in the Mac notch. »), bouton `Download for Mac` (→ `/download/latest`), « Requires an Apple Silicon Mac running macOS 14 or later. », étape d'installation illustrée (drag vers Applications), prix (« $15, one-time. Free 2-day trial included. »), lien changelog, mention privacy (« No account. No analytics. Everything stays on your Mac. »).

---

## 5. Cas limites & gestion d'erreurs

| # | Cas | Comportement spécifié |
|---|---|---|
| 1 | Recul d'horloge (heure, jour, an) | `effectiveNow` ne recule jamais ; 3 battements incohérents → `.tampered` ; jamais de temps recrédité (REQ-LIC-12/15) |
| 2 | Avance d'horloge puis retour | l'avance consume l'essai (HWM avancé) — assumé, jamais exploitable dans l'autre sens ; documenté support |
| 3 | Sommeil pendant l'essai | `mach_continuous_time` court pendant le sommeil [VÉRIFIÉ] → le temps réel est bien décompté ; réévaluation à `didWakeNotification` |
| 4 | Reboot | ancres monotones remises à zéro → ré-ancrage au lancement (delta 0, jamais négatif persisté) |
| 5 | Delta monotone négatif (anomalie basse batterie signalée D-L) | traité comme reboot : ré-ancrage, aucun crédit ni débit |
| 6 | Suppression app + réinstallation pendant l'essai | l'item Keychain survit [VÉRIFIÉ] → essai repris où il en était ; fichier recréé (auto-réparation) |
| 7 | Keychain purgé mais fichier présent (ou l'inverse) | fusion pessimiste : l'état survivant fait foi, l'autre est recréé (REQ-LIC-11) |
| 8 | Les deux stockages effacés | essai réputé jamais démarré — contournement possible par effacement complet, assumé (coût > public visé ; identique aux apps indie du marché) |
| 9 | Accès Keychain refusé/prompté [HYPOTHÈSE D-L n°5] | repli sur le fichier seul + signal Doctor « licensing storage degraded » ; à re-tester entre builds Debug/Release |
| 10 | Restauration Time Machine / Migration Assistant | `trialStart` restauré ancien → essai au pire paraît expiré (jamais rallongé) ; licence : hash machine différent → écran d'activation + réactivation (REQ-LIC-24) |
| 11 | Activation sans réseau / Worker down | erreur `.network` inline, état conservé ; aucune file d'attente automatique (l'utilisateur réessaie) |
| 12 | Clé invalide / remboursée / désactivée | `.invalidKey` inline ; si déjà activée localement, la revalidation qui découvre `refunded/disabled` → `.revoked` avec message (REQ-LIC-25) |
| 13 | Limite d'activation atteinte | message + lien portail LS ; désactivation d'instance orpheline via portail ou support [HYPOTHÈSE D-L n°13 — suppression manuelle d'instance dans le dashboard LS à vérifier] |
| 14 | Reçu corrompu / signature invalide au lancement | retour à l'écran d'activation avec la clé pré-remplie si connue ; log `licensing` ; jamais de crash |
| 15 | Revalidation impossible > 14 j (`graceOffline` échue) | passage à l'écran d'activation avec message doux (« Please reconnect once to revalidate your license. ») — pas de punition brutale, décision produit |
| 16 | Machine sans IOPlatformUUID lisible | jamais observé ; si `machineIdHash() == nil` → licensing désactivé de fait (état `.licensed` refusé, trial autorisé), signal Doctor |
| 17 | Double lancement de l'app pendant l'onboarding | second process quitte immédiatement (singleton par socket déjà lié — mécanisme 01-architecture) ; l'onboarding n'est jamais dupliqué |
| 18 | Onboarding fermé prématurément | équivaut à tout passer ; au prochain lancement, si ni trial ni licence (et licensing actif) → retour direct sur l'étape Unlock uniquement |
| 19 | `requestAuthorization` sans fenêtre au premier plan (LSUIElement) | l'onboarding active l'app avant l'appel ; à valider sur macOS 26 [HYPOTHÈSE D-L n°9] ; si le prompt n'apparaît pas, bouton Settings → Notifications avec deep-link |
| 20 | Hooks : fichier de config en lecture seule / JSON invalide | erreur inline sur la carte + renvoi Doctor ; jamais d'écrasement destructif (fusion + `.bak`, 01-architecture §8.5) |
| 21 | Appcast inaccessible / TLS invalide | Sparkle échoue silencieusement en check automatique ; check manuel → alerte standard Sparkle ; aucune dégradation app |
| 22 | Signature EdDSA d'une update invalide | Sparkle refuse l'installation [VÉRIFIÉ — conception Sparkle] ; consigne : ne jamais modifier un DMG après `generate_appcast` (REQ-LIC-40) |
| 23 | `CFBundleVersion` non incrémenté par erreur | l'update n'est pas proposée — garde-fou CI : le workflow échoue si la version du tag ≤ dernière release |
| 24 | What's New sans section changelog correspondante | fenêtre non affichée, marqueur mis à jour (REQ-LIC-36) |
| 25 | Utilisateur sous proxy/pare-feu bloquant le Worker uniquement | trial et fonctions locales intactes ; activation impossible → message `.network` ; revalidation en grâce |
| 26 | Fuseau horaire / passage à l'heure d'été | aucun effet (temps absolu UTC partout, REQ-LIC-15) |
| 27 | Licensing désactivé (`LICENSING_ENABLED = NO`) | aucun état, aucune requête, aucune UI ; l'app se comporte comme licenciée à vie (REQ-LIC-28) |

---

## 6. Critères d'acceptation

1. **Onboarding minimal** — Given un Mac vierge avec Claude Code installé, When l'utilisateur monte le DMG, lance l'app et suit `Continue` → `Install hooks` → `Start free trial`, Then les hooks Claude affichent `Ready`, une session Claude lancée ensuite apparaît dans le notch, et le tout a nécessité ≤ 3 interactions (REQ-VIS-23).
2. **Ready véridique** — Given l'étape Agents, When l'utilisateur clique `Install hooks` alors que `~/.claude/settings.json` est en lecture seule, Then la carte affiche une erreur avec `Retry` (jamais `Ready`), et le fichier n'a pas été modifié.
3. **Notifications en contexte** — Given l'étape 3, When l'utilisateur clique `Enable Notifications`, Then le prompt système apparaît ; When il choisit « Don't Allow » puis `Continue`, Then l'onboarding se termine normalement et Settings → Notifications propose le deep-link Réglages Système.
4. **Anti-rollback** — Given un essai démarré depuis 47 h, When l'utilisateur recule l'horloge système de 24 h et relance l'app, Then le temps restant affiché est ≤ 1 h (jamais 25 h) ; When il attend 1 h de temps réel, Then l'écran d'achat s'ouvre sans redémarrage et la pill se grise.
5. **Rollback répété** — Given l'app ouverte, When l'horloge est reculée de 2 h et que 3 battements s'écoulent, Then l'état devient `tampered` et l'écran d'achat affiche le bandeau d'horloge incohérente.
6. **Activation immédiate** — Given l'écran d'achat après expiration, When une clé valide est collée (avec espaces parasites) et `Activate` cliqué, Then l'état passe à `licensed` en une seule requête, le notch se déverrouille dans la seconde, sans relance de l'app.
7. **Contrat de confidentialité** — Given un proxy d'inspection, When une activation puis une revalidation s'exécutent, Then les seules données sortantes vers le Worker sont `license_key`, `machine_id` (64 hex, ≠ IOPlatformUUID brut) et `app_version`.
8. **1 licence = 1 Mac** — Given une clé activée sur le Mac A, When elle est saisie sur le Mac B, Then « This key is already active on another Mac. » ; When `Deactivate This Mac` est exécuté sur A puis la clé saisie sur B, Then B s'active et A retombe sur l'écran d'activation à son prochain lancement en ligne.
9. **Offline-first** — Given un Mac licencié hors ligne depuis 10 jours, When l'app se lance, Then elle démarre licenciée (vérification Ed25519 locale) sans aucune requête ni délai réseau.
10. **Update horaire** — Given l'app installée en version N−1 et un appcast servant N, When l'app reste ouverte, Then une proposition de mise à jour (avec l'icône AgentDash) apparaît dans l'heure ; When l'utilisateur installe, Then l'app relance en N et la fenêtre What's New s'affiche, fermable d'un simple appui sur Entrée ; au lancement suivant, elle ne réapparaît pas.
11. **Gatekeeper** — Given le DMG produit par la CI, When il est ouvert sur un Mac vierge (macOS 14, hors ligne après téléchargement), Then l'app s'ouvre sans avertissement ni clic droit (`spctl --assess` accepté, tickets staplés app + DMG).
12. **Kill switch business** — Given une build avec `LICENSING_ENABLED = NO`, When on parcourt onboarding, Settings et le trafic réseau, Then aucune UI trial/licence n'existe, aucune requête n'atteint le Worker, et toutes les features sont débloquées.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances amont** : `plan/01-architecture.md` (A7 Developer ID/notarisation/Sparkle 3600 s ; A11 LS + Worker + Ed25519 + trial anti-rollback ; §4.3 `LicenseManager.load()` en première étape du démarrage ; §3 modules `LicensingKit`/`SettingsKit`) ; `plan/02-data-model.md` (§6 types `TrialState`/`LicenseState`/`LicenseReceipt`, §6.1 `AppSettings.automaticUpdateChecks`/`betaChannel`/`lastWhatsNewVersion`, §8 persistance) ; `plan/00-vision-scope.md` (REQ-VIS-12/23/27/28, textes canoniques, risque R8/tâche T8) ; `plan/research/distribution-licensing.md` (toutes les hypothèses n°1–14).

**Dépendances croisées** : `plan/03-integration-claude-code.md` / `plan/04-integration-cursor.md` (moteur `HooksInstaller` et vérification « Ready » réutilisés par l'onboarding) ; `plan/05-notch-ui.md` (état verrouillé de la pill à `trialExpired`) ; `plan/12-notifications.md` (re-demande de permission notifications, texte canonique de l'étape « Stay in the loop ») et `plan/13-settings.md` (onglet About, section License, Doctor et checks de santé du licensing, liens documentation).

| Risque | Prob. | Impact | Mitigation |
|---|---|---|---|
| Lemon Squeezy ferme les inscriptions pendant la bascule Stripe Managed Payments (D-L n°4) | Moyenne | Moyen | Plan B documenté : Paddle + Keygen ; l'app ne parle qu'au Worker → seule la face LS du Worker change |
| Perte de la clé privée Sparkle | Faible | **Critique** | export `-x` + secret CI + sauvegarde froide (REQ-LIC-44) ; procédure écrite dans `ci/README` |
| Keychain non silencieux après réinstallation (D-L n°5) | Moyenne | Faible | double stockage : le fichier prend le relais ; banc de test Debug/Release avant la release publique |
| Prompt notifications absent en LSUIElement sur macOS 26 (D-L n°9) | Faible | Moyen | activation explicite de l'app avant l'appel + fallback deep-link Réglages Système |
| `stapler` après signature EdDSA casse l'update (D-L n°11) | Faible | Élevé | ordre ①–⑧ verrouillé dans `release.sh` + test E2E de chaîne (REQ-LIC-45) |
| Format/appel de la License API LS sans clé (D-L n°3) | Moyenne | Faible | la clé API vit dans le Worker de toute façon ; aucun impact app |
| Décision business « gratuit » tardive | Moyenne | Faible | REQ-LIC-28 : tout le licensing est retirable par un flag sans toucher au reste (aligné R8/T8 de la vision) |
| URLs d'assets GitHub instables pour `/download/latest` (D-L n°12) | Faible | Faible | asset au nom constant + redirection sous notre domaine, modifiable sans re-release |

---

## 8. Découpage en tâches

| # | Tâche | Taille | Priorité |
|---|---|---|---|
| T1 | `OnboardingCoordinator` + fenêtre Welcome (étapes 1–4, navigation, détection agents) | **M** | P0 |
| T2 | Branchement `Install hooks` → `HooksInstaller` + vérification `Ready` (3 checks) + états d'erreur | **M** | P0 |
| T3 | Étape Notifications (`requestAuthorization` en contexte) + relais Settings/deep-link | **S** | P0 |
| T4 | Flag `LICENSING_ENABLED` (xcconfig), `LicenseManager` factice en mode off, câblage `LicenseStore` | **S** | P0 |
| T5 | `SecureStateStore` (Keychain + fichier HMAC, fusion pessimiste, auto-réparation) + tests | **M** | P1 |
| T6 | Trial : `ClockProvider`, battement anti-rollback, échéance exacte, `didWake`, états `trialExpired`/`tampered` + tests d'horloge simulée (rollback, sommeil, reboot) | **L** | P1 |
| T7 | `MachineIdentity` (IOPlatformUUID + SHA-256) + banc migration/réinstallation (hypothèses D-L n°5–6) | **S** | P1 |
| T8 | Worker Cloudflare (`/v1/activate`, `/validate`, `/deactivate`, signature Ed25519, secrets) + produit LS (`activation_limit = 1`, checkout) | **L** | P1 |
| T9 | `ActivationClient` + vérification offline du reçu + revalidation 7 j/grâce 14 j + `Deactivate This Mac` | **M** | P1 |
| T10 | UI : étape Unlock, écran d'achat, fenêtre d'activation/carte de licence, verrouillage de la pill | **M** | P1 |
| T11 | Intégration Sparkle (SPM épinglé, Info.plist, `UpdaterCoordinator`, section Update d'About, consentement onboarding) | **M** | P1 |
| T12 | Fenêtre What's New + extraction de section `CHANGELOG.md` (bundle + notes appcast) | **S** | P1 |
| T13 | Scripts de release locaux (`release.sh`, `make-dmg.sh`, `notarize.sh`, `bump-version.sh`) — séquence ①–⑧ validée à la main une fois | **L** | P1 |
| T14 | Workflow GitHub Actions `macos-26` (secrets, keychain temporaire, publication, déploiement appcast) | **M** | P1 |
| T15 | Test E2E de la chaîne d'update (N−1 → N, deltas, EdDSA) + checklist de release | **M** | P2 |
| T16 | Site + page de download + `_redirects` `/download/latest` + hébergement `appcast.xml` | **M** | P2 |
| T17 | Canal bêta (`allowedChannels`), rollout progressif optionnel, anti-abus Worker | **S** | P2 |
| T18 | Documentation du site : sections Install/Configure/Troubleshoot + FAQ consolidée, câblage des liens About/Doctor (REQ-LIC-50) | **M** | P2 |

Ordre conseillé : T1–T4 (MVP, onboarding fonctionnel sans licence) → T5–T7 (fondations licensing testables hors ligne) → T8–T10 (activation bout en bout) → T11–T14 (première release distribuable) → T15–T18. Prérequis externe avant T8 : décision business Go/NoGo (T8 de `00-vision-scope.md`) et compte Apple Developer actif avant T13.
