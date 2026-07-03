# 16. Roadmap et jalons (M0 → M8)

> Rédigé le 3 juillet 2026. Ce document ordonne l'exécution des plans `00` à `15` en neuf jalons incrémentaux, chacun se terminant par un **livrable démontrable à la main**. L'ordre s'inspire de l'historique réel d'AgentPeek (`AGENTPEEK_FEATURES.md` §13) : la v0.1.0 d'AgentPeek était déjà un noyau complet (sessions live, actions inline, jauges 5 h/7 j, serveurs, Quick Routes, installeur de hooks) — nous décomposons ce noyau en M0–M4, puis nous suivons le changelog pour la suite (notifications v0.1.7 → M5, Doctor v0.2.6–0.2.7 → M6, Cursor v0.2.9–0.2.11 → M7, distribution → M8).
> Conventions : références de tâches et d'exigences = `fichier du plan · identifiant` (ex. `03 · REQ-CLA-24`, `08 · A5`). Priorités P0/P1/P2 héritées des fichiers sources. **Spike** = banc de validation d'hypothèse (`scripts/experiments/`) à exécuter **avant** la feature dépendante (obligation `00 · REQ-VIS-29`).

---

## 0. Principes de la roadmap

1. **Un jalon = un incrément démontrable.** Chaque jalon se conclut par une démonstration manuelle scriptée (« definition of done ») rejouable sur la machine de développement, sans mock.
2. **Les spikes ouvrent chaque jalon.** Toute hypothèse `[HYPOTHÈSE]` conditionnant une feature du jalon est validée en tout début de jalon (banc `scripts/experiments/`), le résultat étant consigné dans le fichier de plan concerné (statut → `[VÉRIFIÉ]` ou conception amendée). C'est la règle `00 · REQ-VIS-29` / `15 · REQ-TST-24`.
3. **La testabilité précède le code produit.** `DashPaths`, `ClockProvider`, `AGENTDASH_HOME`, `AGENTDASH_SOCKET_OVERRIDE` et la garde anti-destruction (`15 · REQ-TST-01..04`) sont posés en M0 — les refactorer après coup coûterait cher.
4. **Le fil de tests court sur tous les jalons.** Le fichier `15` n'a pas de jalon propre : chaque jalon embarque ses tests unitaires/intégration et ses fixtures ; les gros harnais (FakeAgent, PerfBench, snapshots) s'installent au jalon où ils deviennent utiles (indiqué dans chaque jalon).
5. **Versionnage** (`00 · §3.4`) : jalons M0–M7 = builds internes `0.0.1` → `0.0.8` ; la **parité MVP** (`00 · REQ-VIS-25` : blocs 1–8 pour Claude Code, blocs 1–5 pour Cursor — le bloc 5 limité aux permissions via hooks bloquants, pas de ⌥A ni de réponses inline) est atteinte en fin de M7 ; M8 produit la release distribuable **`0.1.0`** — même numérotation de départ qu'AgentPeek.
6. **Écart assumé avec l'ordre suggéré initialement** : Fast Actions (AgentPeek v0.2.5) est rattachée à M4 (co-localisée avec Quick Routes dans NotchUI, faible coût, aucune dépendance) ; le Doctor (v0.2.6) est construit avec Settings en M6 mais son **self-test IPC** (`13 · REQ-SET-55`) est prototypé dès M2 car il sécurise tout le développement des hooks ; Cursor reste en M7, fidèle au changelog réel (v0.2.9).

Dépendances entre jalons (chemin critique en gras) :

```
M0 ──► M1 ──► M2 ──► M3 ─┐
 │             │          ├──► M5 ──► M6 ──► M7 ──► M8
 └──────────► M4 ─────────┘
M4 ne dépend que de M0 (peut être parallélisé avec M1–M3).
M5 exige M2 (prompts pour les notifications de permission) et M3 (jauges pour le popover).
```

---

## M0 — Socle applicatif + shell notch (build interne 0.0.1)

**Objectif :** une app d'arrière-plan signée localement, bundlée, dont le pill épouse le notch et s'ouvre en panel animé (encore vide), sans jamais voler le focus, avec l'infrastructure de test et l'instrumentation des budgets en place.

### Tâches

| Tâche | Référence |
|---|---|
| Projet Xcode (2 cibles) + packages SPM locaux + règles de dépendances | `01 · §3.1–3.3`, `A8` ; `00 · REQ-VIS-09` |
| `ProductIdentity`, bundle id provisoire, `LSUIElement`, arm64 pur | `00 · T1, REQ-VIS-01..04` |
| Squelette couche AgentAdapter (`AgentProvider`, `HooksInstaller`, `UsageProvider`, `AgentCapabilities`) + `AgentFixture` | `00 · T3, REQ-VIS-09/10/11` |
| Testabilité : `DashPaths`, `ClockProvider` généralisé, overrides d'environnement, garde anti-destruction, package `TestSupport` | `15 · T1/T2, REQ-TST-01..06` |
| `NotchPanel` + géométrie (`notchSize`, fausse encoche externe, click-through) | `05 · N1, REQ-NUI-01..13` |
| Machine à états d'expansion, hover à délai d'intention, clic extérieur, exceptions Settings/champ texte | `05 · N3, REQ-NUI-17..23` |
| `NotchShape` animable + ressorts ouverture/fermeture + anti-overshoot | `05 · N4, REQ-NUI-46..48` |
| Rendu verre `agentGlass()` (fallback `NSVisualEffectView` + branche macOS 26) et pill noir pur | `05 · N7 (socle), REQ-NUI-24, REQ-NUI-45` |
| Multi-écrans : `displayUUID`, reconfiguration/veille, restauration d'état | `05 · N2, REQ-NUI-14/15` |
| Conteneur du panel : header (horloge), sections injectées `NotchSectionProviding`, scroll sans focus | `05 · N6 (squelette), REQ-NUI-32/33/35` |
| Banc de mesure des budgets (RAM, CPU, latence, démarrage à froid) — version initiale | `00 · T4, REQ-VIS-18..20` ; `01 · A9` |
| Logging OSLog + fichier tournant, catégories | `01 · §7.3` |

### Spikes (à traiter en premier)

- **VoiceOver × `NSPanel` non-activant** (`05 · risque 1`, cas limite 17) — plan B : activation temporaire si VoiceOver actif.
- **Niveau `.statusBar + 3` vs overlays système** (Spotlight, Centre de notifications) (`05 · risque 3`).
- **Coût GPU du matériau `behindWindow`** sur panel Ultra-wide (`05 · risque 4`) — instrumenter dès maintenant.

### Livrable démontrable (DoD manuelle)

Lancer l'app : aucune icône Dock ni entrée ⌘-Tab ; le pill noir se fond dans l'encoche (ou simule une encoche au ras du bord sur écran externe) ; survol ≥ 200 ms → panel vide animé (ressort ≈ 420 ms) ; traversée rapide → aucun flicker ; clic extérieur ferme ; pendant tout ça, le curseur texte de l'IDE au premier plan continue de clignoter ; débrancher/rebrancher un écran ne laisse aucune fenêtre orpheline.

### Critères de sortie

- `REQ-NUI-01..24, 32/33/35, 45..48` et `REQ-VIS-01..04` démontrés ; `lipo -archs` = `arm64`.
- CPU idle < 0,5 % notch fermé ; aucune invite TCC au lancement (`REQ-VIS-06`).
- `swift test` vert sur DashCore/TestSupport ; garde anti-destruction active (`REQ-TST-04`).
- App **bundlée** dès ce jalon (prérequis `UNUserNotificationCenter` de M5, `12 · cas limite 11`).

### Risques

Dimensions et wording du notch = hypothèses à calibrer visuellement sur les captures publiques d'AgentPeek (`05 · risque 2`) — passe de calibrage continue jusqu'à M6 (`05 · N11`).

---

## M1 — Lecture des sessions Claude Code (transcripts, mode fallback) (0.0.2)

**Objectif :** toutes les sessions Claude Code — passées et vivantes, terminal/IDE/desktop — apparaissent dans le panel, triées par projet, avec tokens mid-turn, diffs, timeline et actions, alimentées **sans hooks** (transcripts JSONL + registre PID uniquement).

### Tâches

| Tâche | Référence |
|---|---|
| Corpus de fixtures réelles anonymisées + outil d'anonymisation | `15 · T3/T4, REQ-TST-07..10` |
| `TranscriptTailer` FSEvents + offsets, chargement initial `mtime < 48 h` | `03 · REQ-CLA-20/28` ; `01 · §5.1` |
| Parseur JSONL tolérant : dédup `requestId`, `structuredPatch` → `DiffStats`, compteurs, extraits Markdown, titres | `03 · T-CLA-E, REQ-CLA-21..24, 26/27` |
| Subagents `isSidechain` agrégés (jamais de row séparée) | `03 · REQ-CLA-25` ; `07 · REQ-SES-11` |
| Registre `~/.claude/sessions/<pid>.json` + liveness PID + `SessionHost` + dédup `SessionID` | `03 · T-CLA-F, REQ-CLA-70..72` ; `07 · REQ-SES-08/09` |
| Machine à états **fallback** (executing/thinking/idle, jamais `waiting` inféré) | `03 · REQ-CLA-31` ; `02 · §3.3` ; `15 · REQ-TST-14` |
| `SessionStore.apply` + conflits de sources + tri/regroupement par projet + anti-sautillement | `07 · T1/T2, REQ-SES-01..07, 12` |
| Carte de session (3 lignes, chips, formats), avatars pixel-grid, `ActivitySummarizer` | `07 · T3/T4/T5, REQ-SES-17..29` ; `05 · REQ-NUI-52..54` |
| Row étendue : extrait Markdown Show more/less, timeline virtualisée + backfill 2 000 événements | `07 · T7/T8, REQ-SES-30..36` |
| Cycle de vie : `/clear` chaîné, resume mid-turn, fin/GC 24 h, reconnexion au démarrage | `03 · REQ-CLA-73..76` ; `07 · T6, REQ-SES-13..16` |
| Actions : Kill (garde-fous), Copy Session as Markdown, Dismiss, menu contextuel | `03 · REQ-CLA-77..79` ; `07 · T10/T11/T12, REQ-SES-37..41` |
| États vides + bannière « Install hooks » (mode lecture seule) | `07 · T13, REQ-SES-43/44` |

### Spikes

- **Cycle de vie du registre PID** (orphelins de crash, desktop visible dès le lancement) — hypothèse claude-code n°4 (`03 · REQ-CLA-71`).
- **Resume multi-fichiers `.jsonl`** — hypothèse claude-code n°7 (`03 · REQ-CLA-74`).
- **Prototype timeline** LazyVStack + insertions en tête (ancre de scroll) — `07 · risque 2`, avant T8.

### Livrable démontrable

Lancer `claude` dans deux projets + une session desktop : trois rows apparaissent groupées par projet, tokens « 24.6k / 66 » qui montent pendant le tour, diff +X/−Y, host correct (iTerm/Desktop) ; taper `/clear` → la row reste (« Cleared ») et la nouvelle prend sa place ; tuer/relancer AgentDash → liste reconstruite < 1 s sans doublon ; « Copy Session as Markdown » colle un export complet ; Kill + Confirm tue la session.

### Critères de sortie

- `REQ-SES` P0 verts (hors prompts) ; `REQ-CLA-20..28, 31, 70..79` verts.
- Couverture parseur AgentClaude ≥ 85 % ; tests machine à états pilotés par table (fallback).
- Aucun sur-comptage de tokens (dédup `requestId` vérifiée contre ccusage sur le transcript local).
- Démarrage à froid < 1 s sur le corpus local ; avatars en pause panel fermé (CPU idle tenu).

### Risques

Les règles de tri sont `[TRANCHÉ produit]` et peuvent diverger d'AgentPeek — comparateur unique testé, ajustable à coût nul (`07 · risque 3`).

---

## M2 — Hooks Claude Code + actions inline (« Act ») (0.0.3)

**Objectif :** l'installeur de hooks écrit `~/.claude/settings.json` de façon non destructive, l'IPC temps réel devient la source d'état primaire, et l'utilisateur répond aux permissions, plans et questions depuis le notch au clavier — avec fail-open absolu.

### Tâches

| Tâche | Référence |
|---|---|
| **Bancs d'hypothèses claude n°1/n°2** + timeout réel (`experiments/permission-request-interactive`, `ask-user-question-answers`) | `08 · A1` ; `03 · T-CLA-X0` |
| Binaire `agentdash-hook` (HookRelay) + protocole NDJSON + `HookServer` | `03 · T-CLA-B, REQ-CLA-10..14` ; `01 · §4.1, A1/A2` |
| `ClaudeHooksInstaller` : fusion non destructive, `.bak`, idempotence, désinstallation, statut « Ready » | `03 · T-CLA-A, REQ-CLA-01..08` ; `00 · REQ-VIS-16/17` |
| `EventRouter` : transitions T1–T16, classification décision/télémétrie, réconciliation hook/fallback | `03 · T-CLA-C, REQ-CLA-13, 30, 32..34` ; `02 · §3.1/3.3` |
| `PromptStore` + `DecisionEncoder` (formats JSON exacts) + auto-libération + obsolescence | `08 · A2/A3/A4, REQ-ACT-01..09` ; `03 · T-CLA-D, REQ-CLA-40..46, 48/49` |
| Always Allow : écho `permission_suggestions`, jamais persisté par AgentDash | `03 · REQ-CLA-42, 50/51` ; `08 · REQ-ACT-13` |
| Cartes Permission / Plan / Questions + prompts extensibles + « honest prompts » (`HonestCommandAnalyzer`) | `08 · A5/A6/A7/A11, REQ-ACT-10..23, 35` ; `03 · REQ-CLA-47` |
| Hotkeys éphémères ⌘A/⌘N/⌥A/⌥T (résolution AZERTY, suspension saisie, échecs remontés) | `08 · A9, REQ-ACT-24..29` ; `00 · REQ-VIS-22` |
| ⌥T `openHostApp` (chaîne ppid + table `term_program`) | `08 · A10, REQ-ACT-30` ; `03 · REQ-CLA-45` |
| File multi-prompts (« +N waiting », chevrons) | `08 · A8, REQ-ACT-31..34` |
| Auto-expand sur attention + `makeKey`/`resignKey` + focus champ texte | `05 · N9, REQ-NUI-20, 55/56` |
| Réglage « prompt handling location » (3 modes, court-circuit `.terminalOnly`) | `08 · A12, REQ-ACT-38` |
| Prototype du **self-test round-trip** (événement `__agentdash_selftest`) | `13 · REQ-SET-55` (anticipé) |
| Tests croisés HookRelay↔HookServer (vrai binaire) + harnais FakeAgent + scénarios P0 | `15 · T11/T12, REQ-TST-20/21` ; tests merge `15 · REQ-TST-17` |

### Spikes (bloquants, à faire avant tout le reste du jalon)

- **claude-code n°1** — comportement du dialogue terminal pendant la rétention `PermissionRequest` : conditionne toute l'UX « Act » et la sémantique de `promptHandling`. En cas de conflit dur : `.terminalOnly` par défaut, `.notch` opt-in (`08 · risque 1`).
- **claude-code n°2** — `allow + updatedInput.answers` en session interactive ; sinon feature flag fallback `deny + reason` (`08 · REQ-ACT-22`).
- **Gatekeeper/quarantaine sur le binaire copié** hors bundle — premier passage en build de dev signée ad hoc (hypothèse system-integration n°4 ; verdict définitif en M8 sur build Developer ID).
- **Consommation de ⌘A depuis le panel non-activant** (`08 · risque 4`).

### Livrable démontrable

Activer le toggle hooks → `settings.json` fusionné sans perte (diff vérifié), statut « Ready » ; dans une session **déjà ouverte**, déclencher `git push` → le panel s'auto-étend < 1 s, ⌘A depuis Safari répond Allow (le terminal affiche « Allowed by PermissionRequest hook ») ; « Deny with feedback » transmet le message ; ⌥A crée la règle à la destination annoncée ; plan → Approve/Reject ; question 2 choix → réponse inline ; **quitter AgentDash** → le dialogue natif du terminal apparaît immédiatement (fail-open) ; désactiver le toggle → `settings.json` identique à l'origine.

### Critères de sortie

- `REQ-ACT` P0 et `REQ-CLA-01..14, 40..51` verts ; latence hook → UI p95 < 150 ms au banc (`REQ-VIS-20`).
- Fail-open prouvé : app fermée, hook sort en < 50 ms exit 0 sans stdout (`15 · REQ-TST-20`).
- Zéro config par session démontré (`00 · REQ-VIS-14`) : rechargement à chaud des settings par Claude Code.
- Sans prompt visible, ⌘A garde son sens natif partout (hotkeys éphémères, `00 · critère 4`).

### Risques

Hypothèses n°1/n°2 invalidées = re-scoping du jalon (fallbacks prévus, l'UI ne change pas) ; deux répondeurs concurrents si AgentPeek est installé en parallèle (`00 · cas limite 5`) — documenté, revisité en M6 (check coexistence Doctor).

---

## M3 — Usage tokens Claude (jauges 5 h / 7 j) (0.0.4)

**Objectif :** jauges batterie 5 h/7 j alimentées par l'endpoint OAuth, avec countdowns exacts, rétention sur échec, reset au rollover, alertes de budget (logique), stats journalières locales et mode usage du pill.

### Tâches

| Tâche | Référence |
|---|---|
| **Banc endpoint `/api/oauth/usage`** : schéma réel, 401/429, label de compte | `09 · U13` ; hypothèse claude-code n°5 |
| `ClaudeUsagePoller` : Keychain à la demande, headers (`User-Agent` impératif), poll 180 s, relecture sur 401, back-off | `03 · T-CLA-H, REQ-CLA-60..63` ; `09 · U2, REQ-USG-01..03, 20/21` |
| `UsageStore` + `GaugeModel` + jauges batterie (seuils, hystérésis, clamp) | `09 · U1/U4, REQ-USG-15..19` |
| Countdowns et formats (« Resets in 2h 14m », « Refills Sun at 3:47 PM », 12/24 h) | `09 · U5, REQ-USG-08/09` |
| Rollover à date exacte + `didWakeNotification` | `09 · U6, REQ-USG-22/23` |
| Refresh manuel + anti-rafale 10 s + shimmer (header du panel, action de row) | `09 · U7, REQ-USG-31/32` ; `07 · REQ-SES-38` |
| `BudgetAlertEvaluator` (dédup fenêtre × seuil × cycle) — logique pure, câblage système en M5 | `09 · U8, REQ-USG-38/39` |
| Stats journalières : agrégateur incrémental + cache `daily-usage.json` + vue « Daily usage » | `03 · T-CLA-I` ; `09 · U9, REQ-USG-24..28` |
| Chip tokens mid-turn finalisé (`isLive`, point pulsant, tooltip cache) | `09 · U10, REQ-USG-41..44` |
| Mode usage du pill (mini-jauges, largeur verrouillée Wide/Ultra-wide) | `09 · U11, REQ-USG-35/36` ; `05 · REQ-NUI-26/27` |
| Comptes + santé par flux + « usage health notice » (badge ; onglet Doctor en M6) | `09 · U12, REQ-USG-29, 33/34` |
| Option countdown depuis 100 % + mise à jour immédiate au changement de réglage | `09 · REQ-USG-16, 37` |
| Tests UsageKit (rétention, rollover, alertes, formats) | `15 · T7, REQ-TST-15` |

### Spikes

- Schéma réel de `/api/oauth/usage` selon le plan (Pro/Max), présence email/organisation (label de compte) — claude-code n°5.
- Comportement 401 : la relecture Keychain suffit-elle (Claude Code rafraîchit lui-même) — `03 · REQ-CLA-62`.

### Livrable démontrable

Jauges 5 h/7 j conformes au `/usage` du CLI (±1 point, ±1 min) ; couper le Wi-Fi → valeurs **retenues** avec tooltip d'horodatage, jamais `--` ni régression ; rétablir → récupération sans redémarrage ; franchir un seuil configuré → exactement un événement d'alerte par cycle ; « Daily usage » cohérent avec ccusage ; activer le mode usage du pill → mini-jauges live, largeur verrouillée ; toggle usage off → zéro requête vers `api.anthropic.com` (proxy).

### Critères de sortie

- `REQ-USG` P0 (hors Cursor) et `REQ-CLA-60..66` verts ; invariant n°5 (`02 · §8.1`) testé.
- Étanchéité réseau partielle validée : seule destination observée = `api.anthropic.com` (`00 · REQ-VIS-12`).
- Agrégation initiale des stats < 1 s sur le corpus local (`09 · REQ-USG-46`).

### Risques

Endpoint non documenté (rupture possible sans préavis) → décodage tolérant + health notice + fixtures versionnées (`09 · risque 1`) ; le badge « check Doctor » pointe vers un onglet qui n'existe qu'en M6 (bannière provisoire acceptée).

---

## M4 — Serveurs locaux + Quick Routes + Fast Actions (0.0.5)

**Objectif :** le panel liste les serveurs de dev (ports 3000–9999) identifiés et pilotables (open/copy/stop sécurisé), les Quick Routes vers `~/.claude/*` et `~/.cursor/*`, et les Fast Actions (commandes shell sauvegardées). *Parallélisable avec M1–M3 (ne dépend que de M0).*

### Tâches

| Tâche | Référence |
|---|---|
| Scan libproc (LISTEN 3000–9999, fusion v4/v6, cadence 2 s/10 s, scan immédiat) | `10 · T1/T4, REQ-SRV-01..11` |
| Identification par process : `ProcessIdentity`, tables frameworks/runtimes/runner, cache par `(pid, start_time)` | `10 · T2/T3, REQ-SRV-12..22` |
| `ServerStore` + section « Local Servers » (rows, badges, uptime, indicateur de scan, état vide) | `10 · T5/T7, REQ-SRV-23..28` |
| Actions Open/Copy + Stop en deux temps avec garde-fous (re-validation, SIGTERM→SIGKILL, jamais killpg) | `10 · T6/T9, REQ-SRV-29..37` |
| Quick Routes : catalogue, résolveur d'existence hors MainActor, ouverture/révélation Finder, invalidation `hooksDidChange` | `11 · T1/T2, REQ-QRF-01..13` |
| Fast Actions : CRUD + persistance `fastActions.v1`, runner zsh (drainage, strip ANSI, tail 8 Ko), armement 2 temps, UI notch | `11 · T3/T4/T5, REQ-QRF-14..30` |
| Groupe Fast Actions dans Settings (éditeur sheet) — hébergé provisoirement, onglet complet en M6 | `11 · T6, REQ-QRF-23` |
| Bancs fixtures ANSI + tests identification par table | `11 · T7` ; `15 · T8, REQ-TST-16` |

### Spikes

- `npm_config_user_agent` présent pour npm/yarn/bun (vérifié seulement pour pnpm) — `10 · T10, REQ-SRV-16`.
- Chaîne de parents des runners (exec/reparentage) — `10 · REQ-SRV-21`.
- Calibrage du filtrage du bruit (`serverScanExclusions`) vs comportement AgentPeek — hypothèse produit n°7.
- Emplacement MCP user-scope `~/.claude.json` — `11 · REQ-QRF-11`.

### Livrable démontrable

`pnpm dev` (Next.js) + `python3 -m http.server 8000` → deux rows en ≤ 2 s avec badges corrects, dossier, uptime ; Open ouvre le navigateur sans activer AgentDash ; Stop → « Confirm? » 3 s → SIGTERM, la row disparaît ; chip « Config » révèle `settings.json` sélectionné dans le Finder ; le chip « Hooks » n'apparaît qu'après l'installation des hooks Cursor ; Fast Action `echo ok` : armement 2 temps, sortie `ok` + `exit 0` visibles ; `sleep 60` + Stop → terminé en < 4 s.

### Critères de sortie

- `REQ-SRV` P0 et `REQ-QRF` P0 verts ; scan médian < 5 ms ; test de conformité `lsof -F`.
- Aucun kill sans re-validation `(pid, start_time, execPath)` (invariant n°6, `02 · §8.1`).
- Aucun contenu de commande/sortie dans les logs (`11 · REQ-QRF-26`).

---

## M5 — Menu bar + notifications système (0.0.6)

**Objectif :** la seconde surface (status item + popover à sections plates, point orange d'attention) et le canal complet de notifications macOS (permission actionnable, budget, stuck, tâche terminée), articulés en trois canaux d'attention cohérents.

### Tâches

| Tâche | Référence |
|---|---|
| `MenuBarController` : status item, `StatusItemView` (icône + % usage + point orange), clic droit → Quit | `06 · T1/T2/T3, REQ-MBR-01..11` |
| Popover `.transient` : sections Usage (jauges + refresh partagé) / Local Servers (stop 2 temps) / Settings… | `06 · T4/T5/T6/T7, REQ-MBR-12..21` |
| Synchronisation stores partagés, coalescence, cadence de scan pilotée par visibilité, budget CPU | `06 · T8/T9, REQ-MBR-22..27` |
| `NotificationPlanner` (gating, dédup, throttling — logique pure testée) | `12 · T1, REQ-NOT-07..16, 27..31` |
| `NotificationCoordinator` : autorisation, catégories, actions Allow/Deny → `PromptStore` (`DecisionSource.notification`) | `12 · T2/T3, REQ-NOT-01..05, 17..23` ; `08 · REQ-ACT-39` |
| Câblage des déclencheurs (waiting/stale/Stop/usage) + retraits actifs + purge au lancement | `12 · T4, REQ-NOT-20, 31, 34` |
| Détection « stuck » (épisodes `isStale`, anti-faux-positif au réveil) | `12 · T8, REQ-NOT-10` ; `03 · REQ-CLA-33` |
| Hiérarchie des trois canaux d'attention (point orange / auto-expand / bannière) | `12 · REQ-NOT-32/33` |
| Câblage réel des alertes de budget de M3 sur le canal système | `09 · REQ-USG-38/39` ; `12 · REQ-NOT-09` |

### Spikes

- **`NSPopover` depuis un status item : activation/vol de focus ?** — plan B acté : `NSPanel` non-activant ancré (`06 · risque 1, REQ-MBR-13`).
- Auto-dimensionnement `NSHostingView` dans le bouton (`06 · §3.3`).
- `performClick` programmatique pour ouvrir le popover depuis une notification (`12 · REQ-NOT-18`).
- Deep link `x-apple.systempreferences` (panneau Notifications) sur macOS 14+ (`12 · REQ-NOT-03`).
- Livraison d'une action de notification à une app `LSUIElement` quittée (`12 · T9`).

### Livrable démontrable

Session en `waiting` → point orange animé sur l'icône < 1 s ; clic gauche → popover ancré avec jauges et serveurs, sans que l'IDE perde son statut actif ; clic sur une autre app → fermeture ; clic droit → « Quit AgentDash » (les agents continuent en natif) ; bannière « Permission required » avec Allow/Deny fonctionnels en arrière-plan ; la résolution par ⌘A retire la bannière du Centre de notifications ; alerte de budget une seule fois par cycle ; commande silencieuse 120 s → une notification « stuck » par épisode.

### Critères de sortie

- `REQ-MBR` P0 et `REQ-NOT` P0 verts ; toggles notch/menu bar réellement indépendants (4 combinaisons).
- Aucune notification pour une session dismissée/`ended` ; identifiants stables (remplacement, pas d'empilement).
- Contribution CPU idle de MenuBarUI ≤ 0,1 % (`06 · REQ-MBR-27`).

---

## M6 — Settings complets + Appearance + Doctor (0.0.7)

**Objectif :** la fenêtre Settings (sidebar 7 onglets, bouton power, effet immédiat) pilote tout le produit, l'onglet Appearance couvre toutes les options visuelles du notch, et l'onglet Doctor diagnostique et répare l'installation.

### Tâches

| Tâche | Référence |
|---|---|
| Fenêtre + sidebar redimensionnable + power button + positionnement anti-notch + points d'entrée | `13 · S1, REQ-SET-01..09` |
| `SettingsStore` : mutations typées, debounce, table d'effets de bord, états réels relus | `13 · S2, REQ-SET-06/07` |
| Onglet General : launch at login (`SMAppService`), toggles surfaces, prompt handling, cartes Agent hooks (Claude complète ; Cursor active en M7) | `13 · S3/S4, REQ-SET-10..16` |
| Onglet Notifications (toggles, seuils 50–100 %, test, bannière autorisation) | `13 · S5, REQ-SET-17..23` ; `12 · T5` |
| Onglet Appearance complet + reste de NotchUI : variantes du pill (hide when idle, expanded only), densités, growable, graisse, horloge, opacités, frosted rim, depth-lit, picker d'écran | `13 · S6, REQ-SET-24..35` ; `05 · N5/N6/N7 (reste), REQ-NUI-25, 28/29, 31, 34, 36..44` |
| Onglet Usage (toggles, états de connexion, compte, mesure Cursor — picker actif en M7, countdown, daily stats) | `13 · S7, REQ-SET-36..42` |
| Onglet Shortcuts (recorders, conflits, armement d'essai, bannière d'échec, Restore Defaults) | `13 · S8, REQ-SET-43..48` ; `08 · REQ-ACT-26` |
| DoctorKit : noyau + les 16 checks + remèdes en un clic + badge sidebar + re-checks 60 s | `13 · S9/S10/S11/S12, REQ-SET-49..65` |
| Self-test round-trip industrialisé (prototype M2 → check Doctor) | `13 · REQ-SET-55/56` |
| Onglet About (structure, logs, acknowledgements ; câblage Sparkle en M8) | `13 · S13/S14, REQ-SET-66, 68..70` |
| Accessibilité et finitions : VoiceOver, Reduced Motion/Transparency, cibles 24 pt, animations de liste/`/clear` | `05 · N10, REQ-NUI-49..51, 57..59` |
| Export de logs (zip + rapport Doctor JSON) | `13 · S14, REQ-SET-65` ; `01 · §7.3` |
| Infra snapshots + catalogue S1–S16 | `15 · T15, REQ-TST-25..27` |
| Passe de calibrage visuel vs références publiques AgentPeek | `05 · N11` |

### Spikes

- Key equivalents (⌘W, ⌘,) sans barre de menus visible (`13 · REQ-SET-09`).
- Sémantiques « hide when idle » / « expanded only » vs comportement réel AgentPeek (`05 · risque 5`).
- Effet réel de la quarantaine sur le binaire copié — check `13 · REQ-SET-54` (re-passage du banc system-integration n°4).

### Livrable démontrable

Ouvrir Settings depuis le popover : fenêtre redimensionnable, 7 onglets, bouton power rouge ; changer densité → Colossal et opacité pendant que le panel est ouvert → application < 1 frame ; supprimer `~/.agentdash/bin/agentdash-hook` → Doctor rouge, « Reinstall Helper » répare, round-trip repasse vert avec latence chiffrée ; écraser nos entrées de `settings.json` → « Needs repair » ≤ 60 s, Repair restaure sans toucher aux hooks tiers ; assigner ⌘N à Allow → « Conflict » ; quitter via power button avec un prompt en attente → dialogue natif dans le terminal.

### Critères de sortie

- `REQ-SET` P0 verts (hors parties Cursor/Sparkle différées) ; `REQ-NUI` P0/P1 restants verts.
- Doctor entièrement vert sur machine saine ; chaque panne simulée (socket, binaire, hooks) détectée avec remède.
- Snapshots S1–S16 enregistrés (baselines commitées) ; chaque réglage survit au redémarrage.

---

## M7 — Intégration Cursor (0.0.8 → parité MVP v0.1.0)

**Objectif :** sessions, permissions inline et usage mensuel Cursor au niveau AgentPeek v0.2.9–0.2.11, dans les mêmes surfaces et avec les capacités réduites documentées (bloc 5 de `00 · §1.4.1` limité aux permissions via hooks bloquants — pas de ⌥A ni de réponses inline) — le jalon clôt la **parité MVP** (`00 · REQ-VIS-25`).

### Tâches

| Tâche | Référence |
|---|---|
| **Bancs d'hypothèses cursor n°1/2/4/5/7/8** (identité, timeout, questions/plans, fraîcheur DB, usage réel) | `04 · T1, REQ-CUR-50` |
| `CursorHooksInstaller` : création/fusion de `~/.cursor/hooks.json`, statut Ready, désinstallation | `04 · T2, REQ-CUR-01..10` |
| `CursorEventNormalizer` : mapping des 15 événements → transitions C1–C9 | `04 · T3, REQ-CUR-11/12` ; `02 · §3.2` |
| Permissions inline Cursor : allow/deny/feedback/`ask`, capacités réduites (pas de ⌥A), auto-libération | `04 · T4, REQ-CUR-26..32` ; `08 · REQ-ACT-03, 12, 23` |
| `CursorStateReader` : lecture RO de `state.vscdb`, poll adaptatif, deltas, réconciliation, timeline paginée `bubbleId:` | `04 · T5/T6, REQ-CUR-13..20` |
| Transcripts Cursor (`agent-transcripts/*.jsonl`, corroboration `turn_ended`) | `04 · T7, REQ-CUR-21` |
| Subagents, excerpts, table de traduction des outils | `04 · REQ-CUR-19, 22/23` |
| `CursorUsagePoller` : JWT → cookie, `usage-summary`, 4 mesures, « $X of $Y », sous-barres, opt-out réseau | `04 · T8, REQ-CUR-33..42, 45/46` ; `09 · U3, REQ-USG-04/05, 10..13` |
| Stats journalières + comptes Cursor (`aiCodeTracking.dailyStats`, picker de compte, label sur cartes) | `04 · T9, REQ-CUR-43/44` ; `09 · REQ-USG-26, 29/30` |
| UX Cursor : chip de contexte « ctx 72% », cartes question/plan « Answer in Cursor », jauge mensuelle | `04 · T10` ; `07 · REQ-SES-23` |
| Doctor Cursor : checks hooks/DB/usage/`CursorCompat`, dégradation par flux | `04 · T11, REQ-CUR-47..49` ; `13 · REQ-SET-53/58/59` |
| Fixtures `state.vscdb` générées + tests concurrence SQLite + intégration bout en bout | `15 · T5, REQ-TST-11..13` ; `04 · T12` |
| Checklist de parité MVP + matrice de traçabilité à jour | `00 · T2/T6, REQ-VIS-25` |

### Spikes (bloquants, en tout début de jalon)

- **cursor n°1** — `conversation_id == composerId` (sinon la déduplication casse ; secours : corrélation `workspace_roots` + fraîcheur).
- **cursor n°2** — plafond réel du `timeout` des hooks Cursor (si < 60 s, les permissions inline Cursor sont quasi inactionnables → adapter l'auto-libération).
- **cursor n°5** — fiabilité dynamique de `hasBlockingPendingActions`/`generatingBubbleIds` pendant un tour réel.
- **cursor n°7/8** — réponses réelles `usage-summary` par plan (mapping Spend/Weighted/Auto/API à figer **avant** de geler l'UI).
- **cursor n°4** — `preToolUse` sur `ask_question`/`create_plan` (upgrade éventuel de l'affichage seul vers l'actionnable).

### Livrable démontrable

Activer le toggle Cursor → `hooks.json` créé (`version: 1`, 15 entrées), « Ready » ; lancer un tour agent dans Cursor → row < 150 ms après le premier hook, états thinking/executing, chip de contexte (jamais de compteur de tokens) ; commande shell → prompt dans le notch, ⌘A exécute sans toucher à Cursor, ⌥A absent ; prompt ignoré → `ask` à timeout − 10 s, dialogue natif Cursor ; trois conversations antérieures au lancement listées via `composerHeaders` ; jauge mensuelle « $12.07 of $20.00 » + date de reset ; `cursorUsageEnabled` off → zéro octet vers `cursor.com` (proxy) ; AgentDash quitté → prompt natif Cursor immédiat.

### Critères de sortie

- `REQ-CUR` P0 verts ; transitions C1–C9 testées par table ; aucune promesse UI au-delà des capacités (`AgentCapabilities`).
- **Parité MVP `REQ-VIS-25` démontrée** par la checklist scriptée (`00 · T6`) → tag interne `0.1.0-rc`.
- `grep -ri codex` sur le bundle = 0 ; aucun accès `~/.codex` (`00 · REQ-VIS-08`).

### Risques

Endpoints dashboard privés et schéma `state.vscdb` non contractuels = risque permanent (`04 · risques R1/R2`) — mitigé par `CursorCompat`, sondes, health notices et fixtures multi-versions ; toute rupture devient un item Doctor, jamais un crash.

---

## M8 — Onboarding + licensing + distribution (release 0.1.0)

**Objectif :** première release distribuable — onboarding welcome (≤ 3 interactions jusqu'à la première session), trial 48 h/licence one-time (si Go business), DMG signé et notarisé, mises à jour Sparkle horaires, pipeline CI complet.

**Préalable :** décision Go/NoGo licensing (`00 · T8`, risque R8) — si NoGo, `LICENSING_ENABLED = NO` retire tout le bloc trial/achat sans toucher au reste (`14 · REQ-LIC-28`) ; l'onboarding, Sparkle et le pipeline restent.

### Tâches

| Tâche | Référence |
|---|---|
| `OnboardingCoordinator` + fenêtre Welcome (étapes 1–4 : welcome, agents, notifications, launch at login) | `14 · T1/T2/T3, REQ-LIC-01..06, 08` ; `12 · T6` |
| Flag `LICENSING_ENABLED` + `LicenseManager` factice en mode off | `14 · T4, REQ-LIC-10, 28` |
| Trial 48 h anti-rollback (double stockage, `mach_continuous_time`, high-water mark, `tampered`) | `14 · T5/T6/T7, REQ-LIC-11..17` ; `15 · REQ-TST-19` |
| Worker Cloudflare + produit Lemon Squeezy + activation/validation/désactivation + reçu Ed25519 offline | `14 · T8/T9, REQ-LIC-18..27, 29/30` |
| UI : étape Unlock, écran d'achat, fenêtre d'activation, verrouillage de la pill | `14 · T10, REQ-LIC-07, 14` ; `05 · REQ-NUI-31` |
| Sparkle 2 (checks horaires, canal bêta) + fenêtre What's New + câblage About | `14 · T11/T12, REQ-LIC-31..38` ; `13 · REQ-SET-67, 71` |
| Pipeline : scripts release (séquence signature → notarisation → staple → DMG → appcast), CI GitHub Actions `macos-26` | `14 · T13/T14, REQ-LIC-39..46` |
| Site + page de download + `/download/latest` + hébergement `appcast.xml` (P2) | `14 · T16, REQ-LIC-47..49` |
| QA de release : checklist complète `plan/qa/checklist.md`, matrice de compatibilité, gates | `15 · T18/T19/T20, REQ-TST-34..41` ; `00 · T5/T6` |
| Audit final privacy : 24 h derrière proxy, 4 destinations exactement, toggles off = silence | `00 · REQ-VIS-12/13` ; `15 · REQ-TST-41 (9)` |

### Spikes

- **Gatekeeper sur le binaire copié en build Developer ID notarisée** — verdict définitif de l'hypothèse system-integration n°4 ; plan B : hooks `type:"http"` pour Claude (`01 · §2`).
- Ordre `stapler` vs signature EdDSA (D-L n°11) — test E2E de la chaîne d'update (`14 · REQ-LIC-45`).
- Keychain silencieux entre builds Debug/Release (D-L n°5) ; prompt notifications/fenêtre au premier plan en `LSUIElement` (D-L n°9) ; format de clé LS et appel de la License API (D-L n°1/3) ; stabilité des URL d'assets GitHub (D-L n°12).

### Livrable démontrable

Sur un Mac Apple Silicon vierge (macOS 14) : télécharger le DMG → glisser-déposer → lancement sans invite Gatekeeper (`spctl` accepte) ; onboarding `Continue` → `Install hooks` → `Start free trial` = 3 interactions, hooks « Ready », première session Claude visible < 2 min ; reculer l'horloge de 24 h → le temps d'essai restant ne remonte pas ; expiration (build 2 min) → écran d'achat sans redémarrage, pill grisée ; activation d'une clé → déblocage immédiat ; installer la version N−1 + appcast N → mise à jour proposée dans l'heure, What's New validable avec Entrée.

### Critères de sortie

- Les **10 gates de release** (`15 · REQ-TST-41`) tous verts, dont : QA P0 sur ≥ 2 OS (dont macOS 14), Doctor vert sur machine vierge, capture réseau conforme, mise à jour N−1 → N validée.
- `00 · REQ-VIS-23` (time-to-value), `REQ-VIS-27` (distribution), `REQ-VIS-28` (modèle économique, si Go) démontrés.
- Aucune hypothèse restante `[HYPOTHÈSE]` ne conditionne une feature annoncée (`15 · REQ-TST-41 (10)`).

### Risques

Bascule Lemon Squeezy → Stripe Managed Payments (plan B Paddle/Keygen, seul le Worker change) ; perte de la clé privée Sparkle = critique (procédure de sauvegarde froide `14 · REQ-LIC-44`) ; risque juridique/commercial du clone (`00 · R6`) — nom, marque et visuels propres à trancher avec `00 · T1` **avant** toute distribution publique.

---

## Tableau récapitulatif — jalon × fichiers du plan × REQ P0 couvertes

| Jalon | Build | Fichiers du plan principaux | REQ P0 couvertes (plages) | Spikes clés |
|---|---|---|---|---|
| **M0** Socle + shell notch | 0.0.1 | 00, 01, 02 (types), 05, 15 | REQ-VIS-01..04, 06, 09 · REQ-NUI-01..24, 32/33/35, 45..48 · REQ-TST-01..06 | VoiceOver × panel non-activant ; niveau de fenêtre ; coût GPU |
| **M1** Sessions Claude (transcripts) | 0.0.2 | 03 (§2.3/2.4/2.8), 07, 02 (§1–3, 7), 05 (avatars), 15 | REQ-CLA-20..28, 31, 70..79 · REQ-SES-01..27, 30..34, 37, 42..44 · REQ-NUI-52..54 · REQ-TST-07..10, 14 | Registre PID (claude n°4) ; resume multi-fichiers (n°7) ; proto timeline |
| **M2** Hooks + actions inline Claude | 0.0.3 | 03 (§2.1/2.2/2.5/2.6), 08, 01 (§4), 05 (focus), 15 | REQ-CLA-01..08, 10..14, 30, 32, 40..46, 48..50 · REQ-ACT-01..13, 16, 19..22, 24..29, 31/32, 34..36, 38, 40 · REQ-NUI-20, 55 · REQ-VIS-14..17, 22 · REQ-TST-17, 20/21 | **claude n°1 et n°2 (bloquants)** ; Gatekeeper (1ᵉʳ passage) ; ⌘A × panel |
| **M3** Usage tokens Claude | 0.0.4 | 09, 03 (§2.7), 15 | REQ-USG-01..03, 06, 08/09, 15..27, 29, 31..39, 41..43, 45/46 · REQ-CLA-60..63 | Schéma `/api/oauth/usage` + label compte (claude n°5) ; 401/Keychain |
| **M4** Serveurs + Quick Routes + Fast Actions | 0.0.5 | 10, 11, 15 | REQ-SRV-01..07, 12..20, 22..25, 28..34, 36/37 · REQ-QRF-01..05, 07, 09, 13..22 | `npm_config_user_agent` ; exclusions de scan ; `~/.claude.json` MCP |
| **M5** Menu bar + notifications | 0.0.6 | 06, 12, 09 (câblage alertes), 08 (route notif) | REQ-MBR-01..07, 09..25 · REQ-NOT-01..05, 07..12, 14..20, 23..29, 31..37 | Focus `NSPopover` ; `performClick` ; deep link ; action sur app quittée |
| **M6** Settings + Appearance + Doctor | 0.0.7 | 13, 05 (Appearance/a11y), 15 (snapshots) | REQ-SET-01..08, 10..22, 24, 29..33, 36/37, 39, 43..46, 49..60, 65/66, 69 · REQ-NUI-25..31, 34, 36..44, 49..51, 55..59 · REQ-TST-25..27 | Key equivalents `LSUIElement` ; sémantique pill ; quarantaine (re-check) |
| **M7** Intégration Cursor | 0.0.8 (→ 0.1.0-rc) | 04, 09 (§Cursor), 02 (C1–C9), 13 (checks Cursor), 15 | REQ-CUR-01..08, 11..19, 26..30, 33..40, 47/48 · REQ-USG-04/05, 10..13 · REQ-VIS-08, 25 · REQ-TST-11..13 | **cursor n°1/2/5/7/8 (bloquants)** ; n°4 (questions/plans) |
| **M8** Onboarding + licensing + distribution | 0.1.0 | 14, 13 (About/Sparkle), 12 (étape onboarding), 15 (release), 00 (audits) | REQ-LIC-01..05, 08, 10, 28 (P0) + REQ-LIC-11..46 (P1 si Go) · REQ-VIS-05, 07, 12/13, 23, 25 (validation finale) · REQ-TST-34, 37, 39..41 | **Gatekeeper build signée (verdict)** ; stapler × EdDSA ; Keychain ; LS |

Rappels transverses valables à chaque jalon : budgets `01 · A9` (RAM < 150 Mo, CPU idle < 0,5 %, hook → UI < 150 ms) vérifiés au banc ; fail-open (`01 · A10`) non négociable ; privacy (`00 · REQ-VIS-12/13`) contrôlée dès qu'une destination réseau s'ajoute (M3, M7, M8) ; matrice de traçabilité (`00 · T2`) mise à jour à la clôture de chaque jalon.
