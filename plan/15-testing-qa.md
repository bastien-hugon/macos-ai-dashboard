# 15. Stratégie de test et assurance qualité

> Rédigé le 3 juillet 2026, conforme à `plan/01-architecture.md` (modules SPM, threading, budgets §6, stratégie de tests §9) et `plan/02-data-model.md` (machine à états §3, invariants §8.1). Sources factuelles : `plan/research/claude-code.md` et `plan/research/cursor.md`.
> Convention : **[VÉRIFIÉ]** = adossé aux recherches ou à une API documentée ; **[TRANCHÉ]** = décision de ce document ; **[HYPOTHÈSE — à valider]** = à confirmer en implémentation.

---

## 1. Objectif & périmètre

Ce document définit **comment AgentDash est vérifié**, du test unitaire à la release : pyramide de tests automatisés, harnais d'intégration simulant Claude Code et Cursor, tests visuels du notch, bancs de performance contre les budgets chiffrés de `01-architecture.md` §6, checklist de QA manuelle **par feature**, matrice de compatibilité et critères de release.

Sections d'`AGENTPEEK_FEATURES.md` couvertes : ce document ne spécifie aucune feature produit nouvelle mais garantit la vérifiabilité de **toutes** — §2 (hooks, surfaces UI), §3 (sessions), §4 (actions inline), §5 (usage), §6 (serveurs), §7 (Quick Routes), §8 (Fast Actions), §9 (notifications), §10 (Settings/Doctor), §11 (onboarding), §12 (privacy), §14 (périmètre du clone). Les exigences testables (`REQ-*`) des documents 03 à 14 sont la matière première des plans de test ; ce document fournit l'outillage, les corpus et les procédures.

**Dans le périmètre** : infrastructure de testabilité (injection de chemins et d'horloge), corpus de fixtures, générateurs synthétiques, harnais IPC, tests snapshot, bancs de performance, bancs d'hypothèses (`scripts/experiments/`), QA manuelle, compatibilité, gates de release, CI.
**Hors périmètre** : spécification des features elles-mêmes (documents 03–14), pipeline de build/signature/notarisation (document distribution — les *vérifications* de release sont ici, la *mécanique* est là-bas).

Cadres retenus **[TRANCHÉ]** : **Swift Testing** (`import Testing`, fourni avec la toolchain Swift 6) pour tous les tests unitaires et d'intégration des packages SPM ; **XCTest** uniquement là où ses métriques sont nécessaires (`measure(metrics:)` avec `XCTMemoryMetric`/`XCTCPUMetric`/`XCTClockMetric` — API vérifiée) ; **swift-snapshot-testing** (Point-Free, épinglée `exact:`) comme dépendance **de test uniquement** — elle n'entre jamais dans le bundle livré, la règle « minimalisme des dépendances » de `01-architecture.md` §2 ne s'applique qu'au produit.

---

## 2. Exigences détaillées

### 2.1 Infrastructure de testabilité

- **REQ-TST-01 (P0)** — **Injection de chemins** : tout accès disque du produit passe par une struct `DashPaths` (définie dans `DashCore`) qui dérive tous les chemins (`~/.claude`, `~/.cursor`, `globalStorage` Cursor, Application Support, socket, `~/.agentdash`) d'une **racine home injectable**. Aucun module ne construit un chemin à partir de `NSHomeDirectory()` directement. En build Debug/Testing, la variable d'environnement `AGENTDASH_HOME` remplace la racine ; en Release, elle est **ignorée** (anti-abus).
- **REQ-TST-02 (P0)** — **Injection d'horloge** : tout code dépendant du temps (machine à états, rollover de fenêtres d'usage, `isStale`, GC de sessions) consomme un `ClockProvider` protocolisé (stratégie de `01-architecture.md` §9). Les tests pilotent le temps sans `sleep`.
- **REQ-TST-03 (P0)** — **Override du socket** : `agentdash-hook` et `HookServer` honorent la variable d'environnement `AGENTDASH_SOCKET_OVERRIDE` (chemin de socket alternatif) pour permettre des tests d'intégration hermétiques sans toucher au socket réel. Ignorée en Release côté app ; toujours honorée côté hook (le binaire est le même en test et en prod, le chemin par défaut reste celui de la config installée). **[TRANCHÉ]**
- **REQ-TST-04 (P0)** — **Garde anti-destruction** : tout test qui écrit (installeurs de hooks, sauvegardes `.bak`, snapshots d'offsets) vérifie en préambule que `DashPaths.home != FileManager.default.homeDirectoryForCurrentUser` et échoue immédiatement sinon. Aucun test ne peut modifier le vrai `~/.claude` ou `~/.cursor` du développeur.
- **REQ-TST-05 (P0)** — **Mode introspection** : lancée avec `AGENTDASH_TEST_MODE=1` (builds Debug uniquement), l'app expose sur le socket IPC un opcode supplémentaire `{"op":"dump-state"}` retournant un instantané JSON de `SessionStore`/`PromptStore`/`UsageStore` (identifiants et états, jamais de contenu utilisateur). C'est le canal d'assertion des tests bout-en-bout scriptés. **[TRANCHÉ]**
- **REQ-TST-06 (P1)** — **Déterminisme** : les tests unitaires n'utilisent ni réseau, ni `Task.sleep` supérieur à 100 ms, ni le vrai FSEvents quand un flux injecté suffit ; tout aléa (UUID, ports) est seedé. Un test unitaire qui dépasse 2 s est un bug.

### 2.2 Tests unitaires — parseurs de transcripts (AgentClaude)

- **REQ-TST-07 (P0)** — **Corpus de fixtures JSONL réelles anonymisées** dans `Packages/AgentClaude/Tests/Fixtures/`, produit par l'outil d'anonymisation (§3.2) à partir des transcripts réels de cette machine (`~/.claude/projects`, versions 2.1.168 et 2.1.199 observées **[VÉRIFIÉ]**). Le corpus couvre au minimum : session nominale multi-tours ; entrées `assistant` **dupliquées par streaming** (même `requestId`, `output_tokens` cumulatifs) ; `tool_use` Bash/Edit/Write avec `structuredPatch` ; `toolUseResult` string (erreur) ; ligne géante ≈ 70 Ko ; types `attachment`/`file-history-snapshot`/`ai-title`/`last-prompt`/`pr-link`/`queue-operation` ; entrées `isSidechain: true` + transcript subagent avec `meta.json` ; séquence `/clear` ; **type inconnu forgé** (`"type":"future-thing"`) ; ligne JSON malformée ; dernière ligne **tronquée** (écriture en cours).
- **REQ-TST-08 (P0)** — Le parseur JSONL passe sur tout le corpus avec les assertions : dédup `TokenTally` par `requestId` (garder la dernière entrée — invariant `02-data-model.md` §8.1-4) ; totaux incluant `cache_read_input_tokens` et `cache_creation_input_tokens` (piège du sous-comptage ×100 **[VÉRIFIÉ]**) ; stats de diff = somme des hunks `structuredPatch` ; compteur fichiers = `Edit|Write|NotebookEdit` distincts par `file_path` ; types inconnus **ignorés sans erreur** ; ligne malformée ignorée avec compteur d'erreurs incrémenté (jamais d'exception) ; ligne tronquée laissée en attente (offset non avancé) et complétée au drain suivant.
- **REQ-TST-09 (P0)** — **Lecture incrémentale par offsets** : tests du `TranscriptTailer` avec fichier alimenté par appends successifs (générateur §3.3) — aucun événement perdu, aucun dupliqué, offset correct après troncature/rotation du fichier (fichier recréé ⇒ relecture depuis 0), inode changé ⇒ invalidation du snapshot d'offset.
- **REQ-TST-10 (P1)** — Parseur des fichiers annexes : registre `~/.claude/sessions/<pid>.json` (champ à champ contre la fixture réelle anonymisée), `ide/<port>.lock`, encodage du dossier projet (`/Users/x/y` → `-Users-x-y` **[VÉRIFIÉ]**), y compris chemin contenant déjà des tirets.

### 2.3 Tests unitaires — Cursor (AgentCursor)

- **REQ-TST-11 (P0)** — **Fixture `state.vscdb` générée** : un builder de tests crée une base SQLite au schéma observé (`ItemTable`/`cursorDiskKV`, `key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB` **[VÉRIFIÉ]**) peuplée de `composer.composerHeaders`, `composerData:<id>` (`_v: 16`), `bubbleId:<id>:<id>` avec `toolFormerData` aux statuts `completed/error/cancelled/loading`. Tests : liste de sessions (filtres `isDraft`/`isArchived`/`isBestOfNSubcomposer`), rattachement `subagentInfo` → `rootParentConversationId`, `hasBlockingPendingActions`/`hasPendingPlan`, diffs (`totalLinesAdded/Removed`), table de traduction des noms d'outils (`run_terminal_command_v2` → « Ran command »), champ `_v` supérieur inconnu ⇒ dégradation propre (champs reconnus lus, aucun crash).
- **REQ-TST-12 (P0)** — **Concurrence SQLite** : test avec un writer simulant Cursor (transactions WAL en boucle) pendant que `CursorStateReader` lit — aucune erreur remontée à l'UI, retry sur `SQLITE_BUSY`, jamais d'ouverture `immutable=1` (assertion sur les flags d'ouverture).
- **REQ-TST-13 (P1)** — Parseur des transcripts Cursor `agent-transcripts/*.jsonl` (rôles user/assistant, `turn_ended`, dernier message assistant sans `turn_ended` = tour en cours **[VÉRIFIÉ]**) et du frontmatter `terminals/<n>.txt` et `plans/*.plan.md`.

### 2.4 Tests unitaires — machine à états, usage, serveurs, merge

- **REQ-TST-14 (P0)** — **Machine à états** : chaque transition de `02-data-model.md` §3 (T1–T16 Claude, C1–C9 Cursor) = au moins un cas de test piloté par table. Tests d'invariants dédiés : (a) un outil long (10 min simulées via `ClockProvider`) reste `executing`, jamais `waiting` par timeout ; (b) `isStale` passe à `true` à 120 s sans changer `state` ; (c) priorité `waiting > executing > thinking > idle` ; (d) fenêtre d'autorité des hooks (15 s) sur le fallback ; (e) dédup structurelle `SessionID` (deux sources, une row) ; (f) `/clear` conserve la row (`.ended(.cleared)` chaînée).
- **REQ-TST-15 (P0)** — **Calculs d'usage (UsageKit)** : jauges qui **retiennent** la dernière valeur sur échec de refresh (`isStale`, jamais de régression silencieuse — invariant §8.1-5) ; `--` uniquement si aucune valeur jamais obtenue ; reset au rollover 5 h/7 j (échéance `resets_at` **[VÉRIFIÉ]**) ; parsing de la réponse `oauth/usage` (fixture réelle anonymisée, y compris `seven_day_opus: null`) ; mapping `usage-summary` Cursor (cents → « $X of $Y », `isUnlimited`) pour les 4 mesures Spend/Weighted/Auto/API **[HYPOTHÈSE cursor n°8 — les tests figent le mapping proposé, à re-valider sur vraies réponses]** ; seuils de jauge batterie (vert/jaune/rouge) ; option compte à rebours depuis 100 % ; clé de dédup des alertes de budget (1 par fenêtre × seuil × cycle) ; stats journalières (agrégation JSONL dédupliquée + `aiCodeTracking.dailyStats`).
- **REQ-TST-16 (P0)** — **Détection de frameworks (ServersKit)** : la fonction d'identification est **pure** — entrée `(execPath, argv, env, cwd, port)`, sortie `(FrameworkKind?, RuntimeKind?, PackageRunner?, displayName)` — et testée par table sur des relevés réels : `node …/next dev`, `node …/vite`, `astro dev`, `wrangler dev`, `storybook dev`, Playwright, `python -m http.server`, `bun run dev`, `deno task dev`, serveur Rust/Go compilé, `npm_config_user_agent` (npm/pnpm/yarn/bun), `npm_lifecycle_script`, cwd `/` (app GUI) ⇒ nom d'app. Cas négatifs : port hors 3000–9999, process d'un autre uid, exclusions `/System/`.
- **REQ-TST-17 (P0)** — **Merge de `settings.json` / `hooks.json`** : tests exhaustifs des installeurs — (a) fichier absent ⇒ créé (`hooks.json` avec `"version": 1`) ; (b) fichier existant avec clés utilisateur (`model`, `permissions`… — cas réel de cette machine **[VÉRIFIÉ]**) ⇒ préservées octet pour octet sémantique ; (c) hooks tiers présents ⇒ conservés, les nôtres ajoutés avec le marqueur `~/.agentdash/bin/agentdash-hook` ; (d) **idempotence** : double exécution = fichier identique ; (e) **réparation** : entrée AgentDash altérée ⇒ restaurée sans toucher au reste ; (f) désinstallation : seules nos entrées retirées ; (g) JSON malformé ⇒ **aucune écriture**, erreur remontée au Doctor ; (h) `.bak` horodaté créé avant la première écriture seulement ; (i) `disableAllHooks: true` détecté et signalé, jamais modifié.
- **REQ-TST-18 (P1)** — **Framing NDJSON (DashCore)** : lignes > 64 Ko (jusqu'à 128 Ko), lectures partielles (1 octet à la fois), deux requêtes séquentielles sur deux connexions, permissions du socket (0600) et du dossier (0700), repli `$TMPDIR` si le chemin dépasse la limite `sun_path` (104 octets **[VÉRIFIÉ]**).
- **REQ-TST-19** — supprimé (décision one-shot du 3 juillet 2026).

### 2.5 Tests d'intégration — harnais hooks et bout-en-bout

- **REQ-TST-20 (P0)** — **Tests croisés HookRelay ↔ HookServer** (le protocole n'est pas partagé en code — `01-architecture.md` §3.2) : le **vrai binaire** `agentdash-hook` (produit de build) est spawné contre un `HookServer` de test sur socket éphémère. Cas obligatoires : nominal (payload `PermissionRequest` réel anonymisé → réponse `decision` recopiée telle quelle sur stdout, exit 0) ; **socket absent** ⇒ exit 0, stdout vide, durée < 50 ms (fail-open absolu) ; réponse lente (5 s) ⇒ le hook attend sans consommer de CPU ; **serveur tué pendant l'attente** ⇒ exit 0, stdout vide ; ligne de 70 Ko aller et retour ; stdin non-JSON ⇒ relayé quand même (le hook ne parse pas l'événement) ; arguments `--source claude|cursor` reflétés dans l'enveloppe ; `TERM_PROGRAM` hérité transmis.
- **REQ-TST-21 (P0)** — **Harnais FakeAgent** (§3.4) : simulateur de Claude Code/Cursor qui rejoue des **scénarios scriptés** d'événements hooks (fichiers YAML dans `TestSupport/Scenarios/`) en spawnant le vrai binaire hook avec le stdin exact documenté **[VÉRIFIÉ recherches §1.4]**. Scénarios P0 : tour complet Claude (`SessionStart → UserPromptSubmit → PreToolUse → PostToolUse → Stop`) ⇒ `dump-state` montre `idle` + compteurs corrects ; permission (`PermissionRequest` maintenu ouvert) ⇒ décision Allow/Deny/Always-Allow/Deny-with-feedback produit exactement le JSON de sortie documenté (écho des `permission_suggestions` pour ⌥A) ; question (`AskUserQuestion`) ⇒ `updatedInput` avec `questions` + `answers` ; plan (`ExitPlanMode`) ⇒ approve/reject ; auto-libération à `timeout − 10 s` ⇒ réponse vide ; tour Cursor (`beforeSubmitPrompt → beforeShellExecution` bloquant → allow/deny/`ask`).
- **REQ-TST-22 (P0)** — **Bac à sable `~/.claude` factice** : les tests d'intégration montent un home jetable (`AGENTDASH_HOME`) contenant `projects/` (fixtures + génération), `sessions/<pid>.json` (PID d'un process leurre contrôlé par le test), `settings.json` ; idem `~/.cursor` factice avec `hooks.json` et un faux `state.vscdb`. L'app de test (cible `AgentDashApp` en config Testing, UI headless possible) démarre dessus et l'état est vérifié via `dump-state`. Scénario P0 : app lancée **après** le début d'une session ⇒ récupération complète depuis transcript + registre (« reconnexion automatique »).
- **REQ-TST-23 (P1)** — **Ordre et pannes** : événements hooks livrés dans le désordre (PostToolUse avant PreToolUse), événements dupliqués, app redémarrée en plein tour (offsets recalculés, pas de double comptage de tokens), 5 hooks simultanés de 5 sessions différentes (multiplexage du serveur), écriture FSEvents en rafale (500 appends/s) coalescée ≤ 1 drain/250 ms.
- **REQ-TST-24 (P1)** — **Bancs d'hypothèses** (`scripts/experiments/`) : chaque hypothèse numérotée des recherches (claude-code n°1–10, cursor n°1–10) a un mini-programme reproductible avec README (procédure + résultat attendu/observé). Exécution **obligatoire avant** d'implémenter la feature dépendante ; le résultat est consigné dans le document de plan concerné (statut passe de [HYPOTHÈSE] à [VÉRIFIÉ] ou la conception est amendée).

### 2.6 Tests UI — snapshots

- **REQ-TST-25 (P0)** — **Snapshots du pill et du panel** : chaque état visuel du catalogue §4.1 est rendu dans un `NSHostingView` hors écran avec des stores peuplés de données déterministes (dates figées, UUID seedés) et comparé par `swift-snapshot-testing` (`.image`, `perceptualPrecision: 0.98`). Les baselines sont enregistrées **sur une seule version d'OS de référence** (runner CI épinglé) — le rendu texte varie entre versions d'OS, les snapshots ne tournent pas sur la matrice complète. **[TRANCHÉ]**
- **REQ-TST-26 (P0)** — Les snapshots couvrent les axes : apparence (clair/sombre), largeur (`normal`/`wide`/`ultraWide`), densité (`compact`/`regular`/`colossal`), `glassOpacity` 0,55 et 1,0 (Opaque). Combinatoire maîtrisée : tous les états × (sombre, normal, regular) + un état représentatif × chaque axe secondaire.
- **REQ-TST-27 (P1)** — **Tests de logique de vue sans snapshot** : formatage des compteurs (« 24.6k / 66 »), « resets in 2h 14m », « refills Sun at 3:47 PM » (12 h/24 h, locale figée `en_US`), troncatures Show more/less (seuil de repli), libellés de prompts « honnêtes » — testés en unitaires purs sur les fonctions de présentation.
- **REQ-TST-28 (P2)** — Smoke test XCUITest minimal : l'app se lance en bac à sable, le status item existe, le panel s'ouvre et se ferme sans crash. Les interactions fines du `NSPanel` non-activant ne sont **pas** automatisées (peu fiables — assumé, `01-architecture.md` §9) : couvertes par la QA manuelle §2.7.

### 2.7 Tests de performance

- **REQ-TST-29 (P0)** — **Transcript de 10 Mo** (généré, ≈ 12 000 entrées dont lignes de 70 Ko) : parse complet < 500 ms sur runner CI, < 250 ms sur M-series local (budget dérivé de « 100 Mo < 1 s » de `01-architecture.md` §6, marge CI ×5 **[TRANCHÉ, à calibrer]**) ; mémoire de pic du parse < 40 Mo (streaming ligne à ligne, jamais le fichier entier en RAM).
- **REQ-TST-30 (P0)** — **20 sessions simultanées** (banc §3.5 : 20 transcripts alimentés en continu + 20 fausses sessions Cursor + FakeAgent) : `phys_footprint` de l'app **< 150 Mo** en régime établi ; CPU moyen < 5 % panel ouvert ; **CPU < 0,5 %** sur 60 s une fois le flux arrêté et le notch fermé (budgets §6). Mesures via `task_info`/`proc_pid_rusage`, moyennées sur 3 exécutions.
- **REQ-TST-31 (P0)** — **Latence hook → store < 150 ms** : le banc horodate l'envoi côté FakeAgent et la mutation côté store (signposts `os_signpost` aux étapes : réception socket, routage, application MainActor) ; assertion sur p95 avec 5 hooks concurrents. La chaîne nominale mesurée ≈ 25 ms **[VÉRIFIÉ prototypes]** laisse la marge ×5 attendue.
- **REQ-TST-32 (P1)** — **Timeline massive** : session synthétique de 50 000 événements ⇒ la fenêtre rendue reste ≤ 2 000 (`TimelineWindow`), le scroll vers le haut recharge par pages sans dépasser le budget RAM, `totalCount` exact.
- **REQ-TST-33 (P1)** — **Anti-régression** : les bancs REQ-TST-29/30/31 tournent en CI nightly avec seuils ; une dégradation > 20 % vs la médiane des 7 derniers runs échoue le build (fichier de référence commité `ci/perf-baselines.json`).

### 2.8 QA manuelle, compatibilité, release

- **REQ-TST-34 (P0)** — **Checklist de QA manuelle par feature** (§4.2) : maintenue dans `plan/qa/checklist.md` (extraite de ce document), exécutée intégralement avant chaque release mineure, sections P0 avant chaque patch. Chaque item a un identifiant stable `QA-<FEAT>-n`, des étapes reproductibles avec un **vrai** Claude Code et un **vrai** Cursor, et un résultat attendu observable.
- **REQ-TST-35 (P0)** — La QA manuelle des actions inline s'exécute contre les versions **courantes** de Claude Code et Cursor au moment de la release, ainsi que contre les versions minimales supportées définies par le Doctor (plancher à fixer — hypothèse claude-code n°8) ; toute divergence de comportement des hooks est consignée et transformée en test d'intégration.
- **REQ-TST-36 (P1)** — Un **journal de bugs** classés P0 (bloquant/corruption/fail-closed), P1 (feature dégradée), P2 (cosmétique) est tenu ; tout bug P0/P1 corrigé reçoit un test de non-régression automatisé quand le niveau concerné le permet.
- **REQ-TST-37 (P0)** — **Matrice de compatibilité** (§4.3) exécutée avant release majeure : macOS 14 / 15 / 26, Mac avec notch / sans notch (écran externe simulant le notch), multi-écrans, Spaces/plein écran, clavier AZERTY et QWERTY (raccourcis ⌘A/⌘N/⌥A/⌥T), 12 h/24 h, clair/sombre.
- **REQ-TST-38 (P1)** — Sur macOS 26, vérification spécifique de la branche `#available(macOS 26.0, *)` d'`agentGlass()` (Liquid Glass) **et** du fallback `NSVisualEffectView` (forcé via un réglage de debug) — les deux rendus doivent passer la checklist Appearance.
- **REQ-TST-39 (P0)** — **CI** : à chaque PR — `swift test` de tous les packages (macOS 26, arm64) + build des 2 cibles Xcode + tests d'intégration HookRelay + lint des accents/orthographe des chaînes UI ; nightly — matrice unitaire macos-14/15/26 (runners GitHub), bancs de performance, snapshots. Aucun merge si un test P0 échoue.
- **REQ-TST-40 (P0)** — **Couverture minimale** (mesurée par `swift test --enable-code-coverage`, gate CI) : machine à états DashCore ≥ 90 % de lignes ; parseurs AgentClaude/AgentCursor ≥ 85 % ; installeurs/merge ≥ 90 % ; UsageKit ≥ 85 % ; ServersKit (identification) ≥ 85 %. Pas d'objectif global artificiel sur l'UI.
- **REQ-TST-41 (P0)** — **Critères de release** (gate final, tous obligatoires) : (1) 100 % des tests automatisés verts sur la CI de release ; (2) bancs de performance dans les budgets ; (3) checklist QA P0 exécutée sur ≥ 2 versions d'OS dont macOS 14 ; (4) matrice de compatibilité sans échec P0 ; (5) zéro bug P0 ouvert, bugs P1 documentés dans les notes de version ; (6) DMG signé + notarisé validé par `spctl -a -vv` et `stapler validate` sur une machine vierge ; (7) Doctor entièrement vert sur machine vierge après onboarding ; (8) test de remplacement manuel de l'app N→N+1 (nouvelle `AgentDash.app` copiée dans `/Applications`) sans perte de réglages ; (9) vérification privacy : capture réseau (Proxyman/`tcpdump`) montrant **uniquement** les 2 destinations autorisées (`api.anthropic.com`, `cursor.com`) ; (10) hypothèses restantes marquées [HYPOTHÈSE] dans les plans : aucune ne conditionne une feature annoncée.
- **REQ-TST-42 (P1)** — **Gestion du flaky** : un test instable est mis en quarantaine (tag `.flaky` + issue) sous 24 h ; un test en quarantaine > 2 semaines est réparé ou supprimé ; aucun retry automatique sur les tests unitaires, 1 retry maximum sur l'intégration.
- **REQ-TST-43 (P2)** — **Tests de désinstallation/réparation** end-to-end : toggle hooks off ⇒ seules les entrées AgentDash disparaissent des configs ; suppression manuelle de `~/.agentdash/bin/agentdash-hook` ⇒ resynchronisation au lancement suivant (hash) ; corruption du binaire ⇒ idem.

---

## 3. Conception technique

### 3.1 Arborescence de test

```
Packages/<Module>/Tests/…                    # Swift Testing, unitaires par module
Packages/TestSupport/                        # package SPM local, dépendance de test partagée
    Sources/TestSupport/
        DashPaths+Sandbox.swift              # création de homes jetables
        TestClock.swift                      # ClockProvider pilotable
        TranscriptForge.swift                # générateur JSONL synthétique (§3.3)
        CursorDBFixture.swift                # générateur state.vscdb (§3.3)
        FakeAgentHarness.swift               # harnais hooks (§3.4)
        Anonymizer/                          # outil d'anonymisation (§3.2)
    Scenarios/*.yaml                         # scénarios FakeAgent rejouables
IntegrationTests/                            # cible de tests Xcode (app + hook réels)
SnapshotTests/                               # cible dédiée + __Snapshots__/ (baselines commitées)
PerfBench/                                   # exécutable de banc (§3.5) + ci/perf-baselines.json
scripts/experiments/                         # bancs d'hypothèses numérotés (REQ-TST-24)
plan/qa/checklist.md                         # checklist manuelle par feature (extraite du §4.2)
```

### 3.2 Outil d'anonymisation des fixtures **[TRANCHÉ]**

Exécutable Swift `anonymize-transcript` (dans TestSupport, lancé à la main, jamais en CI) :

```swift
struct AnonymizationRules {
    /// Champs texte remplacés par du lorem de MÊME longueur en octets (préserve les
    /// lignes de 70 Ko et les offsets) : text, thinking, content string, stdout, stderr,
    /// toolUseResult (string), plan, prompt, subtitle, name…
    static let textFields: Set<String>
    /// Identifiants re-mappés déterministiquement (UUID → UUID via SHA-256 seedé) :
    /// sessionId, uuid, parentUuid, requestId, tool_use_id, composerId, bubbleId…
    static let idFields: Set<String>
    /// Chemins réécrits sous /Users/test/… en préservant la profondeur et l'extension.
    static let pathFields: Set<String>
    /// Conservés TELS QUELS : type, role, model, stop_reason, usage.*, timestamps
    /// (décalés d'un delta constant), structuredPatch (contenu des lignes anonymisé,
    /// compteurs de hunks préservés), permission_suggestions (ruleContent anonymisé).
}
func anonymize(line: Data, rules: AnonymizationRules, seed: UInt64) throws -> Data
```

Propriété testée sur l'outil lui-même : `parse(anonymize(x)) == anonymize-métriques(parse(x))` — les métriques extraites (tokens, diffs, compteurs, états) sont **identiques** avant/après anonymisation. Revue humaine obligatoire de chaque fixture avant commit (aucun contenu privé — promesse §12 des features appliquée au repo).

### 3.3 Générateurs synthétiques

```swift
/// Générateur de transcripts Claude — utilisé par les tests d'offsets, d'intégration et de perf.
public struct TranscriptForge {
    public struct TurnSpec: Sendable {
        public var toolCalls: [(name: String, input: [String: String], durationMs: Int)]
        public var streamingChunks: Int      // nb d'entrées assistant partagées par requestId
        public var usage: (input: Int, output: Int, cacheRead: Int, cacheCreation: Int)
        public var sidechain: Bool
        public var lineSizeTarget: Int?      // force des lignes géantes (70 Ko)
    }
    public init(sessionId: UUID, cwd: String, version: String = "2.1.199", seed: UInt64)
    public func makeSession(turns: [TurnSpec]) -> Data                    // JSONL complet
    public func appendTurn(to url: URL, spec: TurnSpec) throws            // pour FSEvents/offsets
    public func makeCorpus(sessionCount: Int, targetBytes: Int) throws -> URL  // banc de perf
}

/// Générateur de state.vscdb minimal (schéma observé, _v: 16).
public struct CursorDBFixture {
    public struct ComposerSpec {
        public var composerId: UUID; public var name: String?
        public var status: String            // "none" | "completed" | "aborted"
        public var hasBlockingPendingActions: Bool; public var hasPendingPlan: Bool
        public var bubbles: [(type: Int, toolName: String?, toolStatus: String?)]
        public var linesAdded: Int; public var linesRemoved: Int
        public var isDraft: Bool; public var isArchived: Bool; public var subagentParent: UUID?
    }
    public static func make(at url: URL, composers: [ComposerSpec]) throws
    public static func mutate(at url: URL, apply: (inout ComposerSpec) -> Void) throws  // simule Cursor qui écrit
}
```

### 3.4 Harnais FakeAgent — flux d'un test d'intégration

```
 Test (Swift Testing)                 agentdash-hook (VRAI binaire)            HookServer / app de test
 ────────────────────                 ─────────────────────────────            ─────────────────────────
 1. home jetable (AGENTDASH_HOME)
 2. démarre HookServer sur socket
    éphémère (AGENTDASH_SOCKET_OVERRIDE)
 3. scenario.yaml → événement N
 4. spawn hook, stdin = JSON exact ──►  lit stdin, enveloppe {v,source,
    env = {TERM_PROGRAM, PPID…}          term_program, ppid, event} ─────────►  EventRouter → stores
                                                                               (décision ? garde la connexion)
 5. (cas décision) le test invoque
    PromptStore.decide(.allow) ────────────────────────────────────────────►  réponse NDJSON ◄─┐
                                      ◄── stdout = corps JSON tel quel ───────────────────────┘
 6. assertions : stdout du hook,
    exit code, durée, dump-state
```

```swift
public final class FakeAgentHarness {
    public init(hookBinary: URL, socket: URL)
    @discardableResult
    public func send(event: [String: any Sendable], source: AgentKind,
                     env: [String: String] = [:], timeout: Duration = .seconds(10))
        async throws -> HookRunResult
    public func runScenario(_ url: URL) async throws -> [HookRunResult]   // rejoue un YAML
}
public struct HookRunResult: Sendable {
    public var stdout: Data; public var stderr: Data
    public var exitCode: Int32; public var duration: Duration
}
```

Les payloads des scénarios reprennent **mot pour mot** les stdin documentés (`plan/research/claude-code.md` §1.4, `cursor.md` §1.3–1.4) — le harnais est le gardien du contrat : si Claude Code change son format, seul le scénario est mis à jour et les régressions apparaissent immédiatement.

### 3.5 Banc de performance `PerfBench`

Exécutable dédié (pas XCTest, pour contrôler précisément le cycle de vie de l'app) :

```
1. Prépare un home jetable : corpus TranscriptForge (20 sessions, 10 Mo max/fichier),
   CursorDBFixture (20 composers), settings/hooks factices.
2. Lance AgentDash.app (config Testing, AGENTDASH_TEST_MODE=1, home injecté).
3. Phase CHARGE (120 s) : 20 writers appendent des tours (1 tour/2 s/session),
   FakeAgent envoie 5 hooks/s répartis, mutations CursorDBFixture toutes les 2 s.
4. Phase REPOS (90 s) : tout s'arrête, notch fermé (commande dump-state annexe).
5. Échantillonne toutes les 5 s : phys_footprint (task_info TASK_VM_INFO),
   ri_user_time/ri_system_time (proc_pid_rusage) → CPU %.
6. Latence : FakeAgent émet 200 hooks horodatés ; l'app renvoie dans dump-state
   les horodatages d'application au store → distribution, p50/p95.
7. Écrit perf-report.json ; compare à ci/perf-baselines.json (± tolérances REQ-TST-33).
```

Pour les micro-bancs (REQ-TST-29), XCTest classique : `measure(metrics: [XCTMemoryMetric(), XCTCPUMetric(), XCTClockMetric()])` autour de `parse(corpus)` **[VÉRIFIÉ API]**.

### 3.6 Snapshots — assise technique

```swift
@MainActor
func assertNotchSnapshot<V: View>(
    _ view: V, named name: String,
    width: PanelWidth = .normal, density: Density = .regular,
    colorScheme: ColorScheme = .dark, record: Bool = false
) {
    let host = NSHostingView(rootView: view
        .environment(fixtureStores)             // stores peuplés déterministes
        .environment(\.colorScheme, colorScheme))
    host.frame = CGRect(origin: .zero, size: panelSize(for: width, density))
    assertSnapshot(of: host, as: .image(perceptualPrecision: 0.98), named: name)
}
```

Les vues NotchUI reçoivent leurs stores par environnement (déjà imposé par l'architecture) : aucun refactor spécifique aux tests. Le rendu utilise le fallback `NSVisualEffectView` (déterministe) ; la branche Liquid Glass macOS 26 est vérifiée manuellement (REQ-TST-38) car son rendu dépend du compositeur. **[TRANCHÉ]**

---

## 4. Spécification UX/UI — catalogues de vérification

### 4.1 Catalogue des états snapshotés (REQ-TST-25/26)

| # | Surface | État | Données de fixture |
|---|---|---|---|
| S1 | Pill | idle, 0 session | vide |
| S2 | Pill | 2 sessions actives (count) | executing + thinking |
| S3 | Pill | mode usage (jauges live, largeur verrouillée Wide) | 5 h à 33 %, 7 j à 13 % |
| S4 | Pill | attention (waiting, teinte + point) | 1 waiting(.permission) |
| S5 | Pill | hidden-when-idle / expanded-only (absence rendue) | réglages dédiés |
| S6 | Panel | liste 3 projets / 6 sessions, tous les états | executing/thinking/waiting/idle/ended/stale |
| S7 | Panel | session étendue : timeline mixte + subagents + Markdown replié | 25 événements, Show more visible |
| S8 | Panel | prompt permission (Allow/Deny/Always Allow/Deny with feedback + raccourcis) | `PermissionRequest` Bash `rm -rf node_modules` |
| S9 | Panel | prompt plan (titre stylisé, Approve/Reject) | plan Markdown 3 sections |
| S10 | Panel | prompt multi-questions (2 questions, multiSelect) | `AskUserQuestion` |
| S11 | Panel | usage détaillé : jauges batterie verte/jaune/rouge, `--`, isStale, « $X of $Y » + sous-barres | 4 comptes de fixture |
| S12 | Panel | serveurs : 3 serveurs (Next.js/Vite/python) + état vide + confirmation stop | ServersKit fixtures |
| S13 | Panel | Quick Routes (chemins existants seulement) + Fast Actions (succès/échec) | home jetable partiel |
| S14 | Menu bar popover | sections plates, point orange | 1 waiting |
| S15 | Settings | chaque onglet (General/Notifications/Appearance/Usage/Shortcuts/Doctor/About) | réglages par défaut |
| S16 | Fenêtres | onboarding | fixtures d'onboarding |

Chaque snapshot existe en clair/sombre ; S6 existe de plus en `wide`, `ultraWide`, `compact`, `colossal` et `glassOpacity = 1.0`.

### 4.2 Checklist de QA manuelle par feature (extraits normatifs ; fichier complet `plan/qa/checklist.md`)

Environnement : Mac Apple Silicon, vrai Claude Code (CLI + extension Cursor/VS Code, si possible Claude Desktop) et vrai Cursor connectés, projet jetable `~/qa-playground`.

**QA-HOOKS — Installation & réparation (features §2.1)**
1. Machine sans `~/.cursor/hooks.json` (cas réel vérifié) : onboarding → toggles hooks ON → `settings.json` fusionné sans perte des clés existantes, `hooks.json` créé `"version": 1`, statut « Ready » par outil dans Settings → General.
2. Session Claude **déjà ouverte** pendant l'installation : le file watcher recharge les settings **[VÉRIFIÉ doc]** → le tour suivant apparaît dans AgentDash sans redémarrage (zéro config).
3. Supprimer `~/.agentdash/bin/agentdash-hook` puis relancer l'app → binaire resynchronisé, Doctor vert.
4. Écraser nos entrées dans `settings.json` → Doctor le détecte (`ConfigChange` + re-check), bouton réparer les restaure, hooks tiers intacts.
5. Toggle OFF → nos entrées retirées, le reste du fichier intact ; l'agent continue de fonctionner normalement (fail-open).

**QA-NOTCH — Pill & Panel (features §2.2)**
1. Survol du pill : ouverture après le délai d'intention (~200 ms), pas de flickering en survols rapides ; fermeture au clic extérieur.
2. `claude` demande une permission → auto-expand (si activé) < 1 s, animation fluide ; le notch reste ouvert quand Settings a le focus.
3. Écran externe seul : panel plaqué au ras du bord supérieur (notch simulé) ; débrancher/rebrancher l'écran en panel ouvert → aucune fenêtre orpheline.
4. Saisie dans le champ de réponse d'une question sans que l'app frontale (l'IDE) perde son focus apparent (NSPanel non-activant key-able).

**QA-SESS — Sessions (features §3)**
1. Lancer 3 sessions : `claude` dans iTerm, extension dans Cursor, agent Cursor — les 3 apparaissent, triées par projet, hôte correct (terminal/IDE), sans doublon.
2. Tour long avec gros outputs : compteurs input/output **mid-turn** (mise à jour ≤ 300 ms de coalescence), stats de diff après edits, avatar en vague pendant l'activité, rotation calme en attente.
3. `/clear` → la row reste (`ended`), la nouvelle session la remplace visuellement ; `claude --resume` → même row, dernier tour conservé.
4. Kill sur une session terminal → le process meurt (SIGTERM), la row passe `ended(.killed)` ; jamais proposé sur Cursor.
5. « Copy Session as Markdown » → Markdown complet et lisible dans le presse-papiers ; timeline > 2 000 événements : scroll fluide, chargement paresseux vers le haut.

**QA-ACT — Actions inline (features §4)** — *les 5 premiers points recoupent les hypothèses claude-code n°1–2 : résultats à consigner.*
1. `claude` déclenche une permission Bash → prompt dans le notch ; **⌘A** : « Allowed by PermissionRequest hook » visible dans le terminal, l'outil part immédiatement.
2. **⌘N** puis Deny with feedback avec message → Claude lit le feedback et s'adapte.
3. **⌥A** sur une suggestion → la règle apparaît dans le fichier de settings de la `destination` annoncée ; la même commande ne redemande plus.
4. Plan mode → plan complet rendu, titre stylisé, Approve (option bascule acceptEdits) / Reject avec feedback.
5. Question multi-choix → réponse inline ; vérifier le comportement du sélecteur terminal pendant l'attente (« prompt handling location »).
6. Ne pas répondre pendant ~10 min → à `timeout − 10 s` le notch libère et le dialogue natif du terminal fonctionne (fail-open, l'utilisateur ne perd jamais la main).
7. Cursor : commande shell interceptée → Allow/Deny/« Ask in Cursor » ; pas de ⌥A proposé.
8. **⌥T** ouvre le terminal de la session concernée.
9. App AgentDash **quittée** : toutes les demandes de permission des deux agents s'affichent nativement, aucun blocage (test critique fail-open).

**QA-USAGE — Usage (features §5)**
1. Jauges 5 h/7 j conformes au `/usage` du CLI (±1 %) ; « resets in… » et « refills … » exacts ; sélection de compte si multi-comptes.
2. Couper le réseau → jauges **figées** sur la dernière valeur (pas de stale affiché, pas de `--`) ; rétablir → récupération.
3. Cursor : basculer Spend/Weighted/Auto/API → mise à jour immédiate, « $X of $Y » cohérent avec le dashboard web ; barres optionnelles.
4. Franchir un seuil de budget configuré → une seule notification par fenêtre × seuil × cycle.
5. Stats jour par jour cohérentes avec `ccusage` (ordre de grandeur, dédup identique).

**QA-SRV — Serveurs (features §6)** : `npm run dev` (Next.js), `vite`, `python -m http.server 8080` → détection < 10 s, labels/uptime/dossier corrects ; open/copy URL ; stop avec confirmation (tap double dans la menu bar) ; le serveur relancé avec le même port réapparaît (nouvelle identité pid+port).

**QA-QRF — Quick Routes & Fast Actions (features §7–8)** : seuls les chemins existants listés ; Config révèle le fichier dans le Finder ; Fast Action `echo ok` → sortie visible ; action en échec → code de sortie affiché.

**QA-NOTIF — Notifications (features §9)** : test notification depuis Settings ; permission/stuck (>120 s)/tâche terminée/budget ; toggle maître coupe tout ; sons respectés.

**QA-SET — Settings (features §10)** : chaque réglage a un effet immédiat et survit au redémarrage ; launch at login reflète l'état réel `SMAppService` ; enregistrement d'un raccourci en conflit → avertissement ; Doctor : chaque check passe au vert sur machine saine, chaque panne simulée (socket supprimé, binaire corrompu, hooks écrasés) est détectée avec correctif guidé.

**QA-ONB — Onboarding & mise à jour manuelle (features §11)** : premier lancement → welcome guidé ; remplacement manuel de `AgentDash.app` dans `/Applications` par la version N+1 → réglages, hooks et raccourcis conservés, `~/.agentdash/bin` resynchronisé au lancement, Doctor vert. *(QA-LIC — supprimé (décision one-shot du 3 juillet 2026).)*

**QA-PRIV — Privacy (features §12)** : capture réseau sur une session complète → uniquement `api.anthropic.com` et `cursor.com` (2 destinations, aucune autre) ; chaque destination désactivable (opt-out) ; logs exportés sans aucun contenu de prompt/réponse/diff.

### 4.3 Matrice de compatibilité (REQ-TST-37)

| Configuration | Unitaires CI | QA fumée (30 min) | QA complète |
|---|---|---|---|
| macOS 26, MacBook Pro **avec notch** (machine de référence) | ✅ | ✅ | ✅ chaque release |
| macOS 15, MacBook Air avec notch | ✅ (runner) | ✅ | release majeure |
| macOS 14, Mac mini/Studio **sans notch** + écran externe | ✅ (runner) | ✅ | release majeure |
| Multi-écrans : builtin + externe, notch simulé, changement d'écran principal à chaud | — | ✅ | release majeure |
| Clamshell (builtin fermé), sommeil/réveil (`didWakeNotification`), Spaces & app plein écran | — | ✅ | release majeure |
| Claviers AZERTY + QWERTY (hotkeys), locales fr_FR/en_US (12 h/24 h, formats) | — | ✅ | release majeure |
| Liquid Glass (macOS 26) **et** fallback forcé `NSVisualEffectView` | snapshots (fallback) | ✅ | release majeure |

---

## 5. Cas limites & gestion d'erreurs

1. **Fixtures périmées** : Claude Code/Cursor changent de format → le harnais FakeAgent et les fixtures sont versionnés par version d'agent observée (`Fixtures/claude-2.1.199/…`) ; l'ajout d'une version n'efface jamais l'ancienne (tolérance multi-versions testée).
2. **Anonymisation défaillante** : une fuite de contenu privé dans une fixture est un incident P0 → double garde : test de propriété (§3.2) + revue humaine + grep de motifs personnels (`/Users/bastien`, e-mail) en pre-commit.
3. **Flakiness FSEvents** : la latence (~0,3 s) et la coalescence rendent les assertions temporelles fragiles → toutes les attentes utilisent le polling avec échéance (`expect(within: .seconds(5))`), jamais de `sleep` fixe.
4. **CI sans notch ni écran** : les runners GitHub sont headless → snapshots via `NSHostingView` hors écran (pas de capture d'écran réelle) ; XCUITest limité au smoke ; tout ce qui exige un vrai notch est en QA manuelle (assumé).
5. **PID leurres** : les tests du registre `~/.claude/sessions/` utilisent des process enfants contrôlés (`/bin/sleep`) — jamais un PID arbitraire ; le garde-fou kill (uid, `start_time`, execPath) est testé contre un PID recyclé simulé (process mort puis fixture pointant un autre process).
6. **Différences de rendu inter-OS** : baselines snapshot par OS de référence unique ; changement de runner CI = re-enregistrement contrôlé (PR dédiée, revue visuelle des diffs).
7. **Budgets sur CI partagée** : les runners mutualisés sont bruités → budgets CI avec marge ×5 (REQ-TST-29), moyennes sur 3 runs, gate en régression relative (REQ-TST-33) plutôt qu'en absolu strict.
8. **`dump-state` en prod** : l'opcode d'introspection n'existe qu'en Debug (compilation conditionnelle testée : un build Release doit répondre erreur inconnue).
9. **Tests de merge sur fichiers exotiques** : `settings.json` avec commentaires (JSON5 non standard) ou BOM → l'installeur refuse d'écrire (REQ-TST-17-g) plutôt que de corrompre.
10. **Horloge des bancs de perf** : les mesures s'appuient sur `mach_continuous_time` (insensible aux ajustements NTP pendant le banc).
11. **Épuisement de descripteurs** : le banc 20 sessions vérifie aussi l'absence de fuite de FD (compte `proc_pidinfo PROC_PIDLISTFDS` stable entre début et fin de la phase repos).
12. **Machine du testeur non conforme** : la checklist QA commence par un préambule d'état (versions d'agents, hooks présents, comptes connectés) ; tout écart est consigné avec le résultat.

---

## 6. Critères d'acceptation

1. **Given** le corpus de fixtures complet (REQ-TST-07), **When** `swift test` tourne sur `AgentClaude`, **Then** tous les tests passent et la couverture du parseur est ≥ 85 %, y compris sur les types inconnus et la ligne tronquée.
2. **Given** un home jetable sans socket, **When** le vrai `agentdash-hook` reçoit un `PermissionRequest` sur stdin, **Then** il sort en < 50 ms avec exit 0 et stdout vide (fail-open vérifié par le test d'intégration REQ-TST-20).
3. **Given** le harnais FakeAgent et l'app de test, **When** le scénario « tour complet Claude » est rejoué, **Then** `dump-state` montre la session `idle`, 1 commande, les tokens dédupliqués exacts du scénario, et la latence p95 hook → store < 150 ms.
4. **Given** un `settings.json` contenant des clés utilisateur et un hook tiers, **When** l'installeur s'exécute deux fois puis désinstalle, **Then** le fichier final est byte-équivalent sémantique à l'original et un unique `.bak` horodaté existe.
5. **Given** la machine à états et un `ClockProvider` avancé de 10 minutes pendant un `PreToolUse` sans `PostToolUse`, **When** on interroge l'état, **Then** il est `executing` avec `isStale == true`, jamais `waiting`.
6. **Given** le banc PerfBench (20 sessions, phase repos), **When** les échantillons sont agrégés, **Then** `phys_footprint` < 150 Mo et CPU moyen < 0,5 %, rapport commité en artefact CI.
7. **Given** les baselines snapshot enregistrées, **When** une PR modifie NotchUI, **Then** tout écart visuel > 2 % de perceptualPrecision échoue la CI et exige une mise à jour explicite des baselines.
8. **Given** la checklist `plan/qa/checklist.md` et une machine vierge macOS 14, **When** la passe QA de release s'exécute avec un vrai Claude Code et un vrai Cursor, **Then** chaque item P0 est coché avec résultat, et QA-ACT-9 (app quittée ⇒ prompts natifs intacts) est vérifié en dernier.
9. **Given** la CI de release, **When** un des 10 gates de REQ-TST-41 échoue, **Then** la release est bloquée mécaniquement (le job de publication dépend du job de gates).
10. **Given** une hypothèse de recherche non validée (ex. cursor n°2, timeout des hooks), **When** la feature dépendante entre en développement, **Then** le banc `scripts/experiments/` correspondant a été exécuté et son résultat est consigné dans le document de plan concerné.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances entrantes** (ce document vérifie ce qu'ils spécifient) : `01-architecture.md` (budgets §6, stratégie §9, contrat IPC §4), `02-data-model.md` (machine à états, invariants — source des tables de tests), `03-integration-claude-code.md` et `04-integration-cursor.md` (payloads exacts des scénarios FakeAgent, installeurs), `05-notch-ui.md`/`06-menubar.md` (catalogue snapshot §4.1), `07-sessions.md`, `09-token-usage.md`, `10-local-servers.md`, `11-quick-routes-fast-actions.md`, ainsi que les documents actions inline, notifications, settings/doctor et onboarding/distribution (checklists QA-ACT, QA-NOTIF, QA-SET, QA-ONB et gates de notarisation).
**Dépendances sortantes** : `DashPaths`, `ClockProvider` généralisé, `AGENTDASH_SOCKET_OVERRIDE`, `AGENTDASH_TEST_MODE`/`dump-state` sont des exigences de testabilité que les documents d'implémentation doivent intégrer dès le squelette (coût quasi nul au départ, refactor coûteux après).

**Risques** :
1. **Contrats non officiels** (endpoint `oauth/usage`, endpoints dashboard Cursor, schéma `state.vscdb`) : les tests figent des fixtures qui peuvent diverger de la réalité → mitigation : bancs d'hypothèses avant implémentation, « usage health notice » côté produit, fixtures versionnées.
2. **QA manuelle coûteuse** (2 agents réels × matrice) : ~1 jour par release majeure → mitigation : checklist hiérarchisée P0/P1, fumée de 30 min pour les patchs.
3. **Snapshots fragiles** aux mises à jour d'OS du runner : épinglage du runner + procédure de re-baseline contrôlée.
4. **swift-snapshot-testing** = dépendance supplémentaire (test-only) : risque faible, épinglée `exact:`, supprimable au profit d'un comparateur maison si besoin.
5. **Impossibilité d'automatiser le NSPanel non-activant** : le cœur UX (focus, hover) repose sur la QA manuelle — risque assumé et documenté (`01-architecture.md` §9), compensé par la densité du catalogue snapshot.

---

## 8. Découpage en tâches

| # | Tâche | Taille |
|---|---|---|
| T1 | `DashPaths` + `ClockProvider` généralisé + `AGENTDASH_HOME`/`AGENTDASH_SOCKET_OVERRIDE` + garde anti-destruction (REQ-TST-01..04) | **M** |
| T2 | Package `TestSupport` : sandbox de home, TestClock, squelette | **S** |
| T3 | Outil d'anonymisation + test de propriété + première extraction du corpus réel (REQ-TST-07, §3.2) | **M** |
| T4 | Tests unitaires parseur Claude sur corpus (REQ-TST-08..10) | **L** |
| T5 | `CursorDBFixture` + tests AgentCursor (REQ-TST-11..13) | **L** |
| T6 | Tests machine à états pilotés par table T1–T16/C1–C9 + invariants (REQ-TST-14) | **M** |
| T7 | Tests UsageKit (jauges, rollover, mesures Cursor, alertes) (REQ-TST-15) | **M** |
| T8 | Tests ServersKit par table + refactor identification pure (REQ-TST-16) | **M** |
| T9 | Tests des installeurs/merge settings.json + hooks.json (REQ-TST-17) | **M** |
| T10 | Tests framing NDJSON (REQ-TST-18) | **M** |
| T11 | Tests croisés HookRelay ↔ HookServer avec vrai binaire (REQ-TST-20) | **M** |
| T12 | `FakeAgentHarness` + format scénarios YAML + scénarios P0 (REQ-TST-21) | **L** |
| T13 | `TranscriptForge` (génération + append incrémental + corpus de perf) | **M** |
| T14 | Bout-en-bout bac à sable : app de test + `dump-state` + scénarios reconnexion/désordre (REQ-TST-05, 22, 23) | **L** |
| T15 | Infra snapshot (`assertNotchSnapshot`, stores de fixture) + catalogue S1–S16 (REQ-TST-25..27) | **L** |
| T16 | `PerfBench` (charge/repos, task_info, latence signposts) + baselines + gate nightly (REQ-TST-29..33) | **L** |
| T17 | `scripts/experiments/` : bancs des hypothèses claude-code n°1–2 et cursor n°1–2, 4–5 en premier (REQ-TST-24) | **M** |
| T18 | Rédaction de `plan/qa/checklist.md` complet à partir du §4.2 + matrice §4.3 (REQ-TST-34..38) | **M** |
| T19 | Pipelines CI : PR, nightly (matrice OS, perf, snapshots), gates de couverture et de release (REQ-TST-39..41) | **L** |
| T20 | Journal de bugs + procédure quarantaine flaky + tests désinstallation/réparation (REQ-TST-36, 42, 43) | **S** |

Ordre recommandé : T1–T2 (fondations, **avant** tout code produit) → T3–T6 et T11–T13 en parallèle du développement des parseurs et du relais → T7–T10 avec leurs modules → T14–T16 dès que l'app se lance en bac à sable → T17 en continu (chaque banc avant sa feature) → T18–T20 avant la première release.
