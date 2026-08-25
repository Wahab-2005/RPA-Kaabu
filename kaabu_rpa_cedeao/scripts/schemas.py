"""
schemas.py
----------
Schémas Pydantic pour l'extraction KYC via Gemini Vision.

Historique : la première version de ce schéma utilisait un Enum Python pour le champ
"country" (SEN, MRT, CIV, MLI, GIN, UNKNOWN). C'était un bug bloquant : avec
response_schema + Enum, l'API Gemini applique un DÉCODAGE CONTRAINT côté serveur — le
modèle ne peut littéralement pas retourner une valeur hors de la liste. Le Burkina Faso
(BFA), pourtant dans le périmètre du projet dès le départ, en était absent : toute carte
burkinabè aurait silencieusement reçu "UNKNOWN" (ou pire, un autre code de la liste) sans
aucune erreur remontée. D'où le choix ci-dessous : "country" est une chaîne libre (le
modèle lit ce qui est imprimé), et la logique d'acceptation/rejet par pays est gérée
SÉPARÉMENT, en code, dans une liste explicite et facile à maintenir (voir PAYS_CNI_ACCEPTEE
plus bas) — cohérent avec le principe déjà en place ailleurs dans le projet : "ajouter un
pays ne doit jamais nécessiter une nouvelle branche de logique, juste une entrée de
configuration".
"""
import os
from enum import Enum
from typing import Optional, List
from pydantic import BaseModel, Field


class DocumentType(str, Enum):
    ID_CARD = "ID_CARD"       # Carte nationale d'identité (CNI CEDEAO ou assimilée)
    PASSPORT = "PASSPORT"
    OTHER = "OTHER"            # Ni l'un ni l'autre, ou image illisible / mauvais document


# ----------------------------------------------------------------------------
# Pays dont la CNI est acceptée pour l'inscription KAABU.
#
# ATTENTION : ceci n'est PAS la liste des membres institutionnels actuels de la CEDEAO.
# Le Mali, le Burkina Faso et le Niger ont officiellement quitté la CEDEAO le 29 janvier
# 2025. La CEDEAO elle-même continue cependant de demander à ses membres restants de
# reconnaître les cartes d'identité et passeports de ces trois pays "jusqu'à nouvel ordre"
# (statut encore incertain à ce jour). KAABU a fait le choix métier de continuer à accepter
# leurs CNI. Cette liste reflète donc une DÉCISION MÉTIER KAABU, distincte de la situation
# géopolitique — à réviser périodiquement si cette dernière évolue encore.
#
# CONFIGURABLE SANS TOUCHER AU CODE (la situation politique régionale reste mouvante) :
#   1. Fichier config/pays_cni_acceptee.txt : un code pays ISO alpha-3 par ligne, lignes
#      vides et lignes commençant par '#' ignorées. Pris en compte s'il existe.
#   2. Sinon, variable d'environnement PAYS_CNI_ACCEPTEE : codes séparés par des virgules
#      (ex: "SEN,BFA,MRT,MLI,NER,CIV,GIN,..."). Pratique pour un override rapide (ex: tests,
#      changement d'urgence) sans passer par un déploiement de fichier.
#   3. Sinon, repli sur DEFAUT_PAYS_CNI_ACCEPTEE ci-dessous.
#
# Valeurs par défaut (si ni fichier ni variable d'environnement ne sont présents) :
#   Membres CEDEAO actuels (12, hors retraits) : BEN, CPV, GMB, GHA, GIN, GNB, CIV, LBR,
#   NGA, SEN, SLE, TGO.
#   Ajouts métier KAABU (retraits CEDEAO 2025 toujours acceptés en pratique) : BFA, MLI, NER.
#   Ajout métier KAABU (jamais membre CEDEAO, mais dans le périmètre projet dès le départ,
#   cf. cartes mauritaniennes déjà traitées) : MRT.
# ----------------------------------------------------------------------------
DEFAUT_PAYS_CNI_ACCEPTEE = {
    "BEN", "CPV", "GMB", "GHA", "GIN", "GNB", "CIV", "LBR", "NGA", "SEN", "SLE", "TGO",
    "BFA", "MLI", "NER", "MRT",
}

_CHEMIN_CONFIG_PAYS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "config", "pays_cni_acceptee.txt"
)


def _charger_pays_cni_acceptee():
    """Résout la liste des pays acceptés selon l'ordre de priorité documenté ci-dessus
    (fichier de config > variable d'environnement > valeurs par défaut en dur). Toute erreur
    de lecture du fichier (droits, encodage) se replie silencieusement sur l'étape suivante
    plutôt que de faire planter tout le module au démarrage — cohérent avec le principe
    "échec non-fatal, on continue avec le meilleur repli disponible" déjà appliqué ailleurs
    dans le projet (ex: OCR non-fatal -> dict vide)."""
    if os.path.isfile(_CHEMIN_CONFIG_PAYS):
        try:
            with open(_CHEMIN_CONFIG_PAYS, "r", encoding="utf-8") as f:
                codes = {
                    ligne.strip().upper()
                    for ligne in f
                    if ligne.strip() and not ligne.strip().startswith("#")
                }
            if codes:
                return codes
        except OSError:
            pass  # on se rabat sur la variable d'environnement puis le défaut

    variable_env = os.environ.get("PAYS_CNI_ACCEPTEE", "")
    if variable_env.strip():
        codes = {c.strip().upper() for c in variable_env.split(",") if c.strip()}
        if codes:
            return codes

    return set(DEFAUT_PAYS_CNI_ACCEPTEE)


PAYS_CNI_ACCEPTEE = _charger_pays_cni_acceptee()


class IdentityDocumentRecto(BaseModel):
    """Champs alignés sur ocr_mrz.py (firstname/lastname/birth_date/document_number...)
    pour que la logique de comparaison Robot Framework n'ait pas besoin de distinguer la
    source (Gemini recto vs MRZ verso) par un mapping de noms différents."""

    document_type: DocumentType = Field(
        description="Type de document identifié sur l'image : ID_CARD (carte nationale "
                     "d'identité), PASSPORT, ou OTHER si ni l'un ni l'autre / image illisible."
    )
    country: str = Field(
        default="",
        description="Code ISO 3166 alpha-3 du pays émetteur tel que déductible du document "
                     "(ex: SEN, BFA, MRT, CIV, NGA...). Chaîne vide si indéterminable — NE PAS "
                     "deviner un pays si l'information n'est pas clairement lisible.",
    )
    document_number: str = Field(
        default="",
        description="Le numéro de CARTE (pas le NIN — le NIN se trouve au verso) — sur une "
                     "CNI CEDEAO récente, c'est généralement le numéro imprimé en gros "
                     "caractères en bas de carte (souvent une lettre suivie de chiffres, ex: "
                     "B19561838), PAS le numéro d'enregistrement/dossier s'il y en a un "
                     "second. Chiffres et lettres uniquement, sans espaces.",
    )
    secondary_number: str = Field(
        default="",
        description="Si un SECOND numéro distinct apparaît sur le document (numéro "
                     "d'enregistrement, de dossier, ou NIN séparé du numéro de document "
                     "principal), indique-le ici. Chaîne vide si un seul numéro est présent.",
    )
    lastname: str = Field(default="", description="Nom de famille, en MAJUSCULES, tel qu'imprimé.")
    firstname: str = Field(default="", description="Prénom(s), en MAJUSCULES, tel qu'imprimé.")
    birth_date: str = Field(default="", description="Date de naissance au format JJ/MM/AAAA.")
    birth_place: str = Field(default="", description="Lieu de naissance tel qu'imprimé.")
    delivery_date: str = Field(default="", description="Date de délivrance au format JJ/MM/AAAA.")
    delivery_place: str = Field(default="", description="Lieu/centre/autorité de délivrance tel qu'imprimé.")
    expiration_date: str = Field(default="", description="Date d'expiration au format JJ/MM/AAAA.")
    address: str = Field(default="", description="Adresse du domicile telle qu'imprimée, si présente sur cette face.")
    sex: str = Field(default="", description="'M' ou 'F' exactement, chaîne vide si illisible.")
    height: str = Field(default="", description="Taille avec unité telle qu'imprimée (ex: '163 cm'), chaîne vide si absente.")

    uncertain_fields: List[str] = Field(
        default_factory=list,
        description="Noms des champs ci-dessus (ex: 'lastname', 'document_number') lus avec une "
                     "confiance insuffisante — image floue, reflet, doigt sur le texte, caractère "
                     "ambigu. Sois strict : mieux vaut signaler un doute que produire une valeur "
                     "fausse avec l'air fiable.",
    )


class IdentityDocumentVerso(BaseModel):
    """Champs extraits du VERSO d'une CNI CEDEAO : le NIN imprimé (utilisé comme
    vérification croisée du NIN déjà extrait sur le recto) et la zone MRZ (Machine Readable
    Zone), lue telle quelle sans interprétation — c'est du texte brut sur 3 lignes en format
    TD1, avec des '<' comme caractères de remplissage. On ne parse PAS la MRZ côté Gemini
    (pas de reconstruction de date/nom depuis les lignes) : la comparaison recto/verso se
    fait uniquement sur le NIN, la MRZ brute est conservée pour trace/débogage."""

    nin: str = Field(
        default="",
        description="Le NIN (numéro d'identification national) tel qu'imprimé en clair sur "
                     "le verso, hors zone MRZ. Chiffres et lettres uniquement, sans espaces. "
                     "Chaîne vide si absent ou illisible.",
    )
    mrz_line1: str = Field(default="", description="Première ligne de la zone MRZ (bande de caractères en bas du document), telle qu'imprimée, MAJUSCULES, '<' inclus.")
    mrz_line2: str = Field(default="", description="Deuxième ligne de la zone MRZ, telle qu'imprimée, MAJUSCULES, '<' inclus.")
    mrz_line3: str = Field(default="", description="Troisième ligne de la zone MRZ si présente (format TD1 à 3 lignes), telle qu'imprimée. Chaîne vide si le document n'a que 2 lignes MRZ.")

    uncertain_fields: List[str] = Field(
        default_factory=list,
        description="Noms des champs ci-dessus lus avec une confiance insuffisante — image "
                     "floue, reflet, pli sur le document, caractère ambigu dans la MRZ. Sois "
                     "strict : mieux vaut signaler un doute que produire une valeur fausse.",
    )


def pays_accepte_pour_cni(code_pays: str) -> bool:
    """True si la CNI de ce pays est acceptée pour l'inscription (voir PAYS_CNI_ACCEPTEE).
    Un pays absent de cette liste (ou un code pays vide/indéterminé) signifie que SEUL un
    passeport peut être accepté pour ce document — voir decider_acceptabilite() ci-dessous
    pour la décision complète type de document + pays."""
    return (code_pays or "").strip().upper() in PAYS_CNI_ACCEPTEE


def decider_acceptabilite(document_type: DocumentType, country: str):
    """Applique la règle métier : CNI acceptée uniquement pour les pays de
    PAYS_CNI_ACCEPTEE ; pour tout autre pays, SEUL un passeport est accepté pour
    l'inscription. Retourne (accepte: bool, motif: str) — motif toujours renseigné même si
    accepte=True, pour traçabilité dans les logs/journal.jsonl."""
    if document_type == DocumentType.OTHER:
        return False, "Type de document non reconnu (ni CNI ni passeport identifiable)."

    if document_type == DocumentType.PASSPORT:
        return True, "Passeport accepté quel que soit le pays."

    # document_type == ID_CARD à partir d'ici
    if not country:
        return False, "Pays émetteur indéterminable sur la CNI — vérification manuelle requise avant décision."

    if pays_accepte_pour_cni(country):
        return True, "CNI acceptée : {} figure dans la liste des pays autorisés pour les CNI.".format(country)

    return False, (
        "CNI du pays {} non acceptée pour l'inscription — seul un passeport est accepté pour "
        "les pays hors liste (voir PAYS_CNI_ACCEPTEE dans schemas.py).".format(country)
    )
