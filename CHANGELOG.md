# Changelog

Toutes les versions notables d'AgentDash. Format inspiré de [Keep a Changelog](https://keepachangelog.com).
La CI extrait la section de la version taguée comme notes de release.

## 0.1.0

Première version distribuable — clone d'AgentPeek pour Claude Code + Cursor.

### Ajouté
- Surface notch (pill/panel) avec morphose animée et Liquid Glass (fallback macOS 14)
- Sessions Claude Code (transcripts JSONL) et Cursor (state.vscdb) triées par projet
- Actions inline : permissions, plans et questions répondables au clavier (⌘A/⌘N/⌥A)
- Usage de tokens : Claude 5 h/7 j (endpoint OAuth), Cursor mensuel (dashboard)
- Serveurs de dev locaux (scan des ports 3000–9999) avec arrêt sécurisé
- Quick Routes, Fast Actions, barre de menus, notifications système
- Réglages (7 onglets) avec Doctor de diagnostic, onboarding guidé
- Accessibilité complète (VoiceOver, Reduced Motion, Reduce Transparency)
- Timeline des tool calls Cursor + chip de contexte + subagents

### Notes
- Modèle « one-shot » : ni licence, ni essai, ni mise à jour automatique.
  Mise à jour = remplacer AgentDash.app par une version plus récente.
- 100 % local : aucune donnée ne quitte le Mac hormis la lecture d'usage
  (api.anthropic.com, cursor.com), désactivable.
