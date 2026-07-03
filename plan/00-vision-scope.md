# 0. Vision, périmètre et non-objectifs

> Rédigé le 3 juillet 2026. Document fondateur du plan : tout autre fichier de `plan/` s'y réfère pour le périmètre, le vocabulaire et les principes produit. Conforme aux décisions actées de `plan/01-architecture.md` et au modèle de `plan/02-data-model.md`.
> Couvre les sections **1 (Vue d'ensemble)** et **14 (Périmètre de notre clone)** de `AGENTPEEK_FEATURES.md`, avec renvois ponctuels aux autres sections.
> Convention : **[VÉRIFIÉ]** = adossé aux docs officielles ou à une inspection locale déjà réalisée ; **[HYPOTHÈSE — à valider]** = déduction à confirmer en implémentation.

---

## 1. Objectif & périmètre

### 1.1 Pitch

**AgentDash** (nom provisoire) est une application macOS native (Swift/SwiftUI, Apple Silicon, macOS 14+) qui affiche en permanence l'état des agents de code IA — **Claude Code** et **Cursor** — depuis le **notch du Mac** et la **barre de menus**, pendant que l'utilisateur travaille sur autre chose. C'est une reproduction fonctionnelle complète d'**AgentPeek v0.2.11** (analysé le 3 juillet 2026), restreinte à ces deux agents.

- **Tagline de référence** (AgentPeek, §1 features) : « Your coding agents, in the Mac notch ». Le clone reprend le concept à l'identique ; la tagline définitive sera arrêtée avec le nom final (cf. §8, tâche T1).
- **Promesse** : voir en un coup d'œil ce que font tous ses agents (état, tokens, diffs, serveurs de dev), et **agir** sans changer de fenêtre (permissions, plans, questions) — le tout 100 % local, sans compte ni télémétrie.
- **Ce que le produit N'est PAS** : ni un terminal, ni un multiplexeur, ni un client de chat, ni un wrapper d'API LLM. Il n'exécute aucun agent : il observe et pilote des agents que l'utilisateur lance lui-même.

### 1.2 Personas

| Persona | Situation | Besoins couverts |
|---|---|---|
| **P1 — Le dev multi-agents** (persona principal) | Fait tourner 2 à 6 sessions Claude Code et/ou Cursor en parallèle sur plusieurs projets (terminaux, IDE, apps desktop), pendant qu'il code ou fait de la revue ailleurs | Savoir instantanément quelle session attend une permission, laquelle a fini, laquelle est bloquée ; répondre au clavier sans quitter sa fenêtre courante (§3, §4 features) |
| **P2 — Le dev économe en quota** | Abonnement Claude (fenêtres 5 h/7 j) et/ou Cursor (mensuel) ; craint de percuter ses limites en pleine journée | Jauges d'usage en permanence dans le pill/la menu bar, alertes de budget à seuil, stats journalières, heures de reset exactes (§5, §9 features) |
| **P3 — Le dev « full local »** | Refuse tout outil qui exfiltre ses prompts, transcripts ou diffs ; audite le trafic réseau de ses apps | Garantie zéro télémétrie, zéro compte, réseau limité à 2 destinations désactivables, tout l'état sur la machine (§12 features) |
| **P4 — Le vibe-coder desktop** | Utilise surtout Cursor et Claude Desktop, peu le terminal ; multiple serveurs `next dev`/`vite` oubliés en arrière-plan | Sessions desktop détectées dès le lancement, serveurs locaux listés avec open/copy/stop, Quick Routes vers les dossiers de config (§3.1, §6, §7 features) |

Anti-persona : l'utilisateur d'un seul agent occasionnel dans une seule fenêtre visible en permanence — le produit lui apporte peu ; ce n'est pas la cible des arbitrages.

### 1.3 Différenciateur

Reprise du différenciateur clé d'AgentPeek (§1 features), qui structure toute l'architecture :

> L'app « **sait réellement ce que font les agents** » — permissions demandées, usage de tokens, serveurs de dev locaux — au lieu d'afficher simplement la sortie du terminal.

Concrètement, cela se traduit par trois capacités qu'aucune menu bar app générique ni aucun multiplexeur de terminal n'offre :

1. **Compréhension sémantique** : hooks natifs des agents (source primaire temps réel) + transcripts JSONL + `state.vscdb`, normalisés en événements typés — pas de scraping d'écran ni de parsing de sortie ANSI.
2. **Actionnabilité** : les demandes de permission, plans et questions sont **répondables** depuis le notch (Allow/Deny/Always Allow/Deny with feedback/Approve/Reject/réponses texte), avec écho exact des `permission_suggestions` de Claude Code.
3. **Innocuité absolue** : fail-open partout — app fermée ou en panne, les agents continuent avec leurs dialogues natifs ; zéro changement de workflow, zéro configuration par session.

### 1.4 Périmètre exact

#### 1.4.1 Dans le périmètre (renvoi : §14 « À reproduire (cœur) » de AGENTPEEK_FEATURES.md)

| # | Bloc fonctionnel | Sections features | Fichier de plan détaillé |
|---|---|---|---|
| 1 | Hooks : installation/réparation auto Claude Code (`~/.claude/settings.json`) et Cursor (`~/.cursor/hooks.json`), statut « Ready », Doctor | §2.1, §10 | 03/04 (agents), Doctor |
| 2 | Notch UI : pill + panel, auto-expand, animations, Liquid Glass (fallback), écran externe | §2.2 | notch UI |
| 3 | Menu bar : résumé usage + serveurs, point orange d'attention, popover, clic droit → Quit | §2.2 | menu bar |
| 4 | Sessions : liste triée par projet, états executing/thinking/waiting/idle, tokens live input/output, diffs, timeline, subagents, Markdown, Copy as Markdown, Kill, dédoublonnage, desktop + terminal | §3 | sessions |
| 5 | Actions inline : permissions (⌘A/⌘N/⌥A), Deny with feedback, plans Approve/Reject, questions, ⌥T | §4 | prompts |
| 6 | Usage tokens : fenêtres 5 h/7 j Claude, mensuel Cursor (Spend/Weighted/Auto/API), jauges batterie, stats journalières, alertes budget, mode usage du pill | §5 | usage |
| 7 | Serveurs locaux : scan ports 3000–9999, frameworks/runtimes, open/copy/stop | §6 | serveurs |
| 8 | Quick Routes : `~/.claude/*`, `~/.cursor/*` (chemins existants uniquement) | §7 | notch UI |
| 9 | Fast Actions, notifications (permission/budget/stuck/complete), Settings complets (General/Notifications/Appearance/Usage/Shortcuts/Doctor/About) | §8, §9, §10 | settings/notifications |
| 10 | Onboarding + distribution DMG one-shot (mise à jour = remplacement manuel de l'app) | §11 | onboarding/distribution (14) |

Sur le point 10 : la section 14 des features le laissait « à décider » ; **la décision est actée** le 3 juillet 2026 — modèle **one-shot** : ni trial, ni licence, ni serveur d'activation, ni auto-update, ni site de téléchargement — zéro infrastructure distante propre. Le clone ne reproduit **pas** le modèle économique d'AgentPeek : l'app s'installe par glisser-déposer et se met à jour par remplacement manuel de `AgentDash.app` (cf. `plan/14-onboarding-distribution.md`).

#### 1.4.2 Hors périmètre (non-objectifs fermes)

| Non-objectif | Justification |
|---|---|
| **Support Codex** (`~/.codex/*`, sessions, usage) | Exclusion explicite du contexte projet et de §14 features. Aucun code Codex, aucune chaîne « Codex » dans l'app. L'architecture reste **extensible** : ajouter un agent = un nouveau package SPM implémentant les protocoles de la couche AgentAdapter (cf. §3.2), sans toucher à l'UI. |
| Support Intel (x86_64), Rosetta | Contrat produit AgentPeek : Apple Silicon uniquement (§1 features). |
| macOS 13 et antérieurs | Cible macOS 14+ actée (01-architecture §2). |
| Windows/Linux, iOS/iPadOS, app companion mobile | App macOS native uniquement. |
| Pilotage à distance, sync cloud, multi-machines, multi-utilisateurs | Contraire au principe « 100 % local ». |
| Lancement/orchestration d'agents (spawn de sessions depuis l'app) | AgentPeek observe et répond ; il ne lance pas d'agents. Fast Actions (commandes shell sauvegardées) est le seul mécanisme d'exécution, reproduit tel quel. |
| Édition de code, revue de diffs interactive, chat avec les agents | Les extraits/diffs sont affichés, jamais éditables ; répondre aux questions ≠ converser. |
| Analytics produit, crash reporting distant, A/B testing | Zéro télémétrie (§12 features). |
| Mac App Store | Incompatible (pas de sandbox — 01-architecture §2) ; distribution DMG Developer ID. |
| Localisation de l'UI | Interface 100 % anglais, comme AgentPeek (les textes exacts sont spécifiés dans chaque fichier de plan). |

#### 1.4.3 Prérequis système (renvoi : §1 features « Prérequis système »)

| Prérequis | Valeur | Vérification |
|---|---|---|
| Matériel | Mac Apple Silicon (M-series) uniquement — binaire arm64 pur | `lipo -archs` sur l'exécutable |
| OS | macOS 14.0 ou plus récent | `LSMinimumSystemVersion = 14.0` |
| Agents | Au moins un de : Claude Code (CLI/IDE/Desktop), Cursor. L'app se lance et fonctionne (serveurs, Fast Actions, Settings) même si aucun n'est installé — les surfaces agents affichent alors leur état vide | Détection `~/.claude` / `~/.cursor` (VÉRIFIÉ : présents sur cette machine, `~/.cursor` sans `hooks.json`) |
| Permissions | Aucune permission TCC, aucun droit admin | Aucune invite système au premier lancement (hors notarisation Gatekeeper standard et invite Keychain optionnelle pour l'usage Claude) |
| Réseau | Optionnel — toutes les fonctions locales marchent hors ligne ; seul le rafraîchissement d'usage Claude/Cursor en dépend | Test hors ligne |

### 1.5 Principes produit (invariants — toute décision future doit s'y conformer)

1. **100 % local** : transcripts, diffs, prompts, usage et état des sessions ne quittent jamais le Mac (§12 features).
2. **Zéro télémétrie, zéro compte, zéro analytics** : le produit ne sait rien de ses utilisateurs ; aucune activation, aucune licence — le réseau se limite à deux destinations d'usage opt-out (`api.anthropic.com`, `cursor.com`).
3. **Zéro configuration par session** : une installation unique des hooks ; toute nouvelle session est visible et pilotable sans aucune action (§2.1 features).
4. **Le workflow de l'utilisateur ne change pas** : les agents se lancent comme avant, dans n'importe quel terminal ou app ; AgentDash ne peut jamais les bloquer (fail-open absolu, 01-architecture §7.1).
5. **Natif et sobre** : Swift/SwiftUI, esthétique macOS (Liquid Glass avec fallback), app d'arrière-plan `LSUIElement` sans icône Dock ; budgets stricts RAM < 150 Mo, CPU idle < 0,5 % (01-architecture §6).
6. **Réversible et non intrusif** : fusion non destructive des configs tierces, sauvegardes `.bak`, désinstallation propre ; aucune API privée, aucune permission TCC.
7. **Honnêteté d'affichage** : jamais une hypothèse présentée comme un fait à l'utilisateur — jauges qui retiennent la dernière valeur datée plutôt que d'afficher du stale, `--` si aucune donnée, « usage health notice » si la précision est douteuse, prompts « honnêtes » pour les commandes shell qui écrivent.

### 1.6 Glossaire canonique

Vocabulaire unique du projet — à employer tel quel dans le code (identifiants anglais), l'UI (anglais) et les documents du plan (français). Les termes UI sont ceux d'AgentPeek.

| Terme | Définition |
|---|---|
| **Agent** | Programme de code IA supervisé : Claude Code ou Cursor (`AgentKind`, 02-data-model §1). |
| **Session** | Conversation/exécution d'un agent, identifiée de façon stable par `SessionID` = (agent, `sessionId` Claude \| `composerId` Cursor). |
| **Row / carte de session** | Ligne de la liste des sessions : avatar, état, activité récente, tokens, diffs, compteurs, hôte, temps écoulé, label de compte (§3.2 features). |
| **Session étendue** | Vue détaillée d'une row (clic) : extraits Markdown, timeline, subagents, actions Kill/refresh/Copy as Markdown (§3.3 features). |
| **État de session** | `executing` (un outil tourne) / `thinking` (le modèle génère) / `waiting` (attend l'utilisateur, sur signal explicite uniquement) / `idle` (tour terminé) — 02-data-model §3. |
| **Liveness** | Vitalité du processus de la session : `live` ou `ended(cleared/exited/killed/…)` — orthogonale à l'état. |
| **Stale / stuck** | Session `executing`/`thinking` sans événement depuis 120 s : flag `isStale` (notification « stuck »), sans changement d'état. |
| **Turn (tour)** | Cycle prompt utilisateur → travail de l'agent → `Stop`. « Mid-turn » : pendant le tour (les tokens se mettent à jour en direct). |
| **Notch** | Encoche physique de l'écran du Mac ; par extension, la surface UI d'AgentDash qui l'habille (simulée au ras du bord supérieur sur écran externe). |
| **Pill** | État réduit du notch : barre toujours visible (statut, compteur de sessions ou jauges en « mode usage »). |
| **Panel** | État étendu du notch : sessions, prompts, usage, serveurs, Quick Routes, Fast Actions. |
| **Auto-expand** | Ouverture automatique du panel quand un agent réclame l'attention (option). |
| **Hover intent** | Délai court avant expansion au survol, anti-flickering (défaut 200 ms). |
| **Menu bar / status item** | Seconde surface : `NSStatusItem` avec popover résumé ; « point orange » = indicateur d'attention. |
| **Hook** | Point d'extension natif d'un agent qui exécute notre binaire à chaque événement (config dans `~/.claude/settings.json` / `~/.cursor/hooks.json`). |
| **Hook bloquant / de décision** | Hook dont l'agent attend la réponse (permission, question, plan) — connexion IPC gardée ouverte. |
| **Hook de télémétrie** | Hook fire-and-forget (réponse vide immédiate) alimentant états et timeline. |
| **HookRelay / `agentdash-hook`** | Binaire compagnon ~56 Ko copié dans `~/.agentdash/bin/`, relais stdin → socket → stdout, zéro logique. |
| **Fail-open** | Toute panne d'AgentDash ⇒ silence côté hook (exit 0) ⇒ l'agent applique son comportement natif. Jamais l'inverse (fail-closed). |
| **Réparer (hooks)** | Resynchronisation du binaire (hash) + re-fusion des entrées de hooks manquantes ; déclenchée à chaque lancement et par le toggle Settings. |
| **Prompt actionnable / `PendingPrompt`** | Demande en attente affichée dans le notch : permission, plan ou question(s) — au plus un par session. |
| **Allow / Deny / Always Allow / Deny with feedback** | Décisions de permission ; Always Allow (⌥A) = écho des `permission_suggestions`, Claude Code uniquement. |
| **Plan (Approve/Reject)** | Proposition `ExitPlanMode` de Claude, approuvée ou rejetée avec message. |
| **Auto-libération** | Réponse vide envoyée à `timeout − 10 s` pour rendre la main au dialogue natif de l'agent sans le bloquer. |
| **Prompt handling location** | Réglage : où gérer les prompts (notch, terminal seul, les deux). |
| **Transcript** | Fichier JSONL de session (`~/.claude/projects/**` ; `~/.cursor/projects/*/agent-transcripts/`) — source de la timeline et des tokens. |
| **Tail / offset** | Lecture incrémentale d'un transcript depuis la dernière position connue (FSEvents + offsets). |
| **Timeline** | Historique horodaté des événements d'une session (tool calls résumés en langage clair, prompts, marqueurs) ; sans limite côté données, fenêtrée à 2 000 événements rendus côté RAM. |
| **Subagent** | Agent enfant d'une session (sidechain Claude, subcomposer Cursor) ; agrégé dans la session parente, jamais listé comme session. |
| **Dédoublonnage** | Garantie structurelle qu'une `SessionID` n'a qu'une row, toutes sources confondues. |
| **`/clear`** | Commande Claude qui clôt la session et en ouvre une nouvelle ; la row passe `ended(.cleared)` mais **reste listée**, chaînée à la nouvelle. |
| **Kill** | Arrêt d'une session (SIGTERM → SIGKILL) après re-validation (pid, start_time, execPath) ; Claude uniquement. |
| **Dismiss** | Masquage manuel d'une session terminal silencieuse (données conservées). |
| **Fenêtre d'usage** | Période de quota d'un compte : **5 h** et **7 jours** (Claude, avec « resets in… » / « refills Sun at 3:47 PM »), **mensuelle** (Cursor, cycle de facturation). |
| **Jauge batterie** | Représentation d'une fenêtre d'usage (vert → jaune → rouge, teinte de seuil près de la limite) ; option compte à rebours depuis 100 %. |
| **Rollover** | Bascule d'une fenêtre d'usage à son échéance → reset automatique des jauges. |
| **Rétention (jauges)** | Sur échec de refresh : conserver la dernière valeur datée (`isStale`) plutôt qu'afficher du faux ; `--` si jamais eu de valeur. |
| **Mesure Cursor** | Métrique mensuelle choisie : Spend, Weighted, Auto ou API ; affichage « $X of $Y ». |
| **Compte d'usage / account label** | Compte d'abonnement (Claude ou Cursor) sélectionnable dans Settings, affiché sur les cartes de session. |
| **Stats journalières** | Usage jour par jour (tokens, coût, lignes) reconstruit localement. |
| **Serveur de dev** | Processus en écoute sur un port 3000–9999, identifié (framework, runtime, package runner, projet, uptime) avec actions open/copy/stop. |
| **Quick Route** | Raccourci Finder vers un dossier/fichier de config d'agent ; seuls les chemins existants s'affichent. |
| **Fast Action** | Commande shell sauvegardée, exécutable depuis le notch. |
| **Doctor** | Onglet de diagnostic : santé des hooks, de l'installation, des flux et de la performance, avec correctifs guidés. |
| **Socket IPC** | `~/Library/Application Support/AgentDash/agentdash.sock` (0600) — NDJSON, 1 connexion = 1 requête. |
| **Liquid Glass / `agentGlass()`** | Matériau translucide macOS 26 ; modificateur maison avec fallback `NSVisualEffectView` sur macOS 14–25. |
| **Depth-lit / frosted rim** | Options d'apparence : cartes en relief/puits en creux ; liseré givré. |
| **Densité / largeur** | Réglages d'apparence : compact/regular/colossal ; normal/wide/ultra-wide (pill : Auto width). |
| **One-shot** | Modèle de distribution du produit : installation par glisser-déposer, sans auto-update ni licence ni activation ; mise à jour = remplacement manuel de `AgentDash.app` (réglages et sauvegardes `.bak` conservés, `~/.agentdash/bin` resynchronisé au lancement). |
| **Couche AgentAdapter** | Nom produit de l'ensemble des protocoles d'extensibilité agent de `DashCore` (`AgentProvider`, `UsageProvider`, `HooksInstaller`) — cf. §3.2. |

---

## 2. Exigences détaillées

Priorités : **P0** = indispensable au MVP ; **P1** = parité complète v0.2.11 ; **P2** = raffinement.

### Plateforme et identité produit

- **REQ-VIS-01 (P0)** — L'exécutable de l'app et le binaire `agentdash-hook` contiennent uniquement l'architecture arm64. Test : `lipo -archs` retourne exactement `arm64` pour les deux.
- **REQ-VIS-02 (P0)** — `LSMinimumSystemVersion` vaut `14.0` ; l'app se lance et fonctionne sur macOS 14.x, 15.x et 26.x. Test : lancement sur une machine/VM macOS 14 sans crash ni API manquante.
- **REQ-VIS-03 (P0)** — L'app est un agent d'arrière-plan : `LSUIElement = true`, aucune icône Dock, aucune barre de menus d'application ; Quit accessible via Settings (bouton power) et clic droit sur le status item. Test : lancement → aucun élément dans le Dock ni dans le Cmd-Tab.
- **REQ-VIS-04 (P0)** — Le nom provisoire « AgentDash » est utilisé partout (UI, bundle, `~/.agentdash/`, socket, logs) et aucune occurrence de « AgentPeek » n'existe dans le produit livré. Test : `grep -ri agentpeek` sur le bundle construit → 0 résultat.
- **REQ-VIS-05 (P0)** — Toute l'UI est en anglais (textes exacts spécifiés par les fichiers de plan de chaque surface). Test : revue visuelle de toutes les surfaces ; aucune chaîne française.
- **REQ-VIS-06 (P0)** — Aucune API privée n'est utilisée et aucune permission TCC n'est requise (ni Accessibility, ni Full Disk Access, ni Screen Recording). Test : premier lancement sans aucune invite TCC ; revue des symboles liés (`nm`/`otool`) sans framework privé.
- **REQ-VIS-07 (P0)** — L'app n'est pas sandboxée, avec hardened runtime activé, signée Developer ID. Test : `codesign -d --entitlements` ne montre pas `com.apple.security.app-sandbox` et montre le hardened runtime ; `spctl --assess` accepte l'app.

### Périmètre agents et extensibilité

- **REQ-VIS-08 (P0)** — Les agents supportés sont exactement Claude Code et Cursor : aucune chaîne « Codex » dans l'UI ou le bundle, aucun accès à `~/.codex`. Test : `grep -ri codex` sur le bundle → 0 résultat ; `fs_usage` pendant 10 min d'utilisation → aucun accès `~/.codex`.
- **REQ-VIS-09 (P0)** — Tout code spécifique à un agent vit dans son package (`AgentClaude`, `AgentCursor`) derrière les protocoles de la couche AgentAdapter de `DashCore` ; les modules UI ne dépendent d'aucun de ces deux packages (dépendances SPM vérifiées mécaniquement, 01-architecture §3.2). Test : inspection des `Package.swift` ; la compilation échoue si un import transverse est ajouté.
- **REQ-VIS-10 (P1)** — Les différences fonctionnelles entre agents (Always Allow, réponses inline, Kill, tokens par session…) sont pilotées par une structure de capacités (`AgentCapabilities`, §3.3) et jamais par des `if agent == .claudeCode` dispersés dans l'UI. Test : `grep -rn "\.claudeCode\|\.cursor" Packages/NotchUI Packages/MenuBarUI Packages/SettingsKit` → occurrences limitées au rendu identitaire (nom, avatar, couleur).
- **REQ-VIS-11 (P2)** — Démonstration d'extensibilité : un package d'exemple `AgentFixture` (agent factice pour les tests) implémente la couche AgentAdapter et apparaît dans l'app de dev sans modification des modules UI. Test : cible de test dédiée compilant `AgentFixture`.

### Principes produit (local, privé, innocuité)

- **REQ-VIS-12 (P0)** — Le trafic réseau sortant est limité à 4 destinations (`api.anthropic.com`, `cursor.com`, appcast Sparkle, Worker de licence), chacune désactivable ou absente selon les réglages. Test : 24 h derrière un proxy (Proxyman/Little Snitch) → aucune autre destination ; toggles off → plus aucune requête vers la destination correspondante. **Divergence assumée vs features §12** (qui ne liste que 3 destinations) : la source d'usage Claude (features §5.2, « données du `/usage` de Claude Code ») est l'endpoint `api.anthropic.com/api/oauth/usage` — le même appel que le `/usage` du CLI [HYPOTHÈSE — AgentPeek utilise vraisemblablement la même source]. Destination désactivable via `claudeUsageEnabled` (zéro requête si off). Écart consigné comme volontaire dans la matrice de traçabilité (REQ-VIS-26).
- **REQ-VIS-13 (P0)** — Aucun contenu utilisateur (prompt, réponse, diff, commande) ne quitte la machine ni n'apparaît dans les logs — identifiants, tailles et codes d'erreur uniquement. Test : inspection de `~/Library/Logs/AgentDash/` et des payloads réseau capturés après une session d'usage intensif.
- **REQ-VIS-14 (P0)** — Zéro configuration par session : après l'installation initiale des hooks, une nouvelle session (terminal, IDE ou desktop) apparaît dans la liste sans aucune action utilisateur — y compris les sessions Claude déjà ouvertes (rechargement à chaud des settings, VÉRIFIÉ doc). Test : hooks installés → ouvrir un nouveau terminal, lancer `claude`, soumettre un prompt → la session apparaît sans avoir touché AgentDash.
- **REQ-VIS-15 (P0)** — Fail-open absolu : AgentDash quittée, crashée ou saturée, chaque agent continue de fonctionner à l'identique (dialogues natifs), avec un surcoût par hook < 50 ms (spawn 2,7 ms + connexion en échec, mesurés — VÉRIFIÉ). Test : quitter AgentDash, déclencher une permission dans Claude Code → le prompt natif du terminal s'affiche normalement.
- **REQ-VIS-16 (P0)** — Réversibilité : désactiver un toggle de hooks retire uniquement les entrées AgentDash de la config tierce (les hooks tiers sont préservés) ; une sauvegarde `.bak` horodatée existe avant la première écriture. Test : config `settings.json` contenant un hook tiers → install puis uninstall → diff nul par rapport à l'origine ; `.bak` présent dans `~/.agentdash/backups/`.
- **REQ-VIS-17 (P0)** — Coexistence pacifique : la présence d'AgentPeek (ou de tout autre outil ayant ses propres hooks) ne casse ni AgentDash ni l'autre outil — fusion non destructive, aucun retrait d'entrées étrangères. Test : ajouter manuellement des hooks « tiers » simulés, installer AgentDash, vérifier que les deux jeux coexistent et que les agents fonctionnent.

### Performance et sobriété (budgets actés, 01-architecture §6)

- **REQ-VIS-18 (P0)** — RAM < 150 Mo (`phys_footprint`) en régime établi avec 5 sessions dont 2 actives et le panel ouvert. Test : mesure `footprint`/Activity Monitor après 2 h d'utilisation.
- **REQ-VIS-19 (P0)** — CPU < 0,5 % au repos (aucune session active, notch fermé) en moyenne sur 10 min. Test : `top -pid` / Instruments.
- **REQ-VIS-20 (P0)** — Latence hook → mise à jour UI < 150 ms (hors décision humaine). Test : banc de mesure horodaté (événement de hook synthétique → frame SwiftUI), 100 itérations, p95 < 150 ms.
- **REQ-VIS-21 (P1)** — Démarrage à froid < 1 s pour 100 Mo de transcripts récents ; l'auto-mesure (`task_info` toutes les 30 s) alimente Doctor et signale tout dépassement persistant des budgets. Test : corpus de transcripts synthétiques de 100 Mo ; onglet Doctor → section performance.

### Efficacité des flux (« sans souris ») et time-to-value

- **REQ-VIS-22 (P0)** — Flux sans souris : quand un prompt de permission est visible, l'utilisateur peut Allow (⌘A), Deny (⌘N), Always Allow (⌥A, Claude) et ouvrir le Terminal (⌥T) sans aucun clic, quelle que soit l'app au premier plan (hotkeys globales éphémères). Test : prompt affiché, focus dans Safari → ⌘A répond Allow à l'agent (et ne déclenche pas « Tout sélectionner » dans Safari) ; sans prompt visible, ⌘A dans Safari sélectionne tout.
- **REQ-VIS-23 (P0)** — Time-to-value : du montage du DMG à la première session visible dans le notch, ≤ 3 interactions d'onboarding et < 2 minutes (hors téléchargement). Test : chronométrage sur machine vierge avec Claude Code installé.
- **REQ-VIS-24 (P1)** — Réponse à une permission depuis son apparition dans le notch : réalisable en < 2 s par un utilisateur entraîné (auto-expand + hotkey). Test : chronométrage sur 10 essais.

### Parité fonctionnelle et distribution

- **REQ-VIS-25 (P0)** — Parité MVP : les blocs 1 à 8 du tableau §1.4.1 sont fonctionnels pour Claude Code, et les blocs 1 à 5 pour Cursor (le bloc 5 limité aux permissions via hooks bloquants — pas de ⌥A ni de réponses inline), alignés sur le contenu v0.1.0 d'AgentPeek étendu à Cursor. Test : checklist de démonstration scriptée (cf. §6).
- **REQ-VIS-26 (P1)** — Parité complète : chaque ligne des sections 2 à 12 de `AGENTPEEK_FEATURES.md` (hors mentions Codex) est couverte par une exigence d'un fichier de plan et implémentée. Test : matrice de traçabilité features → REQ maintenue dans le repo, sans trou.
- **REQ-VIS-27 (P1)** — Distribution : DMG signé Developer ID et notarisé, installable par glisser-déposer ; mises à jour Sparkle avec checks horaires. Test : téléchargement sur machine vierge → Gatekeeper accepte sans clic droit ; une mise à jour de test est proposée puis installée.
- **REQ-VIS-28 (P1)** — Modèle économique : essai gratuit 48 h puis licence one-time (1 licence = 1 Mac), déblocage immédiat à la saisie de la clé, écran d'achat immédiat à l'expiration sans redémarrage, manipulation d'horloge inefficace. Test : scénarios LicensingKit (trial, activation, rollback d'horloge).

### Méthode (exigence de processus)

- **REQ-VIS-29 (P0)** — Toute hypothèse marquée [HYPOTHÈSE] dans les fichiers de plan dispose d'un banc de validation dans `scripts/experiments/` exécuté **avant** l'implémentation de la feature dépendante (01-architecture §9). Test : revue de repo — chaque hypothèse numérotée référence son script et son résultat.
- **REQ-VIS-30 (P2)** — Le vocabulaire du glossaire (§1.6) est utilisé uniformément dans le code (identifiants anglais équivalents), l'UI et les documents. Test : revue de cohérence lors de chaque revue de PR (« pill » jamais appelé « bar », « panel » jamais « popup », etc.).

---

## 3. Conception technique

Ce document est un document de cadrage : la seule conception qui lui revient est la **frontière d'extensibilité agent** (la « couche AgentAdapter » promise en §1.4.2) et les **constantes d'identité produit**. Tout le reste appartient aux fichiers spécialisés.

### 3.1 Frontières du périmètre (vue d'ensemble)

```
                        ┌──────────────────────── AgentDash.app ───────────────────────┐
   DANS LE PÉRIMÈTRE    │  NotchUI · MenuBarUI · SettingsKit (UI, agnostiques agent)   │
                        │            ▲ observent les stores @Observable                │
                        │  DashCore : stores · machine à états · IPC · AgentAdapter    │
                        │            ▲ implémentent les protocoles                     │
                        │  AgentClaude          AgentCursor          [AgentFixture]    │
                        │  (~/.claude/*)        (~/.cursor/*)        (tests, REQ-11)   │
                        └───────────────────────────────────────────────────────────────┘
   HORS PÉRIMÈTRE          AgentCodex (~/.codex/*) — n'existe pas, mais le « slot »
   (extensible)            existe : mêmes protocoles, zéro modification UI requise.
```

### 3.2 Couche AgentAdapter — contrat d'extensibilité

Nom produit : « couche AgentAdapter ». Noms canoniques dans le code : les protocoles `AgentProvider`, `UsageProvider` et `HooksInstaller` de `DashCore` (actés en 01-architecture §3.1 — les signatures détaillées, méthode par méthode, sont fixées par les fichiers de plan des agents ; celles-ci en sont le squelette normatif) :

```swift
// DashCore — squelette normatif de la couche AgentAdapter.
public protocol AgentProvider: Sendable {
    var kind: AgentKind { get }                    // .claudeCode | .cursor (02-data-model §1)
    var capabilities: AgentCapabilities { get }    // cf. §3.3 — pilote l'UI, jamais de switch agent dans l'UI
    /// Détection locale : installé ? version ? chemins de config existants ?
    func detectInstallation() async -> AgentInstallation
    /// Démarre/arrête les flux d'ingestion propres à l'agent (transcripts, DB…).
    /// Les événements normalisés remontent en `DashEvent` (Sendable) vers l'EventRouter.
    func startIngestion() async
    func stopIngestion() async
}

public protocol HooksInstaller: Sendable {
    func status() async -> HooksStatus             // .ready / .notInstalled / .damaged(reason) / .agentMissing
    func installOrRepair() async throws            // fusion non destructive + .bak (REQ-VIS-16/17)
    func uninstall() async throws                  // retire uniquement les entrées AgentDash
}

public protocol UsageProvider: Sendable {
    var windows: [UsageWindowKind] { get }         // Claude : fiveHour/sevenDay(±Opus/Sonnet) ; Cursor : monthly
    func accounts() async throws -> [UsageAccount]
    func fetch(window: UsageWindowKind, account: UsageAccount.ID) async throws -> UsageWindow
}

public struct AgentInstallation: Sendable {
    public var isInstalled: Bool
    public var version: String?                    // nil si indéterminable
    public var configPaths: [String]               // chemins réellement présents (Quick Routes, Doctor)
}
public enum HooksStatus: Sendable, Equatable {
    case ready, notInstalled, agentMissing
    case damaged(reason: String)
}
```

Règles d'extensibilité (opposables en revue de code) :

1. Ajouter un agent = **un nouveau package SPM** dépendant uniquement de `DashCore`, enregistré dans la composition root de `AgentDashApp`. Aucun autre fichier ne change.
2. `AgentKind` est une enum ouverte par design (02-data-model §1) : un nouveau cas est un changement additif.
3. L'UI ne lit que les stores et `AgentCapabilities` ; l'identité visuelle (nom affiché, avatar, teinte) provient d'un `AgentIdentity` fourni par le provider — seul endroit où l'UI « connaît » un agent.
4. `agentdash-hook` est agnostique : l'argument `--source` inscrit dans la config du hook identifie l'agent (01-architecture §4.1) ; un nouvel agent réutilise le même binaire et le même socket.

### 3.3 `AgentCapabilities` — matrice normative Claude Code × Cursor

```swift
public struct AgentCapabilities: Sendable {
    public var supportsInlinePermissions: Bool     // prompt actionnable dans le notch
    public var supportsAlwaysAllow: Bool           // ⌥A + permission_suggestions
    public var supportsDenyWithFeedback: Bool
    public var supportsInlineQuestions: Bool       // réponses texte/choix inline
    public var supportsInlinePlans: Bool           // Approve/Reject
    public var supportsKill: Bool                  // PID connu et tuable
    public var supportsPerSessionTokens: Bool      // TokenTally par session
    public var supportsSubagents: Bool
    public var supportsDailyStats: Bool
    public var usageWindows: [UsageWindowKind]
}
```

| Capacité | Claude Code | Cursor | Source |
|---|---|---|---|
| Permissions inline | ✅ (`PermissionRequest`) | ✅ (`beforeShellExecution`/`beforeMCPExecution`) | VÉRIFIÉ (docs hooks) |
| Always Allow (⌥A) | ✅ (`permission_suggestions`) | ❌ (allow/deny/ask seulement) | VÉRIFIÉ ; alignement AgentPeek §4.1 |
| Deny with feedback | ✅ (message) | ✅ (`user_message`) | VÉRIFIÉ doc |
| Questions inline | ✅ (`AskUserQuestion` → `updatedInput.answers`) [HYPOTHÈSE claude-code n°2 en interactif] | ❌ (affichage seul) | 02-data-model §4.1 |
| Plans Approve/Reject | ✅ (`ExitPlanMode`) | ❌ (affichage seul, `hasPendingPlan`) | 02-data-model §3.2 C7 |
| Kill de session | ✅ (registre PID) | ❌ (pas de PID par session) | 02-data-model §2 |
| Tokens par session (input/output, mid-turn) | ✅ (transcripts, dédup `requestId`) | ❌ (contexte affiché à la place) | VÉRIFIÉ / HYPOTHÈSE cursor n°3 |
| Subagents | ✅ (`isSidechain`) | ✅ (`subagentInfo`) | VÉRIFIÉ |
| Stats journalières | ✅ (JSONL local) | ✅ (`aiCodeTracking.dailyStats`) | VÉRIFIÉ |
| Fenêtres d'usage | 5 h + 7 j (± Opus/Sonnet) | mensuelle (Spend/Weighted/Auto/API) | VÉRIFIÉ / HYPOTHÈSE cursor n°8 |

### 3.4 Constantes d'identité produit

| Constante | Valeur (provisoire) | Note |
|---|---|---|
| Nom affiché | `AgentDash` | Nom de code ; renommage global prévu (tâche T1) — aucune chaîne en dur hors `ProductIdentity` |
| Bundle ID | `com.<org>.agentdash` | `<org>` fixé avec le compte Developer ID |
| Dossier compagnon | `~/.agentdash/` (`bin/`, `backups/`, `debug`) | 01-architecture §4 |
| Support/état | `~/Library/Application Support/AgentDash/` (socket, `state/`) | idem |
| Logs | `~/Library/Logs/AgentDash/` | rotation 5 × 2 Mo |
| Versionnage | SemVer `0.x.y` calqué sur la roadmap (le MVP est `0.1.0`, comme AgentPeek) | §13 features comme guide d'ordre de construction |

Centralisation : une struct `ProductIdentity` dans `DashCore` expose ces constantes ; le renommage final = un seul fichier à changer (+ bundle id/entitlements).

---

## 4. Spécification UX/UI

Au niveau vision, seuls le ton et le vocabulaire de l'interface sont normés (chaque surface a son fichier de plan pour les layouts) :

- **Langue** : anglais uniquement (REQ-VIS-05). Ton : sobre, technique, sans emphase (« Ready », « Waiting for you », « resets in 2h 14m »).
- **Noms d'agents affichés** : `Claude Code` et `Cursor` (jamais « Anthropic », « Claude » seul ni « Cursor IDE »).
- **États affichés** (couleur + mouvement, jamais couleur seule — features §3.2) : `Executing`, `Thinking`, `Waiting`, `Idle`.
- **Textes canoniques transverses** (repris tels quels par les autres fichiers de plan) : boutons `Allow` / `Deny` / `Always Allow` / `Deny with feedback` / `Approve` / `Reject` / `Show more` / `Show less` / `Copy Session as Markdown` / `Kill` ; statut de hooks `Ready` ; onboarding `Start free trial` / `Enter license key` ; promesse d'achat `No subscription, ever.` ; ⌥T `Open Terminal`.
- **Sobriété** : l'app ne vole jamais le focus (panel non-activant), n'émet aucun son hors notifications opt-in, ne s'affiche pas dans le Dock. Le notch est « présent sans être là » : pill noire fondue dans l'encoche, animations discrètes (420 ms d'expansion, actée en 01-architecture §6).

---

## 5. Cas limites & gestion d'erreurs

Cas limites au niveau produit/périmètre (les cas techniques par flux vivent dans les fichiers spécialisés) :

1. **Mac Intel** : le binaire arm64 pur ne se lance pas ; la page de téléchargement et le README d'installation indiquent « Apple Silicon only » — aucun fallback Rosetta (non-objectif). Message d'erreur système standard assumé.
2. **macOS 13 ou antérieur** : Gatekeeper/launchd refuse (LSMinimumSystemVersion) ; documentation d'installation explicite.
3. **Aucun agent installé** (`~/.claude` et `~/.cursor` absents) : l'app se lance, l'onboarding affiche les cartes « Non détecté » avec liens d'installation (01-architecture §7.2) ; serveurs, Fast Actions et Settings restent fonctionnels ; aucune erreur bloquante.
4. **Codex installé sur la machine** (`~/.codex` présent) : ignoré totalement — pas de session fantôme, pas de Quick Route, aucun accès disque à ce dossier (REQ-VIS-08).
5. **AgentPeek installé et actif en parallèle** : les deux outils écrivent des hooks dans les mêmes fichiers — la fusion non destructive préserve les entrées AgentPeek ; les deux reçoivent les événements (Claude exécute tous les hooks correspondants — VÉRIFIÉ doc « tous doivent finir »). Risque résiduel : deux répondeurs pour une même permission ; comportement précisé dans le plan prompts [HYPOTHÈSE — à valider : quelle réponse gagne côté agent quand deux hooks bloquants répondent].
6. **Écran sans notch** (Mac mini/Studio + écran externe, MacBook pré-2021) : la surface notch se positionne au ras du bord supérieur (notch simulé, features §2.2) ; aucune fonctionnalité perdue.
7. **Machine hors ligne durable** : tout le local fonctionne ; jauges d'usage en rétention datée puis `--` pour les comptes jamais lus ; licence en grâce 14 j (02-data-model §6).
8. **Locale non anglaise / horloge 12 h** : UI reste en anglais ; format d'heure suit le réglage 12/24 h de l'app (défaut 24 h sur machine FR — 02-data-model §6.1).
9. **Utilisateur sans droits d'écriture sur `~/.claude/settings.json`** (permissions cassées) : l'installation de hooks échoue proprement → statut `damaged(reason)` + correctif guidé dans Doctor ; jamais de crash ni d'écriture partielle.
10. **Montée de version des agents** (format de hooks/transcripts modifié) : parseurs tolérants (types inconnus ignorés — 01-architecture §9), features concernées désactivées individuellement avec version plancher affichée dans Doctor ; jamais de dégradation globale.
11. **Retrait d'AgentDash** (suppression de l'app sans désinstallation) : les hooks orphelins pointent vers `~/.agentdash/bin/agentdash-hook` toujours présent → fail-open garanti même orphelin (exit 0 silencieux) ; les agents ne sont jamais cassés. La documentation décrit la désinstallation propre (toggle off avant suppression).
12. **Plusieurs utilisateurs macOS sur le même Mac** : chemins tous relatifs à `$HOME` → instances indépendantes ; le socket 0600 empêche la lecture croisée ; 1 licence = 1 Mac (pas 1 utilisateur) — assumé, identique à AgentPeek.

---

## 6. Critères d'acceptation

Scénarios vérifiables manuellement, au niveau vision (les scénarios fins par feature vivent dans leurs fichiers) :

1. **Étanchéité réseau** — Given un Mac avec proxy d'inspection installé et AgentDash configurée (usage Claude/Cursor activés), When on utilise l'app 24 h avec sessions actives, Then le journal du proxy ne contient que `api.anthropic.com`, `cursor.com`, l'hôte de l'appcast et l'hôte du Worker de licence ; When on désactive les quatre toggles correspondants, Then plus aucune requête sortante n'apparaît.
2. **Fail-open** — Given une session Claude Code active avec hooks installés, When on quitte AgentDash puis on déclenche une commande nécessitant une permission, Then le prompt natif du terminal apparaît sans délai perceptible et la session se poursuit normalement.
3. **Zéro config par session** — Given hooks installés hier, When on ouvre trois nouveaux terminaux et une fenêtre Cursor et on lance un prompt dans chacun, Then les quatre sessions apparaissent dans le notch sans qu'aucune action AgentDash n'ait été faite, triées par projet, sans doublon.
4. **Sans souris** — Given une permission visible dans le notch et le focus clavier dans une autre app, When on tape ⌘A, Then l'agent reçoit Allow et poursuit ; l'app au premier plan n'a pas reçu le raccourci ; When aucun prompt n'est visible, Then ⌘A garde son sens natif dans l'app au premier plan.
5. **Périmètre agents** — Given un dossier `~/.codex` peuplé (fixtures), When on utilise AgentDash 30 min, Then aucune session Codex n'apparaît, aucune Quick Route Codex n'existe et `fs_usage` ne montre aucun accès à `~/.codex`.
6. **Prérequis** — Given le DMG de release, When on l'ouvre sur un Mac Apple Silicon macOS 14 vierge, Then l'app s'installe par glisser-déposer, se lance sans invite TCC et affiche l'onboarding en moins de 2 minutes et 3 interactions jusqu'à la première session visible (Claude Code présent).
7. **Réversibilité** — Given un `~/.claude/settings.json` contenant des hooks tiers, When on active puis désactive les hooks AgentDash, Then le fichier final est identique à l'original (diff nul) et une sauvegarde `.bak` horodatée existe.
8. **Budgets** — Given 5 sessions dont 2 actives et le panel ouvert pendant 2 h, When on mesure, Then `phys_footprint` < 150 Mo ; Given aucune session active et notch fermé pendant 10 min, Then CPU moyen < 0,5 % ; Given le banc de latence, Then p95 hook → UI < 150 ms.
9. **Traçabilité de parité** — Given la matrice features → exigences du repo, When on la parcourt ligne à ligne contre `AGENTPEEK_FEATURES.md` §2–§12, Then chaque capacité (hors Codex) référence au moins une REQ d'un fichier de plan et son statut d'implémentation.
10. **Vocabulaire** — Given une revue croisée UI/code/plan, When on vérifie 10 termes du glossaire au hasard, Then chacun est employé de façon cohérente (même mot, même sens) dans les trois espaces.

---

## 7. Dépendances (autres fichiers du plan) et risques

### 7.1 Dépendances

- **Amont** : `AGENTPEEK_FEATURES.md` (référence produit), `plan/01-architecture.md` (décisions A1–A11, budgets, modules), `plan/02-data-model.md` (types, machine à états, capacités par agent).
- **Aval** : tous les autres fichiers de `plan/` héritent du périmètre (§1.4), des principes (§1.5), du glossaire (§1.6), de la matrice de capacités (§3.3) et des textes canoniques (§4). La matrice de traçabilité (REQ-VIS-26) est l'outil de contrôle transverse de la roadmap.

### 7.2 Risques produit

| # | Risque | Probabilité | Impact | Atténuation |
|---|---|---|---|---|
| R1 | **APIs privées Cursor** : `state.vscdb` (schéma `_v: 16`, `composerData`, `hasBlockingPendingActions`) et les endpoints dashboard ne sont pas documentés ; toute mise à jour de Cursor peut casser la lecture | Élevée | Moyen (dégradé, pas fatal) | Hooks Cursor officiels = source primaire ; DB = réconciliation seulement ; parseurs tolérants ; santé par flux + Doctor ; bancs de validation par version (REQ-VIS-29) |
| R2 | **Évolutions de Claude Code** : hooks (`PermissionRequest`, `updatedInput.answers`), format des transcripts, endpoint `/api/oauth/usage` non documenté publiquement | Moyenne | Élevé (cœur du produit) | Version plancher affichée dans Doctor, features désactivables individuellement, hypothèses claude-code n°1–2 validées avant implémentation, veille changelog |
| R3 | **Comportement hooks Cursor** (timeout réel, `conversation_id` == `composerId`) encore hypothétique | Moyenne | Moyen | Hypothèses cursor n°1–2 en tout début de roadmap (bancs `scripts/experiments/`) |
| R4 | **Gatekeeper sur le binaire hook copié hors bundle** (quarantaine, signature) | Moyenne | Élevé (le « zéro config » tombe) | Test en build signée réelle dès la première release interne (hypothèse system-integration n°4) ; plan B : hooks `type:"http"` pour Claude (01-architecture §2) |
| R5 | **Concurrence avec AgentPeek lui-même** (double répondeur de permissions si les deux sont installés) | Faible | Faible | Cas limite n°5 documenté ; détection de hooks AgentPeek dans Doctor avec avertissement |
| R6 | **Différenciation juridique/commerciale** : clone fonctionnel d'un produit payant existant (nom, textes, positionnement) | Moyenne | Moyen | Nom, marque et visuels propres (T1) ; aucun asset ni texte copié tel quel hors conventions d'UI génériques ; décision de distribution (privée/publique) avant toute publication |
| R7 | **Liquid Glass / macOS 26** : écart visuel entre fallback (macOS 14–25) et rendu 26 | Faible | Faible | `agentGlass()` avec les deux branches testées ; captures comparatives par release |
| R8 | **Modèle économique optionnel** : si la distribution retenue est privée/gratuite, LicensingKit devient du sur-coût | Moyenne | Faible | REQ-VIS-27/28 en P1 (pas MVP) ; LicensingKit isolé — retirable sans toucher au reste |

---

## 8. Découpage en tâches

| ID | Tâche | Taille | Livrable |
|---|---|---|---|
| T1 | Choisir le nom définitif, le bundle ID (`com.<org>.agentdash`) et la tagline ; créer `ProductIdentity` dans DashCore ; vérifier l'absence de collision de marque | S | Décision consignée + struct |
| T2 | Rédiger la matrice de traçabilité features → REQ (chaque ligne de `AGENTPEEK_FEATURES.md` §2–§12 → REQ d'un fichier de plan), maintenue dans `plan/traceability.md` | M | Matrice complète (REQ-VIS-26) |
| T3 | Implémenter le squelette de la couche AgentAdapter dans DashCore (`AgentProvider`, `HooksInstaller`, `UsageProvider`, `AgentCapabilities`, `AgentInstallation`, `HooksStatus`) + `AgentFixture` de test | M | Package compilant + tests (REQ-VIS-09/10/11) |
| T4 | Construire le banc de mesure des critères de succès : latence hook → UI, RAM, CPU, démarrage à froid (scripts reproductibles dans `scripts/experiments/perf/`) | M | Rapport de mesure exécutable (REQ-VIS-18–21) |
| T5 | Construire le banc d'étanchéité réseau (profil proxy + checklist 4 destinations + toggles) | S | Procédure + rapport (REQ-VIS-12/13) |
| T6 | Rédiger la checklist de démonstration MVP (scénarios §6 n°2, 3, 4, 6) rejouable à chaque release | S | Checklist versionnée (REQ-VIS-25) |
| T7 | Documenter la politique de coexistence et de désinstallation (hooks tiers, AgentPeek, retrait de l'app) + vérification Doctor associée | S | Section docs + check Doctor (REQ-VIS-16/17, cas limites 5 et 11) |
| T8 | Trancher la stratégie de distribution (publique payante / privée gratuite) et le Go/NoGo LicensingKit en P1 ; documenter dans le plan distribution | S | Décision consignée (R6, R8) |
| T9 | Mettre en place la revue de vocabulaire (glossaire §1.6 intégré au template de PR) | S | Template de PR (REQ-VIS-30) |

Ordre conseillé : T1 → T3 → T2 (la matrice référence les REQ des autres fichiers au fur et à mesure de leur rédaction) ; T4/T5 avant la première release interne ; T8 avant tout travail LicensingKit.
