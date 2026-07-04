# AgentPeek — Référence exhaustive des features

> Analyse complète de https://agentpeek.app/ (landing, docs, changelog, FAQ, pricing) au 3 juillet 2026 (version analysée : **v0.2.11**).
> Objectif : reproduire l'intégralité de ce logiciel pour **Cursor + Claude Code** (AgentPeek supporte aussi Codex ; noté ici pour référence mais hors scope de notre clone).

---

## 1. Vue d'ensemble

- **Nom** : AgentPeek
- **Tagline** : « Your coding agents, in the Mac notch »
- **Concept** : app macOS native (Swift) qui affiche en permanence l'état des agents de code IA (Claude Code, Codex, Cursor) depuis le **notch du Mac** et la **barre de menus**, pendant que l'utilisateur travaille sur autre chose.
- **Créateur** : Bren Huber (@brenhubr sur X), projet solo, mises à jour quotidiennes.
- **Différenciateur clé** (vs menu bar app / terminal multiplexer) : l'app « sait réellement ce que font les agents » — permissions demandées, usage de tokens, serveurs dev locaux — au lieu d'afficher simplement la sortie du terminal.

### Prérequis système
- Mac Apple Silicon (M-series) uniquement
- macOS 14 ou plus récent
- Application Swift native

---

## 2. Architecture / Fonctionnement

### 2.1 Système de hooks
- Au premier lancement, AgentPeek installe des **hooks partagés** pour Claude Code, Codex et Cursor — utilisés à la fois par les CLI et les apps desktop.
- Les hooks permettent de lire localement : prompts actifs, tool calls récents, diffs, demandes de permission en attente.
- Les **nouvelles sessions récupèrent automatiquement les hooks** — zéro configuration après l'installation.
- Aucun changement de workflow requis : fonctionne que l'agent tourne dans n'importe quel terminal ou dans son app desktop.
- Statut des hooks vérifiable dans **Settings → General → Agent hooks** (doit afficher « Ready » par outil).
- Toggle unique d'activation qui installe **et répare** les hooks (v0.1.1).
- Fichiers concernés (cf. Quick Routes) :
  - Claude Code : `~/.claude/settings.json`, `~/.claude/projects` (logs/sessions)
  - Cursor : `~/.cursor/hooks.json`
  - Codex : `~/.codex/config.toml`, `~/.codex/sessions`

### 2.2 Surfaces UI
Deux surfaces indépendantes, chacune togglable dans Settings :

1. **Notch** — deux états :
   - **Pill** (réduit) : barre toujours visible affichant statut / usage.
   - **Panel** (étendu) : détails complets des sessions, permissions, questions, usage tokens, serveurs locaux, Quick Routes.
2. **Menu bar** — surface résumé séparée : usage tokens + serveurs ; popover avec sections plates ; se ferme au clic sur une autre app ; point orange « attention » quand un agent attend l'utilisateur ; clic droit → Quit.

Comportements du notch :
- Auto-expand quand un agent réclame l'attention (option).
- Délai d'intention court au survol pour éviter le flickering (v0.1.20).
- Reste ouvert quand la fenêtre Settings a le focus.
- Positionné au ras du bord supérieur sur écran externe (simule un notch).
- Animations fluides d'ouverture/fermeture/changement de session (v0.2.11).

---

## 3. Monitoring des sessions (« Watch »)

### 3.1 Liste des sessions
- **Toutes les sessions** Claude Code / Codex / Cursor en un seul endroit, **triées par projet**.
- Sessions parallèles multi-projets visibles simultanément.
- Sessions détectées depuis le terminal **et** depuis les apps desktop (Claude Desktop, app Codex), avec tracking séparé.
- Les sessions desktop apparaissent dès le lancement, sans attendre une activité.
- **Déduplication** : les doublons de sessions sont fusionnés en une seule ligne.
- Reconnexion automatique des sessions en cas de connexion perdue.
- La commande `/clear` ne retire pas la session de la liste.
- Une session Claude relancée en cours de tour ne perd pas son dernier tour.

### 3.2 Carte de session (row)
Chaque ligne de session affiche :
- **Identité/avatar de l'agent** — avatar « pixel-grid » animé : vague diagonale quand actif, rotation calme quand en attente.
- **État** : executing / thinking / waiting / idle — indiqué par **couleur + mouvement**.
- Activité récente (dernier événement en langage clair).
- **Usage tokens par session** : compteurs séparés input/output (ex. « 24.6k / 66 »), mis à jour en direct **pendant** le tour (mid-turn), suivant le contexte live.
- Compteurs de fichiers et de commandes.
- **Stats de diff** (lignes ajoutées/supprimées).
- Environnement hôte (terminal vs desktop app).
- Temps écoulé.
- **Label de compte** : compte d'abonnement affiché sur la carte de session.

### 3.3 Session étendue (clic sur une row)
- Extraits des réponses de l'agent (**rendu Markdown** + extraction plain-text).
- Réponses longues repliables : « Show more / Show less ».
- **Timeline d'événements** : historique horodaté de **tous les tool calls**, résumés en langage clair ; sans limite d'historique (cap supprimé) ; performant jusqu'à des milliers d'entrées.
- **Activité des subagents** remontée dans les sessions Claude et Codex.
- Actions rapides sur la row : **Kill** (tuer la session), **refresh usage**.
- Menu contextuel : **« Copy Session as Markdown »**.
- Sessions terminal silencieuses dismissables.

---

## 4. Actions inline (« Act »)

### 4.1 Permissions
- Les demandes de permission apparaissent **directement dans le notch**, sans changer de fenêtre.
- Raccourcis clavier :
  - **⌘A** : Allow
  - **⌘N** : Deny
  - **⌥A** : Always Allow (Claude Code uniquement)
  - **⌥T** : Ouvrir le Terminal
- Bouton **« Deny with feedback »** (refus avec message).
- Prompts « plus honnêtes » pour les commandes shell qui écrivent des fichiers (reformulation côté AgentPeek).
- Prompts extensibles (permission / plan / multi-questions).
- Réglage : où gérer les prompts (notch vs ailleurs) — « prompt handling location ».

### 4.2 Plans
- Revue et approbation des **plans** proposés par l'agent avant exécution.
- Boutons **Approve / Reject** (au lieu d'Allow/Deny).
- Titres de plan stylisés.

### 4.3 Questions
- Répondre aux **questions de l'agent** inline depuis le notch (réponse texte), sans switcher de fenêtre.
- Support des prompts multi-questions.

---

## 5. Suivi de l'usage de tokens

### 5.1 Fenêtres suivies
| Agent | Fenêtres |
|---|---|
| Claude Code | **5 heures** (court terme, countdown « resets in… ») + **7 jours** (« refills » avec jour et heure exacts, ex. « refills Sun at 3:47 PM ») |
| Codex | 5 heures + 7 jours (idem) |
| Cursor | **Mensuel** (mois de facturation en cours + date de reset) |

### 5.2 Détails
- Source Claude : données du `/usage` de Claude Code.
- Source Cursor : **dashboard live** du compte Cursor (lecture via la session Mac existante, pas de login séparé) — remplace l'ancien feed legacy.
- Cursor : choix de la mesure mensuelle — **Spend, Weighted, Auto, ou API** ; affichage « $X of $Y » selon le plan ; barres optionnelles Auto/Composer et API dans la vue détail du notch.
- Sélection du **compte d'usage** (Claude, Codex ou Cursor) dans Settings (multi-comptes).
- Affiche `--` quand l'usage est indisponible ; les jauges **retiennent** la dernière valeur plutôt que d'afficher du stale en cas d'échec de refresh ; récupération après hiccups.
- Reset automatique des jauges quand la fenêtre 5h/7j bascule.
- **Statistiques d'usage jour par jour**.
- Jauges style **batterie** (vert → jaune → rouge) ; teinte de seuil près de la limite.
- Option : compte à rebours **depuis 100 %** au lieu de monter.
- Bouton refresh usage dans le header du notch et le popover menu bar ; shimmer pendant le refresh.
- Mises à jour de jauge immédiates au changement de réglage.
- « Usage health notice » pointant vers le Doctor si la précision est douteuse.
- **Mode usage** du pill réduit : jauges d'usage live directement dans le pill (largeur verrouillée Wide/Ultra-wide en mode usage, « Auto width »).

---

## 6. Serveurs de dev locaux

- **Scan des ports 3000–9999** pour détecter les serveurs en écoute (indicateur de scan visible).
- **Détection de frameworks** : Next.js, Vite, Astro, Wrangler, Storybook, Playwright, serveurs de sites statiques.
- **Détection de runtimes** : Node, Bun, Deno, Python, Ruby, Rust, Go.
- Détection cohérente du **package runner** (npm/pnpm/yarn/bun…).
- Chaque ligne serveur affiche : **port, dossier projet, détails du process, uptime**.
- Actions : **ouvrir l'URL**, **copier l'URL**, **arrêter le serveur** (avec garde-fous / tap de confirmation dans la menu bar).
- États vides soignés ; sizing « list-style ».

---

## 7. Quick Routes

Raccourcis vers les dossiers fréquents des agents, ouverts dans le **Finder** ; seuls les chemins existants s'affichent :

| Route | Chemins |
|---|---|
| Skills | `~/.claude/skills` · `~/.codex/skills` |
| Plugins | `~/.claude/plugins` · `~/.codex/plugins` |
| Config | `~/.claude/settings.json` · `~/.codex/config.toml` |
| Logs | `~/.claude/projects` · `~/.codex/sessions` |
| Hooks | `~/.cursor/hooks.json` |
| Root | `~/.claude` · `~/.codex` · `~/.cursor` |

(MCP servers également accessibles d'après la landing : « Jump to skills, plugins, MCP servers, config, or logs ».)

---

## 8. Fast Actions

- Sauvegarder et exécuter des **commandes shell** directement depuis le notch (v0.2.5).

---

## 9. Notifications

Notifications système macOS natives, avec :
- **Toggle maître** + options de son.
- **Demandes de permission** (agent en attente).
- **Alertes de budget** : seuils configurables **50–100 %** pour les fenêtres 5h et 7j.
- **Alertes de session bloquée** (« stuck-session »).
- **Alertes de tâche terminée** — déclenchées quand l'agent finit son tour.
- Fonction **« Test notification »** depuis Settings.
- Prompts de mise à jour avec l'icône de l'app ; fenêtre « What's New » validable avec Entrée.

---

## 10. Settings (fenêtre redimensionnable, navigation sidebar)

### General
- Launch at login
- Toggles indépendants notch / menu bar
- Auto-expand sur attention
- Emplacement de gestion des prompts
- Gestion des hooks d'agents (statut « Ready », installer/réparer)

### Notifications
- Cf. section 9.

### Appearance
- Largeurs réduites/étendues (dont **Ultra-wide**) ; picker de largeur compact
- **Densité** (dont option « Colossal »)
- Taille de la liste de sessions : **fixe ou growable** (croît jusqu'à la hauteur de l'écran avant de scroller)
- Graisse des titres
- Horloge 12h/24h
- Options du pill : count / usage / hide when idle / expanded only
- **Liquid Glass** : slider d'opacité (avec option Opaque), toggles de « frosted rim », profondeur et couleurs raffinées, interface « depth-lit » (cartes en relief, puits en creux)
- Slider d'**opacité des métriques** (lisibilité du texte du notch)

### Usage
- Onglet consolidant tous les toggles d'usage par agent, sélection de compte, mesure Cursor (Spend/Weighted/Auto/API), barres optionnelles.

### Shortcuts
- Onglet listant tous les raccourcis ; avertissement en cas d'échec d'enregistrement d'un raccourci ; ⌘, ne rentre pas en conflit avec la fenêtre Settings système.

### Doctor
- Onglet de **diagnostic** : problèmes de hooks et d'installation, performance, correctifs guidés.

### About
- Vérification de mises à jour (checks **horaires**, via **Sparkle**), réglage Update
- Liens documentation, accès aux fichiers de log, remerciements
- Bouton Quit (bouton power rouge en haut à gauche des Settings)

---

## 11. Onboarding & Licensing

### Onboarding
- **Welcome guidé en fenêtre** pour connecter Claude et Codex (et Cursor).
- Choix au premier lancement : « Start free trial » (2 jours) ou saisie de clé de licence.

### Modèle économique
- **Essai gratuit 2 jours**, puis **licence one-time 15 $** — « No subscription, ever ».
- Inclut : toutes les features actuelles, sessions illimitées, **toutes les mises à jour futures**.
- 1 licence = 1 Mac Apple Silicon ; migration matérielle peut nécessiter une réactivation.
- Activation : fenêtre dédiée avec carte de licence et champ de clé inline ; déblocage immédiat à la saisie.
- Fin d'essai → écran d'achat immédiat sans redémarrage.
- Anti-triche : faille de manipulation de l'horloge système fermée (v0.2.9).
- La vérification de licence transmet uniquement : clé, machine ID, version de l'app.

### Distribution
- DMG **signé et notarisé**, téléchargeable sur `agentpeek.app/download/latest` ; glisser dans Applications.
- Mises à jour via **Sparkle**.

---

## 12. Privacy

- Transcripts de session, diffs, prompts et usage de tokens **restent sur le Mac**.
- **Aucun compte, aucune analytics, aucune télémétrie.**
- Accès réseau limité à : vérification de licence, checks de mise à jour Sparkle, lecture optionnelle de l'usage Cursor (via le sign-in Mac existant).
- État des sessions stocké localement.

---

## 13. Historique complet des versions (changelog)

> Utile pour comprendre l'ordre de construction des features et prioriser notre roadmap.

| Version | Date | Contenu |
|---|---|---|
| v0.1.0 | 30 avr. 2026 | MVP : sessions live Claude Code + Codex dans le notch ; permissions/questions/plans inline ; jauges 5h/7j ; serveurs dev locaux (stop/copy/open) ; Quick Routes ; installeur de hooks ; licence 15 $ |
| v0.1.1 | 4 mai | Toggle unique install/réparation des hooks ; reconnexion auto des sessions |
| v0.1.2 | 7 mai | Picker de largeur ; notch ouvert pendant Settings ; labels framework serveurs ; uptime |
| v0.1.3–0.1.5 | 10 mai | Releases signées fiables ; checks de MàJ horaires ; fixes UI |
| v0.1.6 | 11 mai | Landing : panneau sessions aligné sur la carte in-app |
| v0.1.7 | 17 mai | Notifications système (permission/budget/stuck/complete) ; Copy Session as Markdown ; actions Kill + refresh usage ; teinte de seuil sur les barres |
| v0.1.8 | 22 mai | Docs réorganisées (install/configure/troubleshoot) ; réglages notifications étendus ; couleurs d'activité adoucies |
| v0.1.9–0.1.10 | 26–29 mai | Multi-écrans/Spaces fixes ; prompts de MàJ ; What's New |
| v0.1.11 | 1 juin | Toggles indépendants notch/menu bar ; avatars pixel-grid animés ; comportement unifié Claude/Codex ; suppression du cap d'historique |
| v0.1.12 | 2 juin | Lectures d'usage Codex fiables ; fix état waiting→running ; bouton power Quit |
| v0.1.13 | 2 juin | Panneaux plus spacieux ; heures de refill exactes ; horloge 12/24h ; **activité subagents** ; popover menu bar aplati |
| v0.1.14–0.1.16 | 3–5 juin | Liste de sessions fixe/growable ; fenêtre d'activation ; interface depth-lit |
| v0.1.17–0.1.19 | 7–8 juin | Meilleur tracking des limites ; prompts extensibles ; reset des jauges au rollover ; `/clear` conserve la session ; activation fiable |
| v0.1.20–0.1.21 | 10 juin | **Mode usage** dans le pill réduit ; point orange menu bar ; anti-flicker au survol ; Auto width |
| v0.1.22–0.1.23 | 14 juin | Fiabilité usage ; réponses longues Show more/less ; perf timelines massives |
| v0.1.24–0.1.25 | 16 juin | Usage Claude via `/usage` ; meters qui retiennent au lieu d'afficher du stale ; labels serveurs (Astro, Next.js, Vite, Wrangler, Storybook, Playwright) |
| v0.1.26–0.1.28 | 18–20 juin | Fixes crashs ; customisation Liquid Glass ; test notification ; écran d'achat à la fin d'essai |
| v0.1.29–0.1.32 | 21–22 juin | **Support desktop apps** (Claude Desktop, Codex) ; split tokens input/output ; sessions desktop sans doublons ni délai |
| v0.2.0 | 28 juin | Welcome guidé ; sessions plus fiables ; dédoublonnage ; usage précis avec comptes live ; Liquid Glass amélioré |
| v0.2.1–0.2.4 | 29 juin | Fixes onboarding, doublons Codex/Git ; ingestion resserrée ; **rendu Markdown des réponses** ; sizing serveurs |
| v0.2.5 | 30 juin | **Fast Actions** (commandes shell depuis le notch) ; Ultra-wide + densité Colossal |
| v0.2.6–0.2.7 | 30 juin–1 juil. | **Stats d'usage jour par jour** ; onglet **Doctor** ; réductions RAM/CPU |
| v0.2.8 | 1 juil. | Slider d'opacité + Opaque ; countdown depuis 100 % ; clic droit menu bar → Quit ; fix Always Allow |
| v0.2.9 | 2 juil. | **Support Cursor** (sessions, permissions, usage mensuel) ; Settings sidebar redimensionnables ; onglets Usage et Shortcuts ; label de compte ; prompts « honnêtes » ; notifications de fin de tâche ; anti-triche horloge |
| v0.2.10 | 2 juil. | Usage Cursor via dashboard live ; mesures Spend/Weighted/Auto/API ; affichage « $X of $Y » ; usage health notice |
| v0.2.11 | 3 juil. | Sélection de compte d'usage ; opacité des métriques ; jauges batterie ; token chip mid-turn ; animations de sessions |

---

## 14. Périmètre de notre clone (Cursor + Claude Code)

### À reproduire (cœur)
1. **Hooks** : installation/réparation auto pour Claude Code (`~/.claude/settings.json` — hooks natifs Claude Code) et Cursor (`~/.cursor/hooks.json`), avec statut « Ready » et onglet Doctor.
2. **Notch UI** : Pill + Panel, auto-expand, animations, Liquid Glass, support écran externe.
3. **Menu bar** : résumé usage + serveurs, point d'attention, popover.
4. **Sessions** : liste triée par projet, états (executing/thinking/waiting/idle), tokens live input/output, diffs, timeline des tool calls, subagents, Markdown, Copy as Markdown, Kill, dédoublonnage, desktop + terminal.
5. **Actions inline** : permissions (⌘A/⌘N/⌥A), Deny with feedback, plans Approve/Reject, réponses aux questions, ⌥T terminal.
6. **Usage tokens** : fenêtres 5h/7j Claude (via `/usage`), mensuel Cursor (Spend/Weighted/Auto/API), jauges batterie, stats journalières, notifications de budget, mode usage du pill.
7. **Serveurs locaux** : scan ports 3000–9999, frameworks/runtimes, open/copy/stop.
8. **Quick Routes** : `~/.claude/*`, `~/.cursor/*`.
9. **Fast Actions**, **Notifications** (permission/budget/stuck/complete), **Settings** complets (General/Notifications/Appearance/Usage/Shortcuts/Doctor/About).

### Hors scope (spécifique AgentPeek)
- Support Codex (`~/.codex/*`).
- Licence, trial, activation, auto-update (Sparkle) et site web — **DÉCISION du 3 juillet 2026 : hors scope définitif.** Modèle « one-shot » : mise à jour = désinstaller/remplacer l'app par la nouvelle version manuellement.

### Principes à conserver
- 100 % local, zéro télémétrie, zéro compte.
- Zéro configuration par session ; le workflow de l'utilisateur ne change pas.
- Natif Swift, Apple Silicon, macOS 14+.
