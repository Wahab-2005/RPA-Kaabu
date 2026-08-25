"""
gemini_extractor.py
--------------------
Extraction KYC du recto d'un document d'identité via Gemini Vision (curl.exe sous-jacent via fichier temp),
avec application de la règle métier : CNI acceptée uniquement pour les pays de
schemas.PAYS_CNI_ACCEPTEE ; pour tout autre pays, seul un passeport permet l'inscription.
"""
import sys
import os
import json
import time
import base64
import io
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

from PIL import Image
from dotenv import load_dotenv

from schemas import IdentityDocumentRecto, IdentityDocumentVerso, DocumentType, decider_acceptabilite

load_dotenv()

MODELE_PAR_DEFAUT = "gemini-3.5-flash-lite"
# ↑ gemini-2.5-flash n'est plus disponible (retiré par Google). Bascule sur le modèle 3.x GA
#   le plus rapide/économique disponible : gemini-3.5-flash-lite, conçu pour l'automatisation
#   à haut volume et la latence minimale — plus adapté ici que gemini-3.5-flash (plus lourd,
#   pensé pour l'agentique/code complexe) pour une simple extraction de champs OCR.
#   Alternative si besoin de plus de robustesse au détriment de la vitesse : gemini-3.5-flash.
#   Ce changement de génération impose aussi d'adapter le paramètre "thinking" plus bas
#   (thinking_budget -> thinking_level), cf. commentaire dans _appeler_gemini.

INSTRUCTION_RECTO = """
Système KYC/RPA Afrique de l'Ouest. Analyse le RECTO de ce document d'identité (carte
nationale d'identité ou passeport).

1. Identifie le TYPE (carte d'identité, passeport, ou autre).
2. Extrais les valeurs exactement telles qu'imprimées, sans corriger ni deviner.
3. Dates au format JJ/MM/AAAA (ex: '05 Fév 1995' -> '05/02/1995').
4. Documents bilingues : ignore le texte non-latin.
5. Noms/prénoms en MAJUSCULES.
6. Deux numéros distincts -> document_number = le principal, secondary_number = l'autre.
7. Valeur illisible/absente/ambiguë -> laisser vide et ajouter le nom du champ dans
   uncertain_fields plutôt que deviner.
"""

INSTRUCTION_VERSO = """
Système KYC/RPA Afrique de l'Ouest. Analyse le VERSO de cette carte nationale d'identité
CEDEAO.

1. Repère le NIN (numéro d'identification national) imprimé EN CLAIR (hors zone MRZ),
   généralement en haut ou associé au libellé "NIN". Chiffres et lettres uniquement.
2. Repère la zone MRZ : bande de caractères monospace en bas du document, sur 2 ou 3 lignes,
   utilisant des '<' comme remplissage. Recopie CHAQUE ligne exactement telle qu'imprimée,
   caractère pour caractère, en MAJUSCULES, sans corriger ni reformater. Ne déduis/reconstruis
   RIEN à partir de la MRZ (pas de parsing de date, nom, etc.) — recopie brute uniquement.
3. Si le document n'a que 2 lignes MRZ, laisse mrz_line3 vide.
4. Valeur illisible/absente/ambiguë -> laisser vide et ajouter le nom du champ dans
   uncertain_fields plutôt que deviner.
"""


def redimensionner_pour_envoi(image: Image.Image, cote_max: int = 1024) -> Image.Image:
    largeur, hauteur = image.size
    plus_grand_cote = max(largeur, hauteur)
    if plus_grand_cote <= cote_max:
        return image
    ratio = cote_max / plus_grand_cote
    nouvelle_taille = (int(largeur * ratio), int(hauteur * ratio))
    return image.resize(nouvelle_taille, Image.LANCZOS)


def nettoyer_schema_pydantic(schema: dict) -> dict:
    """Résout les $ref et supprime $defs pour rendre le schéma compatible avec l'API Gemini REST."""
    defs = schema.pop("$defs", {})

    def resoudre_ref(obj):
        if isinstance(obj, dict):
            if "$ref" in obj:
                ref_key = obj["$ref"].split("/")[-1]
                target = defs.get(ref_key, {})
                resolved = resoudre_ref(target)
                for k, v in obj.items():
                    if k != "$ref":
                        resolved[k] = resoudre_ref(v)
                return resolved
            return {k: resoudre_ref(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [resoudre_ref(item) for item in obj]
        return obj

    return resoudre_ref(schema)


class GeminiKYCExtractor:
    def __init__(self, api_key: Optional[str] = None, model_name: Optional[str] = None):
        self.api_key = api_key or os.getenv("GEMINI_API_KEY")
        if not self.api_key:
            raise ValueError("Variable d'environnement GEMINI_API_KEY absente.")
        self.model_name = model_name or os.getenv("GEMINI_MODEL", MODELE_PAR_DEFAUT)

    def extract_recto(self, image_path: str) -> IdentityDocumentRecto:
        donnees_dict = self._appeler_gemini(image_path, INSTRUCTION_RECTO, IdentityDocumentRecto)
        return IdentityDocumentRecto(**donnees_dict)

    def extract_verso(self, image_path: str) -> IdentityDocumentVerso:
        """Extrait NIN + zone MRZ brute depuis le verso. Mêmes garanties de robustesse que
        extract_recto (redimensionnement, thinking désactivé, diagnostic quota)."""
        donnees_dict = self._appeler_gemini(image_path, INSTRUCTION_VERSO, IdentityDocumentVerso)
        return IdentityDocumentVerso(**donnees_dict)

    def _appeler_gemini(self, image_path: str, instruction: str, schema_pydantic) -> dict:
        """Logique commune recto/verso : redimensionnement, encodage, appel curl.exe vers
        l'API Gemini avec le schéma structuré fourni, et parsing de la réponse JSON."""
        chemin = Path(image_path)
        if not chemin.exists():
            raise FileNotFoundError(f"Image introuvable : {image_path}")

        t0 = time.time()
        image = Image.open(chemin)
        image = redimensionner_pour_envoi(image)

        # Buffer image JPEG/Base64
        buffer = io.BytesIO()
        image.convert("RGB").save(buffer, format="JPEG", quality=85)
        base64_image = base64.b64encode(buffer.getvalue()).decode("utf-8")
        t1 = time.time()

        # Schéma JSON compatible
        schema_clean = nettoyer_schema_pydantic(schema_pydantic.model_json_schema())
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model_name}:generateContent?key={self.api_key}"

        payload = {
            "contents": [
                {
                    "parts": [
                        {"text": instruction},
                        {
                            "inline_data": {
                                "mime_type": "image/jpeg",
                                "data": base64_image,
                            }
                        },
                    ]
                }
            ],
            "generationConfig": {
                "response_mime_type": "application/json",
                "response_schema": schema_clean,
                "temperature": 0.0,
                # CRITIQUE POUR LA LATENCE : sans configuration explicite, le modèle utilise le
                # "dynamic thinking" par défaut (il décide lui-même combien réfléchir) — c'est ce
                # qui causait les ~15s observés sur un appel qui ne nécessite aucun raisonnement
                # complexe (simple extraction de champs).
                #
                # Depuis la bascule gemini-2.5-flash -> gemini-3.5-flash (2.5 n'est plus
                # disponible), le paramètre a changé : la génération 3.x utilise "thinking_level"
                # avec une valeur textuelle ("minimal"/"low"/"medium"/"high"), et non plus
                # "thinking_budget" (entier, spécifique à la génération 2.5, qui n'est donc plus
                # utilisé ici). "minimal" est l'équivalent le plus proche de l'ancien
                # thinking_budget=0 pour ce cas d'usage (extraction de champs sans raisonnement).
                # Si MODELE_PAR_DEFAUT ou GEMINI_MODEL repasse un jour sur une génération 2.5,
                # ce bloc doit revenir à {"thinking_budget": 0}.
                "thinking_config": {"thinking_level": "minimal"},
            },
        }

        # Écriture du payload dans un fichier temporaire pour contourner la limite de taille de la ligne de commande Windows
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json", encoding="utf-8") as temp_file:
            json.dump(payload, temp_file)
            temp_file_path = temp_file.name

        try:
            # Passage du fichier temporaire à curl avec @
            cmd = [
                "curl.exe",
                "-s",
                "-X",
                "POST",
                url,
                "-H",
                "Content-Type: application/json",
                "-d",
                f"@{temp_file_path}",
            ]

            res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
            t2 = time.time()
        finally:
            # Suppression du fichier temporaire
            if os.path.exists(temp_file_path):
                os.remove(temp_file_path)

        sys.stderr.write(
            f"[BENCHMARK] Image : {t1 - t0:.2f}s | Appel Network (curl.exe) : {t2 - t1:.2f}s | Total : {t2 - t0:.2f}s\n"
        )

        if res.returncode != 0 or not res.stdout:
            raise RuntimeError(f"Échec de l'exécution curl.exe : {res.stderr}")

        try:
            res_json = json.loads(res.stdout)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Réponse Gemini non exploitable ou erreur API : {res.stdout}")

        # Diagnostic thinking_level : la réponse indique le nombre RÉEL de tokens dépensés
        # en réflexion. Si thoughts_token_count > 0 malgré thinking_level="minimal" dans la
        # requête, le paramètre n'est pas honoré par l'API pour ce modèle — la latence ne vient
        # alors PAS d'un oubli de configuration côté script, mais d'une limite du modèle/API.
        usage = res_json.get("usageMetadata", {})
        tokens_reflexion = usage.get("thoughtsTokenCount", 0)
        tokens_total = usage.get("totalTokenCount", 0)
        if tokens_reflexion > 0:
            diagnostic = "-> thinking_level=minimal IGNORE par l'API"
        else:
            diagnostic = "-> thinking bien desactive, latence due a autre chose"
        sys.stderr.write(
            f"[BENCHMARK] Tokens de reflexion (thinking) : {tokens_reflexion} | Total tokens : {tokens_total} {diagnostic}\n"
        )

        try:
            raw_text = res_json["candidates"][0]["content"]["parts"][0]["text"]
            return json.loads(raw_text)
        except (KeyError, IndexError, json.JSONDecodeError) as e:
            raise RuntimeError(
                f"Réponse Gemini non exploitable ou erreur API : {res.stdout}"
            )


def resultat_vers_dict(donnees: IdentityDocumentRecto) -> dict:
    champs = donnees.model_dump()
    champs["document_type"] = donnees.document_type.value
    champs["source"] = "gemini_vision"
    return champs


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"erreur": "Usage: python gemini_extractor.py <chemin_image>"}))
        sys.exit(1)

    chemin_image = sys.argv[1]

    if not os.environ.get("GEMINI_API_KEY"):
        print(json.dumps({"erreur": "Variable d'environnement GEMINI_API_KEY absente (voir .env)."}))
        sys.exit(1)

    try:
        extracteur = GeminiKYCExtractor()
        donnees = extracteur.extract_recto(chemin_image)
    except FileNotFoundError as e:
        print(json.dumps({"erreur": str(e)}, ensure_ascii=False))
        sys.exit(1)
    except RuntimeError as e:
        print(json.dumps({"erreur": str(e)}, ensure_ascii=False))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"erreur": f"Échec de l'appel Gemini : {e}"}, ensure_ascii=False))
        sys.exit(1)

    accepte, motif = decider_acceptabilite(donnees.document_type, donnees.country)
    champs = resultat_vers_dict(donnees)
    champs["document_accepte"] = accepte
    champs["motif_decision"] = motif

    if not accepte:
        print(json.dumps({"results": champs, "errors": motif}, ensure_ascii=False))
        return

    if donnees.uncertain_fields:
        print(json.dumps({
            "results": champs,
            "errors": f"Champs incertains selon Gemini, vérification manuelle recommandée : {donnees.uncertain_fields}",
        }, ensure_ascii=False))
        return

    print(json.dumps({"results": champs, "errors": ""}, ensure_ascii=False))


if __name__ == "__main__":
    main()
