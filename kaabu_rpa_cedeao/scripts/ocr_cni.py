"""
Wrapper CLI appelé par resources/verification_cni.robot :
    python3 ocr_cni.py <chemin_recto> <chemin_verso>

Utilise gemini_extractor.py (GeminiKYCExtractor.extract_recto + extract_verso) pour
l'extraction des DEUX faces.

IMPORTANT — le NIN vient du VERSO, pas du recto : sur cette CNI CEDEAO, le numéro imprimé
en gros caractères sur le recto est le numéro DE CARTE (distinct), tandis que le vrai NIN
(celui attendu par le champ écran "Numéro de pièce" sur Kaabu) n'est lisible qu'au verso.
Champs de sortie :
    - nin           : le vrai NIN, lu sur le VERSO — c'est LE champ critique comparé à
                       l'écran/Tango côté Robot Framework (voir verification_cni.robot /
                       report_modification_client.robot, aucun changement requis côté eux :
                       ils lisent déjà la clé "nin" de façon générique).
    - numero_carte  : le numéro de carte lu sur le RECTO (document_number), conservé à titre
                       informatif uniquement — PAS comparé, PAS utilisé pour valider un dossier.
    - mrz_line1/2/3 : zone MRZ brute du verso (texte tel quel, non parsé), pour trace/débogage.
Voir schemas.IdentityDocumentRecto / IdentityDocumentVerso pour le détail des schémas.

Contrat de sortie inchangé, pour ne rien casser côté Robot Framework :
    Succès : {"results": {...}, "errors": ""}
    Échec  : {"erreur": "..."}   (code de sortie 1)

Robustesse verso : une erreur sur l'extraction VERSO (image floue, MRZ/NIN illisible...) ne
fait PAS lever d'exception ici — "nin" reste vide et "verso_erreur" décrit la cause. Le NIN
étant un champ critique, les keywords Robot Framework existants traitent déjà un NIN
vide/absent comme une incohérence nécessitant une vérification manuelle (voir "nin_ok" dans
Verifier Coherence CNI), donc aucun changement de comportement requis de leur côté pour ce
cas. Seule une erreur de QUOTA sur le verso remonte jusqu'à la rotation de clés (voir plus
bas), car elle affecte aussi le recto avec la même clé.

Rotation de clés : essaie GEMINI_API_KEY_1, _2, _3 (ou GEMINI_API_KEY générique) l'une
après l'autre UNIQUEMENT en cas d'erreur de quota (429 / RESOURCE_EXHAUSTED) sur une clé.
Sur toute autre erreur (image corrompue, réponse Gemini invalide...), on échoue tout de
suite sans gaspiller les autres clés sur un problème qui ne vient pas d'elles.

Installation :
    pip install pillow pydantic python-dotenv --break-system-packages
    + curl.exe disponible dans le PATH (préinstallé sur Windows 10 1803+ / Windows 11)
"""
import os
import sys
import json

from dotenv import load_dotenv

from gemini_extractor import GeminiKYCExtractor, resultat_vers_dict
from schemas import decider_acceptabilite

load_dotenv()

CLES_API = [
    v for v in [
        os.getenv("GEMINI_API_KEY_1"),
        os.getenv("GEMINI_API_KEY_2"),
        os.getenv("GEMINI_API_KEY_3"),
        os.getenv("GEMINI_API_KEY"),
    ] if v
]

RENOMMAGE_CHAMPS = {"document_number": "numero_carte"}

INDICATEURS_QUOTA = ("429", "RESOURCE_EXHAUSTED", "quota")


def _est_erreur_quota(exception):
    message = str(exception)
    return any(indicateur in message for indicateur in INDICATEURS_QUOTA)


def extraire_et_mapper_verso(chemin_verso, cle_api):
    """Extrait le verso : c'est ICI, et uniquement ici, que se trouve le vrai NIN (le numéro
    du recto n'est que le numéro de carte, distinct — voir RENOMMAGE_CHAMPS). Retourne un
    dict avec la clé critique "nin" (vide si extraction échouée/illisible — les keywords
    Robot Framework traitent déjà un NIN vide/absent comme incohérence à vérifier
    manuellement, donc aucune dégradation silencieuse) et "mrz_line1/2/3" à titre
    informatif. Une erreur de QUOTA est relancée telle quelle (propagée) pour déclencher la
    rotation de clés au niveau appelant ; toute autre erreur (image floue, MRZ illisible...)
    est absorbée ici et journalisée dans "verso_erreur", sans faire échouer tout le dossier."""
    champs_verso = {
        "nin": "",
        "mrz_line1": "",
        "mrz_line2": "",
        "mrz_line3": "",
        "verso_uncertain_fields": [],
        "verso_erreur": "",
    }
    try:
        extracteur = GeminiKYCExtractor(api_key=cle_api)
        donnees_verso = extracteur.extract_verso(chemin_verso)
        champs_verso["nin"] = donnees_verso.nin
        champs_verso["mrz_line1"] = donnees_verso.mrz_line1
        champs_verso["mrz_line2"] = donnees_verso.mrz_line2
        champs_verso["mrz_line3"] = donnees_verso.mrz_line3
        champs_verso["verso_uncertain_fields"] = donnees_verso.uncertain_fields
    except Exception as e:
        if _est_erreur_quota(e):
            raise
        sys.stderr.write(
            f"⚠️ Extraction du verso échouée — NIN indisponible pour ce dossier "
            f"(vérification manuelle nécessaire) : {e}\n"
        )
        champs_verso["verso_erreur"] = str(e)
    return champs_verso


def extraire_et_mapper(chemin_recto, chemin_verso, cle_api):
    extracteur = GeminiKYCExtractor(api_key=cle_api)
    donnees = extracteur.extract_recto(chemin_recto)
    champs = resultat_vers_dict(donnees)

    for ancien, nouveau in RENOMMAGE_CHAMPS.items():
        if ancien in champs:
            champs[nouveau] = champs.pop(ancien)

    accepte, motif = decider_acceptabilite(donnees.document_type, donnees.country)
    champs["document_accepte"] = accepte
    champs["motif_decision"] = motif

    # Le NIN (champ critique comparé à l'écran/Tango) vient du verso — voir docstring de
    # extraire_et_mapper_verso. Il écrase toute clé "nin" préexistante (il n'y en a plus
    # depuis le renommage document_number -> numero_carte ci-dessus, mais on le fait quand
    # même explicitement pour que ce soit sans ambiguïté à la lecture).
    champs_verso = extraire_et_mapper_verso(chemin_verso, cle_api)
    champs.update(champs_verso)

    # Important : on NE remonte PAS ces motifs dans "errors" — ce champ déclenche côté
    # Robot Framework un retry technique (3 tentatives avec pause croissante), pertinent
    # pour une vraie panne API mais inutile ici : un rejet pays/document ou un champ
    # incertain donnera le même résultat à chaque nouvelle tentative. L'info reste
    # disponible dans results["document_accepte"] / ["motif_decision"] / ["uncertain_fields"]
    # pour une décision côté Robot (voir note d'intégration transmise séparément).
    return champs, ""


def main():
    if len(sys.argv) != 3:
        print(json.dumps({"erreur": "Usage: python3 ocr_cni.py <recto> <verso>"}))
        sys.exit(1)

    chemin_recto, chemin_verso = sys.argv[1], sys.argv[2]

    if not os.path.isfile(chemin_recto):
        print(json.dumps({"erreur": f"Fichier recto introuvable : {chemin_recto}"}, ensure_ascii=False))
        sys.exit(1)
    if os.path.getsize(chemin_recto) == 0:
        print(json.dumps({
            "erreur": f"Fichier recto vide (0 octet) : {chemin_recto} — probable échec de "
                      f"téléchargement/capture en amont."
        }, ensure_ascii=False))
        sys.exit(1)
    if not os.path.isfile(chemin_verso):
        print(json.dumps({"erreur": f"Fichier verso introuvable : {chemin_verso}"}, ensure_ascii=False))
        sys.exit(1)
    if os.path.getsize(chemin_verso) == 0:
        print(json.dumps({
            "erreur": f"Fichier verso vide (0 octet) : {chemin_verso} — probable échec de "
                      f"téléchargement/capture en amont."
        }, ensure_ascii=False))
        sys.exit(1)

    if not CLES_API:
        print(json.dumps({
            "erreur": "Aucune clé Gemini configurée (GEMINI_API_KEY_1/2/3 ou GEMINI_API_KEY)."
        }, ensure_ascii=False))
        sys.exit(1)

    derniere_erreur = None
    for i, cle_api in enumerate(CLES_API):
        try:
            champs, erreurs_metier = extraire_et_mapper(chemin_recto, chemin_verso, cle_api)
            print(json.dumps({"results": champs, "errors": erreurs_metier}, ensure_ascii=False))
            sys.exit(0)

        except Exception as e:
            derniere_erreur = e
            if _est_erreur_quota(e) and i < len(CLES_API) - 1:
                sys.stderr.write(
                    f"Quota atteint sur la clé Gemini n°{i + 1} — bascule sur la clé suivante.\n"
                )
                continue
            break

    print(json.dumps({"erreur": str(derniere_erreur)}, ensure_ascii=False))
    sys.exit(1)


if __name__ == "__main__":
    main()
