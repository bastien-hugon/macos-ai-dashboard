# Recherche — Distribution, mises à jour et licensing d'AgentDash (nom provisoire)

> Recherche menée le 3 juillet 2026. Sources : documentation officielle Sparkle, Apple Developer, Lemon Squeezy, Paddle, GitHub (actions/runner-images), articles techniques récents (2024-2026).
> Convention : chaque affirmation est marquée **[VÉRIFIÉ]** (doc officielle ou source primaire consultée) ou **[HYPOTHÈSE]** (déduction raisonnable à valider en implémentation). Les recommandations tranchées sont signalées par **➤ RECOMMANDATION**.
>
> Rappel du cahier des charges (cf. `AGENTPEEK_FEATURES.md`, § 11-12) : essai gratuit 2 jours → licence one-time 15 $, 1 licence = 1 Mac, vérification transmettant uniquement clé + machine ID + version d'app, DMG signé/notarisé téléchargeable sur un endpoint `download/latest`, mises à jour Sparkle avec checks horaires et fenêtre « What's New », faille de rollback d'horloge fermée (v0.2.9 d'AgentPeek — chez nous, à fermer dès le premier jour).

---

## 0. Synthèse des recommandations

| Sujet | Décision recommandée |
|---|---|
| Mises à jour | **Sparkle 2** via SPM, UI standard de Sparkle + fenêtre « What's New » maison post-update, `SUScheduledCheckInterval = 3600` (checks horaires), canal `beta` optionnel |
| Artefact | **Un seul DMG** signé + notarisé + staplé, servi à la fois par le site (`/download/latest`) et par l'appcast |
| Création DMG | Script **`create-dmg`** (github.com/create-dmg/create-dmg) via Homebrew |
| Hébergement | **GitHub Releases** pour les binaires + **appcast.xml et site sur Cloudflare Pages** (domaine custom, redirection `/download/latest`) |
| CI | **GitHub Actions, runner `macos-26`** (GA depuis février 2026), signature via keychain temporaire, notarisation via **clé API App Store Connect** |
| Paiement | **Lemon Squeezy** (MoR, 5 % + 0,50 $, License API native activate/validate/deactivate) — surveiller la migration vers Stripe Managed Payments |
| Activation | **Cloudflare Worker sans état** qui proxifie l'API Lemon Squeezy et émet un **reçu d'activation signé Ed25519**, vérifiable offline via CryptoKit |
| Machine ID | **SHA-256(IOPlatformUUID + sel applicatif)** |
| Trial | Double stockage **Keychain + fichier**, anti-rollback par **high-water mark + `mach_continuous_time()`**, accumulateur de temps écoulé, transition réactive vers l'écran d'achat |
| Onboarding | Fenêtre welcome multi-étapes (hooks → notifications → login item → trial/licence), permission notifications demandée **en contexte, jamais au premier écran** |

---

## 1. Sparkle 2 — framework de mise à jour

### 1.1 État du projet

- **[VÉRIFIÉ]** Dernière version stable observée sur la page GitHub Releases au moment de la recherche : **2.9.4 « Appcast Improvements » (3 juillet 2024)**. Versions précédentes : 2.9.2 (17 mai 2024, correctifs de sécurité critiques), 2.9.0 (22 février 2024 : support Markdown des notes de version — nécessite macOS 12+ —, signature d'appcast, Swift concurrency). *Étrange qu'aucune release 2024-2026 plus récente ne soit apparue dans l'extrait ; re-vérifier la toute dernière version au moment de l'ajout du package (cf. § Hypothèses).*
- **[VÉRIFIÉ]** Sparkle 2 vérifie les mises à jour par **signatures EdDSA (ed25519)** + Apple code signing, supporte le sandboxing, les UI personnalisées et une architecture moderne (installations via XPC).
- **[VÉRIFIÉ]** Par défaut, Sparkle vérifie les mises à jour **toutes les 24 h** ; l'intervalle est configurable (§ 1.5).
- AgentDash ne sera **pas sandboxée** (lecture de `~/.claude`, scan de ports, kill de process) → **[VÉRIFIÉ]** l'intégration Sparkle est le cas simple : pas de configuration XPC spécifique au sandbox requise (le guide sandboxing ne s'applique pas). La doc note même qu'on peut retirer les XPC Services de la distribution si l'app n'est pas sandboxée (optimisation optionnelle, non prioritaire).

### 1.2 Intégration SPM

- **[VÉRIFIÉ]** Package : `https://github.com/sparkle-project/Sparkle` (Xcode → File → Add Packages…), produit `Sparkle` lié à la cible de l'app.
- **[VÉRIFIÉ]** Les outils CLI (`generate_keys`, `sign_update`, `generate_appcast`) sont livrés en **artefact binaire du package** : après résolution, ils se trouvent sous `…/SourcePackages/artifacts/sparkle/Sparkle/bin/` dans DerivedData (la doc indique « ../artifacts/sparkle/Sparkle/bin » relativement au package ; chemin exact à confirmer localement — cf. Hypothèses). Alternative fiable pour la CI : télécharger l'archive de distribution officielle (`Sparkle-2.x.x.tar.xz` sur GitHub Releases) et utiliser son dossier `bin/`, en **épinglant la même version** que le package SPM.
- **[HYPOTHÈSE]** Épingler le package sur une version exacte (`exact:`) plutôt que `upToNextMajor` pour que l'outil `generate_appcast` de la CI et le framework embarqué restent synchrones.

### 1.3 Clés EdDSA — génération et gestion

- **[VÉRIFIÉ]** `./bin/generate_keys` génère une paire ed25519 ; la **clé privée est stockée dans le Keychain de login** du Mac ; la **clé publique (base64)** est affichée pour être copiée dans l'Info.plist.
- **[VÉRIFIÉ]** Export/import de la clé privée : `generate_keys -x fichier` (export) et `generate_keys -f fichier` (import). C'est le mécanisme prévu pour transférer la clé vers la CI.
- **[VÉRIFIÉ]** La clé privée signe les archives de mise à jour (DMG/ZIP), les deltas et, depuis 2.9, l'appcast lui-même le cas échéant.
- **➤ RECOMMANDATION** : générer la paire une fois sur la machine de développement, exporter avec `-x`, stocker le fichier exporté dans un **secret GitHub Actions** (`SPARKLE_ED_PRIVATE_KEY`) et dans un gestionnaire de mots de passe comme sauvegarde froide. **La perte de cette clé casse la chaîne de mise à jour** (les apps installées refusent les updates signées par une autre clé) ; la clé publique est figée dans chaque binaire distribué.
- **[VÉRIFIÉ]** En CI, `generate_appcast` accepte `--ed-key-file <chemin>` pour lire la clé privée depuis un fichier au lieu du Keychain (motif classique : écrire le secret dans un fichier temporaire, l'utiliser, le supprimer). *Le flag exact de `sign_update` (clé via fichier) est à confirmer sur la version épinglée — cf. Hypothèses ; en pratique `generate_appcast` suffit car il signe tout.*

### 1.4 Info.plist — clés de configuration

**[VÉRIFIÉ]** (doc « Customization » de Sparkle) :

| Clé | Rôle | Valeur AgentDash |
|---|---|---|
| `SUFeedURL` | URL de l'appcast | `https://<domaine>/appcast.xml` |
| `SUPublicEDKey` | Clé publique EdDSA base64 | sortie de `generate_keys` |
| `SUEnableAutomaticChecks` | Checks automatiques activés | `YES` (avec consentement onboarding, cf. § 1.7) |
| `SUScheduledCheckInterval` | Intervalle en secondes — **défaut 86 400 (24 h), minimum 3 600 (1 h)** | **`3600`** pour répliquer les « checks horaires » d'AgentPeek |
| `SUAutomaticallyUpdate` | Téléchargement + installation silencieux | `NO` par défaut (laisser l'utilisateur opter) |
| `SUAllowsAutomaticUpdates` | Autorise l'option « installer automatiquement » | `YES` |
| `SUShowReleaseNotes` | Affiche les notes de version dans l'UI d'update | `YES` (défaut) |
| `CFBundleVersion` | **Obligatoire**, monotone croissant — c'est le `sparkle:version` comparé | numéro de build entier incrémenté à chaque release |

Le minimum d'une heure pour `SUScheduledCheckInterval` colle exactement au comportement d'AgentPeek (« checks horaires ») — c'est donc la valeur plancher légitime, pas un hack.

### 1.5 appcast.xml — structure et publication

- **[VÉRIFIÉ]** L'appcast est un **flux RSS enrichi**. Par item : `<sparkle:version>` (= CFBundleVersion), `<sparkle:shortVersionString>` (version marketing), `<pubDate>`, `<enclosure url="…" length="…" sparkle:edSignature="…"/>`, notes de version via `<description>` inline ou `<sparkle:releaseNotesLink>`, plus `<sparkle:minimumSystemVersion>` (mettre `14.0`) et `<sparkle:phasedRolloutInterval>` (rollout progressif, optionnel).
- **[VÉRIFIÉ]** `generate_appcast /dossier/updates/` scanne le dossier d'archives, **signe chaque archive, génère les deltas** (mises à jour différentielles) et écrit l'appcast. Les notes de version peuvent être fournies par des fichiers `.html` ou `.md` homonymes des archives (Markdown rendu nativement depuis Sparkle 2.9, macOS 12+ — OK pour notre cible macOS 14+).
- **[VÉRIFIÉ]** Options utiles de `generate_appcast` : `--ed-key-file`, `--download-url-prefix` (préfixe des URL d'enclosure — indispensable si les DMG sont sur GitHub Releases et l'appcast ailleurs), `--link`, `--channel`.
- **[VÉRIFIÉ]** L'archive doit préserver les symlinks (important pour un DMG contenant l'app : natif ; pour un ZIP : utiliser `ditto -c -k --sequesterRsrc --keepParent`).
- **Ordre des opérations** : signer (codesign) → notariser → **stapler** → *ensuite seulement* passer le DMG final à `generate_appcast`. **[HYPOTHÈSE raisonnée]** : la doc ne fixe pas l'ordre, mais la signature EdDSA porte sur l'octet-stream exact du fichier ; or `stapler staple` modifie le DMG. Donc toujours signer l'appcast en dernier.

### 1.6 Canaux de release

- **[VÉRIFIÉ]** Un item d'appcast peut porter `<sparkle:channel>beta</sparkle:channel>` ; sans élément channel, l'item est sur le canal par défaut. Côté app, on implémente `SPUUpdaterDelegate` :

```swift
func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    UserDefaults.standard.bool(forKey: "betaChannel") ? ["beta"] : []
}
```

- **[VÉRIFIÉ]** Un updater ne peut pas s'exclure du canal par défaut ; les canaux servent à des branches temporaires (bêtas rattrapées ensuite par une release stable), pas à des lignes parallèles permanentes. Noms valides : lettres, chiffres, tirets, underscores, points.
- **➤ RECOMMANDATION** : un seul appcast avec canal `beta` optionnel (toggle « Recevoir les bêtas » dans Settings → About), plutôt que deux feeds séparés.

### 1.7 UI de mise à jour : standard vs personnalisée

- **[VÉRIFIÉ]** Deux niveaux d'intégration :
  1. **`SPUStandardUpdaterController`** — UI standard de Sparkle (fenêtre de mise à jour, notes de version, progression). Instanciable dans SwiftUI en propriété d'un objet App, avec `checkForUpdates()` exposé pour le bouton « Check for Updates » de Settings → About.
  2. **`SPUUpdater` + `SPUUserDriver` custom** — contrôle total de l'UI : on initialise `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)` avec sa propre implémentation de `SPUUserDriver`. Méthodes clés du protocole (toutes appelées sur le main thread) : `showUpdatePermissionRequest`, `showUserInitiatedUpdateCheck`, `showUpdateFound(with:state:reply:)`, `showDownloadInitiated` / `…DidReceiveExpectedContentLength` / `…DidReceiveDataOfLength`, `showDownloadDidStartExtractingUpdate`, `showReadyToInstallAndRelaunch`, `showInstallingUpdate`, `showUpdateInstalledAndRelaunched`, `showUpdateNotFoundWithError`, `dismissUpdateInstallation`.
- **➤ RECOMMANDATION** : démarrer avec **l'UI standard** (fiable, accessible, localisée) ; AgentPeek utilise des « prompts de mise à jour avec l'icône de l'app », ce que l'UI standard fait déjà. Ne passer à un `SPUUserDriver` custom que si l'on veut afficher la proposition d'update *dans le notch* (V2 potentielle — le protocole le permet proprement).
- **Consentement** : **[VÉRIFIÉ]** au premier lancement, Sparkle affiche par défaut une demande de permission pour les checks automatiques (ou `showUpdatePermissionRequest` en driver custom). On peut la court-circuiter en réglant `automaticallyChecksForUpdates` programmatique­ment pendant l'onboarding (case pré-cochée « Vérifier les mises à jour automatiquement »).

### 1.8 Fenêtre « What's New »

Sparkle affiche les notes de version **avant** l'installation. La fenêtre « What's New » d'AgentPeek (affichée **après** la mise à jour, validable avec Entrée) est une **fonctionnalité applicative maison** :

- **[HYPOTHÈSE d'implémentation]** (pattern standard, aucune API Sparkle dédiée) : stocker `lastWhatsNewVersion` dans UserDefaults ; au lancement, si `CFBundleShortVersionString` > valeur stockée **et** que ce n'est pas le premier lancement, afficher une fenêtre SwiftUI rendant le changelog embarqué (fichier Markdown packagé dans le bundle, section correspondant à la version) ; bouton par défaut validable avec Entrée (`.keyboardShortcut(.defaultAction)`).
- Garder le changelog dans le repo (`CHANGELOG.md`) comme **source unique** : la CI en extrait la section de la version pour ① le fichier `.md` consommé par `generate_appcast` (notes pré-update) et ② la ressource embarquée (What's New post-update).

---

## 2. Pipeline de release

### 2.1 Prérequis Apple

- **[VÉRIFIÉ]** Adhésion **Apple Developer Program** (99 $/an) requise pour Developer ID et la notarisation.
- **[VÉRIFIÉ]** Certificat **« Developer ID Application »** : signe l'app **et** le DMG. (« Developer ID Installer » ne sert que pour les `.pkg` — non utilisé ici.)
- **[VÉRIFIÉ]** Exigences de notarisation : signature Developer ID + **hardened runtime** (`codesign --options runtime`) + **timestamp sécurisé** (`--timestamp`) + absence de l'entitlement `com.apple.security.get-task-allow` (build Release).
- **[HYPOTHÈSE]** AgentDash ne devrait nécessiter **aucune exception au hardened runtime** (pas de JIT, pas de bibliothèques non signées) ; à confirmer une fois les dépendances arrêtées.

### 2.2 Signature

Deux approches :

1. **`xcodebuild archive` + `xcodebuild -exportArchive`** avec `ExportOptions.plist` (`method: developer-id`) — Xcode signe correctement l'app **y compris les composants embarqués de Sparkle** (framework + XPC Services). **➤ RECOMMANDATION** : c'est la voie à suivre ; elle évite les erreurs de re-signature manuelle.
2. Signature manuelle `codesign` inside-out (composants les plus profonds d'abord, jamais `--deep` en production) — utile seulement en dépannage.

Commande de vérification avant notarisation :

```bash
codesign --verify --deep --strict --verbose=2 AgentDash.app
spctl --assess --type execute --verbose AgentDash.app   # échouera avant notarisation, normal
```

### 2.3 Création du DMG

- **[VÉRIFIÉ]** Deux outils CLI dominants, équivalents sur le fond : **`create-dmg`** (script shell, `brew install create-dmg`) et **`dmgbuild`** (Python). Aucun ne signe ni ne notarise — étapes séparées.
- **➤ RECOMMANDATION** : **`create-dmg`** (zéro dépendance Python en CI, layout icône + lien `/Applications`, options `--icon`, `--app-drop-link`, `--background`, `--window-size`). Exemple :

```bash
create-dmg \
  --volname "AgentDash" \
  --window-size 540 380 \
  --icon "AgentDash.app" 140 180 \
  --app-drop-link 400 180 \
  --background "assets/dmg-background.png" \
  "AgentDash-1.2.3.dmg" "export/AgentDash.app"
codesign --sign "Developer ID Application: <Nom> (<TEAMID>)" --timestamp "AgentDash-1.2.3.dmg"
```

### 2.4 Notarisation et stapling

- **[VÉRIFIÉ]** Formats acceptés par `notarytool` : ZIP, DMG, PKG. Notariser le **DMG** couvre l'app qu'il contient (la notarisation indexe tous les binaires par hash).
- **[VÉRIFIÉ]** Deux modes d'authentification : ① Apple ID + mot de passe applicatif + Team ID ; ② **clé API App Store Connect** (`--key AuthKey_XXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>`) — **recommandée en CI** (pas de 2FA, révocable).

```bash
xcrun notarytool submit AgentDash-1.2.3.dmg \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait
xcrun stapler staple "export/AgentDash.app"    # ticket sur l'app (Gatekeeper offline)
xcrun stapler staple "AgentDash-1.2.3.dmg"     # ticket sur le DMG
```

- **Subtilité d'ordre** : stapler l'app **à l'intérieur** du DMG impose de reconstruire le DMG après. **➤ RECOMMANDATION** de séquence complète : ① exporter et signer l'app ; ② zipper (`ditto`) et notariser **l'app** ; ③ `stapler staple` l'app ; ④ construire le DMG avec l'app staplée ; ⑤ signer le DMG ; ⑥ notariser le DMG (rapide, hashes déjà connus) ; ⑦ stapler le DMG ; ⑧ `generate_appcast`. **[HYPOTHÈSE]** : la double soumission (app puis DMG) est le pattern le plus robuste documenté par la communauté (forums Apple/C-Command) ; certains ne notarisent que le DMG — acceptable, mais l'app non staplée exigera un accès réseau Gatekeeper à la première ouverture si elle est extraite du DMG hors ligne.
- Débogage : `xcrun notarytool log <submission-id> …` en cas de statut `Invalid`. **[VÉRIFIÉ]**

### 2.5 Hébergement téléchargement + appcast

Contraintes : URL de download stable (`/download/latest`), appcast servi en HTTPS, DMG versionnés persistants (Sparkle delta + rollback), bande passante faible (DMG ~5-20 Mo, base utilisateurs indé).

Options :

| Option | Avantages | Inconvénients |
|---|---|---|
| **GitHub Releases (binaires) + Cloudflare Pages (site, appcast, redirection)** | gratuit, versionné, CDN GitHub correct, appcast sous contrôle du domaine | deux systèmes ; URL GitHub « moches » (masquées par la redirection) |
| Cloudflare R2 + domaine custom | tout sous un domaine, œuf gratuit (10 Go), URLs propres | upload à scripter, pas de page « releases » navigable |
| Tout sur GitHub Pages | simplissime | limites de taille/bande passante du repo pour les DMG |

**➤ RECOMMANDATION** : **GitHub Releases** pour les DMG + **Cloudflare Pages** pour le site, `appcast.xml` et une règle de redirection `https://<domaine>/download/latest → asset GitHub de la dernière release`. `generate_appcast --download-url-prefix "https://github.com/<org>/<repo>/releases/download/v<version>/"` fait le pont. L'appcast reste sur notre domaine → on peut changer d'hébergeur de binaires sans casser `SUFeedURL` (qui est figée dans les binaires distribués).

### 2.6 GitHub Actions — workflow de release

- **[VÉRIFIÉ]** Runners macOS hébergés : `macos-15` (GA avril 2025) ; **`macos-26` (Tahoe) GA depuis le 26 février 2026, Apple Silicon natif (arm64)** ; `macos-latest` bascule sur macos-26 à partir du 15 juin 2026 ; Xcode 26.x par défaut sur macos-26. **➤ RECOMMANDATION** : épingler `runs-on: macos-26` explicitement.
- **[VÉRIFIÉ]** Pattern éprouvé (article F. Terzi + doc Apple) — secrets nécessaires :
  `MACOS_CERTIFICATE` (p12 base64), `MACOS_CERTIFICATE_PWD`, `MACOS_CERTIFICATE_NAME`, `KEYCHAIN_PWD` (keychain CI temporaire), `ASC_KEY` (contenu du .p8), `ASC_KEY_ID`, `ASC_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY`.

Squelette du job (étapes vérifiées individuellement, assemblage à valider) :

```yaml
release:
  runs-on: macos-26
  steps:
    - uses: actions/checkout@v4
    - name: Import signing certificate
      run: |
        echo "$MACOS_CERTIFICATE" | base64 --decode > cert.p12
        security create-keychain -p "$KEYCHAIN_PWD" build.keychain
        security default-keychain -s build.keychain
        security unlock-keychain -p "$KEYCHAIN_PWD" build.keychain
        security import cert.p12 -k build.keychain -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PWD" build.keychain
    - name: Archive & export (Developer ID)
      run: |
        xcodebuild archive -scheme AgentDash -configuration Release -archivePath build/AgentDash.xcarchive
        xcodebuild -exportArchive -archivePath build/AgentDash.xcarchive \
          -exportOptionsPlist ci/ExportOptions.plist -exportPath export
    # … notarisation app (ditto+notarytool+stapler), create-dmg, signature DMG,
    #    notarisation DMG, stapler DMG (cf. § 2.4)
    - name: Generate appcast
      run: |
        echo "$SPARKLE_ED_PRIVATE_KEY" > ed_key && chmod 600 ed_key
        ./sparkle-tools/bin/generate_appcast --ed-key-file ed_key \
          --download-url-prefix "https://github.com/<org>/agentdash/releases/download/v${VERSION}/" \
          updates/
        rm ed_key
    - name: Publish
      run: gh release create "v${VERSION}" updates/*.dmg --notes-file relnotes.md
      # + déploiement de l'appcast.xml vers Cloudflare Pages (wrangler)
```

Points d'attention : `security set-key-partition-list` est indispensable pour éviter le prompt de keychain en headless **[VÉRIFIÉ]** ; conserver les anciens DMG dans `updates/` (télécharger les N dernières releases) pour que `generate_appcast` produise les **deltas** **[VÉRIFIÉ]** ; la notarisation prend de quelques secondes à ~15 min (`--wait` bloque le job) **[VÉRIFIÉ]**.

---

## 3. Essai gratuit de 2 jours — implémentation robuste

Objectif : essai de 48 h en temps réel, résistant à : suppression/réinstallation de l'app, effacement des préférences, rollback de l'horloge système ; avec bascule **immédiate** (sans redémarrage) vers l'écran d'achat à expiration.

### 3.1 Où stocker le début d'essai (redondance)

**➤ RECOMMANDATION — double stockage avec fusion pessimiste :**

1. **Keychain** : item `kSecClassGenericPassword` (service `com.<org>.agentdash.license`, account `trial-state`), avec `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (non synchronisé iCloud, lié à la machine).
   - **[VÉRIFIÉ - comportement général]** Les items Keychain **survivent à la suppression et réinstallation de l'app** — c'est tout l'intérêt.
   - **[HYPOTHÈSE à tester]** L'accès sans prompt après réinstallation dépend de l'ACL : elle est liée au *designated requirement* de l'app signée ; une nouvelle build signée du même Team ID/bundle ID doit y accéder silencieusement. Tester aussi l'option moderne `kSecUseDataProtectionKeychain = true` (requiert un entitlement d'application-identifier, présent sur toute app signée Developer ID) vs le keychain « login » historique — valider lequel se comporte le mieux pour une app **non sandboxée**.
2. **Fichier** : petit blob dans un emplacement discret **hors** du conteneur évident de l'app (ex. `~/Library/Application Support/<sous-dossier neutre>/…`), pour survivre à un « nettoyage » ciblé du Keychain. **[HYPOTHÈSE]** AgentPeek fait probablement de même ; l'emplacement exact est un choix produit (équilibre honnêteté/robustesse — rester raisonnable, pas de rootkit-like).
3. **Contenu du blob** (identique aux deux endroits), chiffré/authentifié :
   ```json
   { "trialStart": 1751500000, "highWaterMark": 1751560000,
     "elapsedSeconds": 60000, "machineIdHash": "…", "v": 1 }
   ```
   scellé par **HMAC-SHA256** (ou `AES.GCM` de CryptoKit) avec une clé dérivée de (constante embarquée ⊕ machineIdHash) — pas inviolable (le secret est dans le binaire), mais élève le coût au-delà du public visé. **[HYPOTHÈSE de conception standard]**
4. **Règle de fusion** : au lancement, lire les deux ; si divergence, prendre le `trialStart` **le plus ancien** et le `highWaterMark`/`elapsedSeconds` **les plus grands** ; réécrire les deux. Si les deux sont absents → premier lancement, créer l'état. Si un seul est absent → le recréer depuis l'autre (auto-réparation).

### 3.2 Anti-rollback de l'horloge système

Trois mécanismes complémentaires :

1. **High-water mark (« dernière heure vue »)** : à chaque lancement et à chaque battement (timer ~60 s), si `Date()` > `highWaterMark`, avancer le high-water mark et persister. **Si `Date()` < `highWaterMark` − tolérance (~2 min), l'horloge a été reculée** : ne jamais recréditer du temps — continuer à mesurer le temps écoulé sur l'ancre monotone et considérer `effectiveNow = highWaterMark + delta_monotone`. C'est exactement l'exigence « refuser si maintenant < dernière exécution connue ».
2. **Ancre monotone** : **[VÉRIFIÉ]** attention, sur macOS le `CLOCK_MONOTONIC` POSIX **suit les reculs d'horloge** (bug/dette historique documentée : reculer l'heure d'une heure fait reculer CLOCK_MONOTONIC d'autant). Les horloges réellement insensibles au wall clock sont **`mach_continuous_time()`** (équivalent `CLOCK_MONOTONIC_RAW` via `clock_gettime_nsec_np`, macOS 10.12+), qui **continue de courir pendant le sommeil**, et `mach_absolute_time()` (`CLOCK_UPTIME_RAW`), qui s'arrête pendant le sommeil. **➤ Utiliser `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` / `mach_continuous_time()`.**
   - **[VÉRIFIÉ - signalement communautaire]** Cas limite : un rapport (libuv/HN) décrit un reset d'époque de `CLOCK_UPTIME_RAW` après un long sommeil en très basse batterie ; par prudence, traiter tout **delta monotone négatif** comme « reboot » (ré-ancrer) plutôt que de faire confiance aveuglément.
   - Les ancres monotones **repartent de zéro au reboot** : persister le couple (ancre monotone, wall clock au moment de l'ancre) et ré-ancrer à chaque lancement ; `sysctl kern.boottime` peut aider à détecter un reboot, mais **[VÉRIFIÉ - mise en garde communautaire]** `kern.boottime` est recalculé à partir du wall clock et n'est pas une source de confiance en soi.
3. **Accumulateur `elapsedSeconds`** : incrémenté uniquement par des **deltas monotones positifs** entre battements, persisté. Il ne peut que croître, quel que soit le wall clock.

**Décision d'expiration** (OU logique, le plus défavorable gagne) :
`expired = (effectiveNow ≥ trialStart + 48 h) || (elapsedSeconds ≥ 48 h × marge)`.
Une manipulation d'horloge ne peut donc au mieux que… ne rien gagner. En cas d'incohérence flagrante répétée, marquer l'état `tampered` (l'UI peut afficher « horloge système incohérente détectée » et basculer sur l'écran d'achat, comme la fermeture de faille v0.2.9 d'AgentPeek).

4. **Contrôle réseau opportuniste (optionnel, compatible vie privée)** : lors des requêtes déjà légitimes (check Sparkle horaire, validation de licence), lire l'en-tête HTTP `Date` de la réponse et le traiter comme un high-water mark supplémentaire. Aucune requête *additionnelle* n'est émise → cohérent avec la promesse « accès réseau limité à licence + mises à jour ». **[HYPOTHÈSE de conception]**

**Tolérance aux faux positifs** : changements de fuseau horaire (travailler en UTC exclusivement → non affecté), correction NTP légitime de quelques secondes (tolérance 2 min), restauration Time Machine/migration (le `trialStart` restauré est ancien → au pire l'essai paraît expiré, jamais rallongé — acceptable ; prévoir un contact support).

### 3.3 Transition immédiate vers l'écran d'achat

- `LicenseManager` : singleton `@Observable` (ou `ObservableObject`) exposant `state: LicenseState` (`trial(remaining:)`, `trialExpired`, `licensed`, `tampered`).
- Trois déclencheurs de réévaluation : ① **timer armé sur l'échéance exacte** (`DispatchSourceTimer`/`Timer` à `trialStart + 48h − now`) ; ② **battement** ~60 s (met aussi à jour le compte à rebours affiché) ; ③ **réveil machine** (`NSWorkspace.didWakeNotification` — les timers ne tirent pas pendant le sommeil) et retour au premier plan.
- À `trialExpired` : le notch passe en état verrouillé (pill grisée), la fenêtre d'achat s'ouvre (`purchase screen` : bouton acheter → URL checkout, champ de saisie de clé inline) — **sans redémarrage**, tout est réactif via SwiftUI. **[HYPOTHÈSE d'implémentation, pattern standard]**

---

## 4. Licence one-time 15 $ — conception

### 4.1 Vue d'ensemble de l'architecture recommandée

**➤ RECOMMANDATION : architecture à deux couches**

```
Achat (Lemon Squeezy, MoR) ──> clé de licence LS (chaîne aléatoire, activation_limit = 1)
        │
        ▼  activation dans l'app : POST /v1/activate {license_key, machine_id_hash, app_version}
Cloudflare Worker (sans état) ── proxifie l'API License de LS (activate/validate/deactivate,
        │                         instance_name = machine_id_hash)
        ▼
Reçu d'activation signé Ed25519  { keyHash, machineIdHash, issuedAt, licenseVersion }
        │
        ▼
App : stockage Keychain + vérification OFFLINE à chaque lancement (CryptoKit, clé publique embarquée)
```

Pourquoi deux couches : **[VÉRIFIÉ]** les clés Lemon Squeezy sont des chaînes aléatoires **sans signature ni fingerprinting ni validation offline** (« every license check requires a live API call ») ; la limite d'activations est « server-side enforcement of a client-side honor system ». La couche Ed25519 maison apporte : validation offline à chaque lancement, liaison machine cryptographique, indépendance vis-à-vis du fournisseur de paiement (si on quitte LS, seul le Worker change). Et le Worker garantit la promesse de confidentialité : **seuls transitent clé + machine ID (haché) + version d'app** — exactement le contrat d'AgentPeek.

### 4.2 Machine ID

- **[VÉRIFIÉ - API publique]** `IOPlatformUUID` : propriété de `IOPlatformExpertDevice` dans l'IORegistry, stable pour une machine physique, indépendante du volume/OS. Lecture :

```swift
import IOKit
func platformUUID() -> String? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, // kIOMasterPortDefault avant macOS 12
                                            IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(entry) }
    return IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString,
                                           kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
}
```

- **➤ RECOMMANDATION** : ne **jamais** transmettre l'UUID brut. `machineIdHash = SHA-256(platformUUID + selApplicatifConstant)` en hex — pseudonymisation (le serveur ne peut pas remonter à l'UUID matériel), et c'est ce hash qui sert d'`instance_name` LS. **[HYPOTHÈSE à valider]** : comportement de l'IOPlatformUUID après Migration Assistant / restauration sur un **nouveau Mac** → il change (propriété matérielle), donc la réactivation est bien nécessaire après migration matérielle — conforme à la FAQ d'AgentPeek ; à tester sur du vrai matériel.

### 4.3 Serveur d'activation minimal (Cloudflare Worker)

API (JSON, HTTPS) — **[HYPOTHÈSE de conception, s'appuyant sur l'API LS vérifiée]** :

| Endpoint | Entrée | Action | Sortie |
|---|---|---|---|
| `POST /v1/activate` | `license_key`, `machine_id`, `app_version` | `POST api.lemonsqueezy.com/v1/licenses/activate` (`license_key`, `instance_name = machine_id`) ; si OK → signer le reçu | `{ receipt, signature, instance_id }` |
| `POST /v1/validate` | `license_key`, `instance_id`, `machine_id`, `app_version` | `POST …/v1/licenses/validate` (statut : active / disabled / refunded) | `{ valid, receipt?, signature? }` (reçu re-signé → révocation possible) |
| `POST /v1/deactivate` | `license_key`, `instance_id` | `POST …/v1/licenses/deactivate` (supprime l'instance, décrémente `activation_usage`) | `{ ok }` |

- **[VÉRIFIÉ]** Endpoints LS License API : `POST https://api.lemonsqueezy.com/v1/licenses/{activate|validate|deactivate}`, `Content-Type: application/x-www-form-urlencoded`, paramètres `license_key`, `instance_name` (activate) / `instance_id` (validate, deactivate) ; `activation_limit` configurable par produit ; la désactivation libère le siège. **[HYPOTHÈSE à confirmer]** : la License API serait appelable **sans clé API** (conçue pour être appelée depuis des apps distribuées) — la doc précise n'a pas pu être consultée (403). Si confirmé, le Worker reste sans secret LS ; sinon, la clé API LS vit dans le Worker (jamais dans l'app) — ce qui est de toute façon plus propre.
- Le Worker détient la **clé privée Ed25519 de licensing** (secret Cloudflare, distincte de la clé Sparkle !). L'app embarque la clé publique et vérifie offline :

```swift
import CryptoKit
let pub = try Curve25519.Signing.PublicKey(rawRepresentation: embeddedKeyData)
guard pub.isValidSignature(sig, for: receiptBytes) else { /* invalide */ }
// puis vérifier receipt.machineIdHash == machineIdHash actuel
```

  **[VÉRIFIÉ]** `Curve25519.Signing` (CryptoKit) disponible depuis macOS 10.15 — OK pour macOS 14+.
- **Politique de revalidation** : offline-first — l'app ne **requiert** jamais le réseau au lancement ; revalidation en arrière-plan ~tous les 7-14 jours quand le réseau est disponible ; si le serveur répond « refunded/disabled », le reçu n'est pas renouvelé et une **période de grâce** (14-30 jours depuis la dernière validation réussie) évite de punir les utilisateurs hors ligne. **[HYPOTHÈSE de conception]**

### 4.4 Stockage, migration matérielle, limites

- **Stockage** : reçu + signature + `instance_id` + clé dans le **Keychain** (`kSecClassGenericPassword`, `…ThisDeviceOnly`) ; copie fichier de secours comme pour le trial. Déblocage immédiat à la saisie de la clé (champ inline → spinner → état `licensed` réactif).
- **1 licence = 1 Mac** : `activation_limit = 1` sur le produit LS.
- **Migration/réactivation** :
  1. Bouton **« Deactivate this Mac »** dans Settings → About/License (appelle `/v1/deactivate`, efface le reçu local) — le cas nominal.
  2. Mac mort/vendu sans désactivation : le portail client Lemon Squeezy (My Orders) permet de gérer/retrouver ses clés **[VÉRIFIÉ - fonctionnalité LS générale]** ; pour la désactivation d'instance orpheline, prévoir soit un petit endpoint self-service (« libérer mes activations », authentifié par la clé elle-même), soit le support par e-mail + action manuelle dans le dashboard LS. **[HYPOTHÈSE : LS dashboard permet de supprimer une instance manuellement — à vérifier.]**
  3. Anti-abus léger : le Worker peut limiter les cycles activate/deactivate (ex. 5/30 jours) — optionnel, ne pas sur-ingénierer pour 15 $.

### 4.5 Fournisseurs de paiement — comparaison et choix

| Critère | **Lemon Squeezy** | **Paddle (Billing)** | **Stripe + serveur maison** | **Polar.sh** |
|---|---|---|---|---|
| Merchant of Record (TVA/sales tax gérées) | **Oui** | **Oui** | **Non** (Stripe Tax calcule, mais VOUS êtes redevable : immatriculations OSS/VAT à votre charge) | **Oui** |
| Frais | **5 % + 0,50 $** | **5 % + 0,50 $** (+ marge de change 2-3 % éventuelle) | ~2,9 % + 0,30 $ + Stripe Tax + coût de conformité | 5 % + 0,50 $ (tier gratuit 2026 ; taux réduits via abonnement 20-400 $/mois) |
| Sur une vente à 15 $ | ~1,25 $ (8,3 %) | ~1,25 $ (8,3 %) | ~0,74 $ **hors conformité fiscale** | ~1,25 $ |
| Clés de licence natives | **Oui** (génération + API activate/validate/deactivate, `activation_limit`) | **Non — la génération de licences de Paddle Classic est dépréciée dans Paddle Billing** (fulfillment à construire soi-même via webhooks, ou Keygen) | Non (tout à construire) | Oui (clé `PREFIX_UUID4`, basique, sans fingerprinting) |
| Statut 2026 | Racheté par Stripe (2024) ; **Stripe Managed Payments** (MoR Stripe, annoncé février 2026, 5 % + 0,50 $ identique) en cours d'ouverture publique ; LS continue de fonctionner | Stable, mais processus d'approbation du compte/produit | Stable | A augmenté ses prix en 2026 (ex-4 %) |
| Divers | Checkout overlay propre, portail client | Checkout très mature, exigences de vérification de site | Contrôle total, données client chez vous | Open source, dev-first |

**Vérifié** : les frais Paddle 5 % + 0,50 $ (page pricing 2026) ; la dépréciation des license keys dans Paddle Billing (doc développeur Paddle « Paddle-led fulfillment… deprecated ») ; les endpoints License API LS ; le rachat LS→Stripe et le lancement de Stripe Managed Payments à 5 % + 0,50 $ ; les prix Polar 2026 ; Stripe seul n'est pas MoR.

**➤ RECOMMANDATION tranchée : Lemon Squeezy.**
Justification : ① MoR indispensable pour un solo dev vendant mondialement à 15 $ (l'immatriculation TVA/OSS + sales tax US coûterait plus cher que les 4,2 points d'écart avec Stripe — sur 1 000 ventes, l'écart LS-Stripe ≈ 510 $, très inférieur au coût de conformité) ; ② seule offre MoR avec **API de licence intégrée** (activate/validate/deactivate + activation_limit), ce qui rend notre Worker quasi sans état ; ③ le rachat par Stripe sécurise plutôt la pérennité — et notre couche Ed25519 isole l'app du fournisseur si une migration vers Stripe Managed Payments (+ Keygen ou licensing maison) devenait nécessaire. **Plan B documenté** : Paddle + Keygen (Keygen : plateforme de licensing dédiée, open source/self-hostable, intégration Paddle documentée) si LS fermait les inscriptions pendant la transition Stripe.
À écarter : Stripe pur (charge fiscale disproportionnée pour 15 $), Polar (licensing trop basique, prix désormais alignés sans l'API de licence mature).

---

## 5. Onboarding

### 5.1 Structure de la fenêtre welcome

AgentPeek : « welcome guidé en fenêtre » pour connecter les agents + choix trial/licence au premier lancement. Déclinaison AgentDash (**[HYPOTHÈSE de conception]**, alignée sur les HIG « Onboarding » d'Apple — accueil bref, montrer la valeur, tout doit être re-jouable depuis Settings) :

1. **Bienvenue** — pitch une phrase + visuel du notch ; bouton Continuer.
2. **Connexion des agents** — cartes Claude Code / Cursor avec détection (`~/.claude` présent ? `~/.cursor` ? app Cursor installée ?), bouton « Install hooks » par agent → statut **Ready** (vert) en direct ; lien « réparer » ; c'est le même moteur que Settings → General → Agent hooks et l'onglet Doctor.
3. **Notifications** — écran d'explication (« être prévenu quand un agent attend une permission ou termine ») **avant** de déclencher `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])` ; si refus, continuer sans bloquer (re-proposable dans Settings → Notifications avec deep-link vers Réglages Système).
4. **Launch at login** — toggle **désactivé par défaut** ; si activé : `SMAppService.mainApp.register()`.
5. **Trial / licence** — deux boutons : « Start free trial » (2 jours, aucune donnée demandée) et « I have a license » (champ de clé inline → activation immédiate). Démarrer le trial crée l'état § 3.1.

### 5.2 Bonnes pratiques vérifiées

- **[VÉRIFIÉ]** HIG : l'onboarding doit être court, optionnel dans ses étapes, et ne jamais être le seul chemin vers une fonctionnalité.
- **[VÉRIFIÉ]** Launch at login : les guidelines Apple exigent le **consentement utilisateur** (pas d'auto-enregistrement) ; utiliser `SMAppService` (macOS 13+) ; **lire l'état réel via `SMAppService.mainApp.status`** plutôt que de le mettre en cache (l'utilisateur peut retirer l'item dans Réglages Système) ; macOS affiche une notification système « login item ajouté ».
- **[VÉRIFIÉ]** `UNUserNotificationCenter.requestAuthorization` est l'API pour les notifications locales ; la bonne pratique consiste à demander **en contexte**, après explication. Option `.provisional` possible (livraison silencieuse sans prompt) — mais pour notre usage (alertes de permission urgentes), l'autorisation complète est préférable.
- **[HYPOTHÈSE à tester]** L'app sera de type accessory (`LSUIElement = YES`, pas d'icône Dock). Une app accessory **peut** afficher des fenêtres régulières (welcome, Settings) via `NSApp.activate(ignoringOtherApps: true)` + `window.makeKeyAndOrderFront(_:)`, et **peut** publier des notifications UNUserNotificationCenter — pratique standard des apps menu bar, à confirmer sur macOS 26 (notamment l'apparition correcte du prompt d'autorisation quand aucune fenêtre n'a le focus).
- **Fin d'essai → achat** : réutiliser le dernier écran de l'onboarding comme écran d'achat autonome (fenêtre modale + état verrouillé du notch), déclenché réactivement (cf. § 3.3).
- **Sparkle & onboarding** : régler `automaticallyChecksForUpdates = true` pendant l'onboarding (case pré-cochée mentionnée à l'étape 1 ou dans les Settings) pour éviter le prompt de permission séparé de Sparkle. **[VÉRIFIÉ - mécanisme, réglage exact à valider]**

---

## 6. Hypothèses restant à valider en implémentation

1. **Version Sparkle courante** : 2.9.4 (juillet 2024) vue comme dernière release — vérifier au moment de l'intégration s'il existe une 2.10+/3.x et ses éventuels changements d'API (`SPUUserDriver` notamment).
2. **Chemin exact des outils Sparkle via SPM** (`…/SourcePackages/artifacts/sparkle/Sparkle/bin`) et flags exacts de `sign_update` (clé via fichier) sur la version épinglée.
3. **Lemon Squeezy License API sans clé API** : la doc (403 pendant la recherche) doit confirmer si `activate/validate/deactivate` sont appelables sans authentification ; sinon, la clé API LS vit dans le Worker.
4. **Disponibilité des inscriptions Lemon Squeezy en 2026** pendant la bascule Stripe Managed Payments (SMP annoncé février 2026, ouverture publique « coming soon ») ; le cas échéant, activer le plan B Paddle + Keygen.
5. **Keychain après réinstallation** : accès silencieux aux items (ACL liée au designated requirement) entre builds Debug/Release et entre versions ; choix `kSecUseDataProtectionKeychain` vs keychain login pour une app Developer ID non sandboxée.
6. **IOPlatformUUID** : stabilité à travers mises à jour d'OS ; confirmation qu'il change entre deux machines après Migration Assistant (fondement de la politique de réactivation).
7. **`mach_continuous_time`** : reproduire (ou écarter) le reset d'époque signalé après long sommeil en basse batterie ; valider la stratégie « delta négatif ⇒ ré-ancrage ».
8. **Double notarisation app puis DMG** : confirmer que la soumission du DMG contenant une app déjà staplée passe sans avertissement, et mesurer le coût en temps CI.
9. **Prompt de notification pour une app `LSUIElement`** sur macOS 26 : le dialogue d'autorisation apparaît-il correctement sans fenêtre au premier plan ?
10. **Paddle (plan B)** : délais réels d'approbation de compte/produit en 2026 et exigences de vérification du site.
11. **Ordre appcast/stapling** : vérifier qu'aucune étape (stapler notamment) ne modifie le DMG **après** la signature EdDSA dans notre pipeline final (test de bout en bout : installer v1, publier v2, vérifier l'update).
12. **Redirection `/download/latest` → asset GitHub Releases** : stabilité des URLs d'assets et absence de problème avec les téléchargements repris/interrompus de Sparkle.
13. **Suppression manuelle d'une instance de licence** dans le dashboard LS (support de la réactivation orpheline).
14. **Comportement de `generate_appcast` avec des DMG signés/staplés** pour la génération de deltas entre versions (tailles, fiabilité).

---

## Sources principales

- Sparkle : https://sparkle-project.org/documentation/ · /documentation/publishing/ · /documentation/customization/ · /documentation/api-reference/Protocols/SPUUserDriver.html · https://github.com/sparkle-project/Sparkle (releases, discussion #2189 « Beta Channel Setup », issue #1701 SPM)
- Apple : https://developer.apple.com/documentation/security/customizing-the-notarization-workflow · https://developer.apple.com/developer-id/ · HIG Onboarding · doc UNUserNotificationCenter
- CI : https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/ · https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/ · actions/runner-images #14167 (macos-latest → macos-26, juin 2026)
- Licensing/paiement : https://docs.lemonsqueezy.com/api/license-api (et sous-pages activate/validate/deactivate) · https://www.lemonsqueezy.com/blog/2026-update · https://developer.paddle.com/migrate/paddle-classic/features · https://www.paddle.com/pricing · https://dodopayments.com/blogs/paddle-fees-explained · https://polar.sh/resources/pricing · https://licenseseat.com/alternative-to-lemonsqueezy · https://keylight.dev/best-licensing-for-macos-apps/ · https://keygen.sh/integrate/paddle/
- Horloges/anti-rollback : https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time · https://github.com/libuv/libuv/issues/2891 · https://bugs.python.org/issue42107 · https://news.ycombinator.com/item?id=25660753
- Login item : https://nilcoalescing.com/blog/LaunchAtLoginSetting/
- DMG : https://github.com/create-dmg/create-dmg · forums Apple Developer (threads 714395, 125145) · forum C-Command (notarisation app + DMG)
