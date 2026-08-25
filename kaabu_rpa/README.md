# RPA KAABU — Robot Framework

Automatisation de la connexion et de l'inscription client sur le portail
KAABU (Orange-Sonatel) : `https://kaabu.orange-sonatel.com`

## Structure du projet

```
kaabu_rpa/
├── resources/
│   ├── variables.robot   # URL, identifiants, locators (sélecteurs)
│   └── keywords.robot    # Mots-clés réutilisables (login, formulaire, preuves)
├── tests/
│   └── inscription_kaabu.robot   # Scénarios de test
├── results/               # Rapports, logs, captures d'écran générés
└── README.md
```

## ⚠️ À faire avant la première exécution

Le formulaire réel n'a pas pu être inspecté (la vidéo fournie montrait
uniquement l'écran de vérification KYC, pas la page de login ni le
formulaire vierge). **Les locators dans `resources/variables.robot` sont
des hypothèses** basées sur les libellés visibles à l'écran (Nom, Prénom,
Type de pièce, etc.). Il faut les corriger :

1. Ouvrir le site dans Chrome, faire clic droit → **Inspecter** sur chaque
   champ du formulaire de connexion et d'inscription.
2. Relever l'attribut `id`, `name`, ou un `xpath` stable pour chaque champ.
3. Remplacer les valeurs correspondantes dans `variables.robot`
   (ex: `${LOGIN_USERNAME_FIELD}    id:le_vrai_id`).

## Installation

```bash
pip install robotframework robotframework-seleniumlibrary --break-system-packages
pip install pillow pydantic python-dotenv --break-system-packages
# + un chromedriver compatible avec votre version de Chrome, dans le PATH
# + curl.exe disponible dans le PATH (préinstallé sur Windows 10 1803+ / Windows 11)
```

## OCR CNI : Gemini Vision

`scripts/ocr_cni.py` extrait les champs de la CNI via Gemini Vision
(`scripts/gemini_extractor.py` + `scripts/schemas.py`), en n'utilisant QUE le
recto — confirmé suffisant, `delivery_date`/`expiration_date` y sont bien
imprimés. `verification_cni.robot` continue d'appeler
`ocr_cni.py <recto> <verso>` sans rien changer ; `<verso>` est accepté mais
ignoré. L'ancien script Orange-Sonatel est conservé dans
`scripts/ocr_cni_orange.py.bak`.

Configuration (`.env`) :
```
GEMINI_API_KEY_1=...
GEMINI_API_KEY_2=...
GEMINI_API_KEY_3=...
# GEMINI_MODEL=gemini-2.5-flash   (valeur par défaut de gemini_extractor.py)
```
Rotation automatique sur la clé suivante en cas de quota atteint (429).

⚠️ **`gemini-2.5-flash` s'arrête le 16 octobre 2026** (annonce Google). Le
paramètre `thinking_config`/`thinking_budget` utilisé dans
`gemini_extractor.py` est spécifique à la génération 2.5 — voir le
commentaire dans le fichier avant de changer de modèle.

⚠️ **TODO connu** : `results["document_accepte"]` (règle métier
CNI acceptée/refusée selon le pays, voir `schemas.py`) n'est pour l'instant
**pas exploité** par `verification_cni.robot` — un dossier avec un document
refusé continue d'être traité comme si de rien n'était. À traiter avant mise
en production complète de cette règle.

## Sécuriser les identifiants (recommandé)

Ne laissez pas le mot de passe en clair dans `variables.robot` en
production. Passez-le en ligne de commande à la place :

```bash
robot --variable USERNAME:S_DGSIKAABU_001 --variable PASSWORD:%KAABU_PWD% \
      --outputdir results tests/inscription_kaabu.robot
```

où `KAABU_PWD` est une variable d'environnement définie séparément
(`export KAABU_PWD='...'` sous Linux/Mac, `set KAABU_PWD=...` sous Windows),
plutôt que codée en dur dans un fichier versionné.

## Exécution

```bash
cd kaabu_rpa
robot --outputdir results tests/inscription_kaabu.robot
```

Les rapports (`report.html`, `log.html`) et les captures d'écran de preuve
seront générés dans `results/`.

## Personnaliser les données client

Le test `Creer Une Nouvelle Inscription Client` utilise le dictionnaire
`${CLIENT_1}` défini dans `tests/inscription_kaabu.robot`. Pour traiter
plusieurs clients, transformez ce test en boucle `FOR` sur une liste de
dictionnaires, ou lisez les données depuis un fichier CSV/Excel avec la
bibliothèque `DataDriver`.

## Prochaines étapes suggérées

- Confirmer et corriger tous les locators avec le vrai DOM du site.
- Ajouter la gestion des pièces jointes (upload CNI recto/verso) si le
  champ de fichier utilise un composant personnalisé (ex: drag-and-drop).
- Ajouter des vérifications de non-régression (ex: contrôle du format
  des dates, doublons de numéro de pièce).
