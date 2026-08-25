"""
nationalite_lib.py
-------------------
Bibliothèque Robot Framework (module-based library) : vérifie si la nationalité affichée
sur le portail KAABU correspond à un pays dont la CNI est acceptée pour l'inscription/
modification, en réutilisant PAYS_CNI_ACCEPTEE de schemas.py comme UNIQUE source de vérité.

Pourquoi ne pas juste dupliquer la liste dans variables.robot ? schemas.py documente déjà
un cas réel où ce genre de liste doit être mise à jour (retrait CEDEAO du Mali/Burkina/Niger
en 2025, décision métier KAABU de continuer à les accepter quand même) — avoir DEUX listes
(une en Python, une en Robot) qui doivent être modifiées en même temps est une source
classique d'oubli/désynchronisation. En passant par cette bibliothèque, il suffit de
modifier schemas.py (ou config/pays_cni_acceptee.txt, ou la variable d'environnement
PAYS_CNI_ACCEPTEE — voir schemas.py) pour que le comportement change aussi côté Robot.
"""
from schemas import PAYS_CNI_ACCEPTEE

# Nom affiché sur le portail KAABU (champ "nationalité", en français, tel qu'observé en
# production) -> code ISO 3166 alpha-3 utilisé par schemas.PAYS_CNI_ACCEPTEE. Les variantes
# avec/sans accents et espaces sont listées pour absorber les différences d'affichage.
NOMS_PORTAIL_VERS_ISO = {
    "BENIN": "BEN",
    "BÉNIN": "BEN",
    "CAP-VERT": "CPV",
    "CAP VERT": "CPV",
    "GAMBIE": "GMB",
    "GHANA": "GHA",
    "GUINEE": "GIN",
    "GUINÉE": "GIN",
    "GUINEE-BISSAU": "GNB",
    "GUINÉE-BISSAU": "GNB",
    "GUINEE BISSAU": "GNB",
    "COTE D IVOIRE": "CIV",
    "COTE D'IVOIRE": "CIV",
    "CÔTE D'IVOIRE": "CIV",
    "CÔTE D IVOIRE": "CIV",
    "LIBERIA": "LBR",
    "LIBÉRIA": "LBR",
    "NIGERIA": "NGA",
    "NIGÉRIA": "NGA",
    "SENEGAL": "SEN",
    "SÉNÉGAL": "SEN",
    "SN": "SEN",
    "SIERRA LEONE": "SLE",
    "TOGO": "TGO",
    "BURKINA FASO": "BFA",
    "MALI": "MLI",
    "NIGER": "NER",
    "MAURITANIE": "MRT",
}


def nationalite_est_eligible(nom_affiche):
    """Keyword Robot Framework "Nationalite Est Eligible" : True si le nom de pays affiché
    sur le portail correspond à un pays de PAYS_CNI_ACCEPTEE (schemas.py), False sinon —
    y compris si le nom affiché n'est reconnu dans aucune des variantes ci-dessus (mieux
    vaut ignorer un dossier à vérifier manuellement que le traiter à tort)."""
    nom_normalise = (nom_affiche or "").strip().upper()
    code_iso = NOMS_PORTAIL_VERS_ISO.get(nom_normalise)
    if not code_iso:
        return False
    return code_iso in PAYS_CNI_ACCEPTEE
