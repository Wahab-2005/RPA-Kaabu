"""
test_ocr_tesseract_v4.py
--------------------------
Extraction OCR structurée pour cartes d'identité CEDEAO — conçu pour tolérer
les variations de mise en page entre pays membres (toutes les cartes CEDEAO
ne sont pas identiques : ordre des champs, langue dominante, libellés).

Principe : contrairement à un recadrage sur des positions fixes en pixels
(qui ne marche que sur UNE photo précise), tous les champs sont retrouvés
par repérage de LIBELLÉ dans le texte OCR, avec plusieurs synonymes possibles
par champ (français / anglais / portugais) et une recherche "mot entier"
(pas juste "contient" — bug corrigé : une recherche naïve de "NOM" matchait
à tort à l'intérieur de "PRÉNOMS" une fois les accents retirés).

Installation :
    pip install pytesseract Pillow --break-system-packages
    + moteur Tesseract : https://github.com/UB-Mannheim/tesseract/wiki
      (cocher French — English est inclus par défaut, Portuguese optionnel)

Utilisation :
    python test_ocr_tesseract_v4.py chemin\\vers\\cni_recto.jpg
    python test_ocr_tesseract_v4.py chemin\\vers\\cni_recto.jpg --haut 0 --bas 1
    (--haut 0 --bas 1 désactive le recadrage, pour une image déjà bien cadrée
    sur la carte ou un scan)
"""
import sys
import os
import re
import json
import argparse
import unicodedata

try:
    import pytesseract
    from PIL import Image, ImageOps
except ImportError as e:
    print(f"ERREUR: dépendance manquante ({e}).")
    print("Lancez : pip install pytesseract Pillow --break-system-packages")
    sys.exit(1)

# ----------------------------------------------------------------------------
# Si Tesseract n'est pas dans le PATH Windows, décommentez et ajustez :
# ----------------------------------------------------------------------------
# pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"


# ----------------------------------------------------------------------------
# Libellés connus par champ, en plusieurs langues (les cartes CEDEAO sont
# bilingues/trilingues FR/EN/PT selon le pays émetteur). Ajouter un synonyme
# ici suffit à couvrir une nouvelle variante de carte — pas besoin de créer
# un "profil" séparé par pays.
# ----------------------------------------------------------------------------
LIBELLES = {
    "firstname": ["PRENOMS", "PRENOM", "GIVEN NAMES", "GIVEN NAME", "NOMES"],
    "lastname": ["NOM", "SURNAME", "FAMILY NAME"],
    "birth_place": ["LIEU DE NAISSANCE", "PLACE OF BIRTH", "NATURALIDADE"],
    "delivery_place": ["CENTRE D ENREGISTREMENT", "CENTRO DE REGISTO", "ISSUING AUTHORITY", "AUTORITE"],
    "address": ["ADRESSE DU DOMICILE", "ADRESSE", "ADDRESS", "MORADA"],
    "card_id_label": ["N DE LA CARTE", "IDENTITY CARD NO", "IDENTIFICATION NO", "BILHETE DE IDENTIDADE NO"],
    "birth_date_label": ["NAISSANCE", "BIRTH", "NASCIMENTO"],
    "delivery_date_label": ["DELIVRANCE", "DELIVREE", "ISSUE", "EMISSAO"],
    "expiration_date_label": ["EXPIRATION", "EXPIRY", "VALIDADE"],
    "sex_label": ["SEXE", "SEX", "SEXO"],
    "height_label": ["TAILLE", "HEIGHT", "ALTURA"],
}


def normaliser(texte):
    """Majuscules, accents retirés, ponctuation de séparation neutralisée."""
    texte = texte.upper()
    texte = unicodedata.normalize("NFKD", texte).encode("ascii", "ignore").decode()
    texte = re.sub(r"[°'ºÀ-ÿ]", " ", texte)
    texte = re.sub(r"\s+", " ", texte).strip()
    return texte


def ligne_contient_libelle(ligne_normalisee, libelle):
    """Recherche 'mot entier' (pas juste 'contient') pour éviter les faux
    positifs — ex: 'NOM' ne doit PAS matcher à l'intérieur de 'PRENOMS'."""
    motif = r"\b" + re.escape(libelle) + r"\b"
    return re.search(motif, ligne_normalisee) is not None


def preparer_image_carte(chemin_image, fraction_haut=0.26, fraction_bas=0.73):
    """Corrige la rotation EXIF, recadre (optionnel), agrandit x2 + contraste."""
    image = Image.open(chemin_image)
    image = ImageOps.exif_transpose(image)
    largeur, hauteur = image.size
    if fraction_haut > 0 or fraction_bas < 1:
        image = image.crop((0, int(hauteur * fraction_haut), largeur, int(hauteur * fraction_bas)))
    image = image.resize((image.width * 2, image.height * 2), Image.LANCZOS)
    image = image.convert("L")
    image = ImageOps.autocontrast(image, cutoff=1)
    return image


def langue_ocr():
    """Utilise français+anglais+portugais si les 3 paquets sont installés,
    sinon se replie sur les langues réellement disponibles (au minimum
    l'anglais, toujours installé par défaut avec Tesseract)."""
    try:
        installees = set(pytesseract.get_languages(config=""))
    except Exception:
        return "eng"
    voulues = [l for l in ["fra", "eng", "por"] if l in installees]
    return "+".join(voulues) if voulues else "eng"


def ocr_pleine_carte(image_carte):
    return pytesseract.image_to_string(image_carte, lang=langue_ocr(), config="--psm 6")


def chercher_valeur_validee(lignes_originales, lignes_normalisees, synonymes, motif_attendu, offset_max=3):
    """Cherche TOUTES les lignes correspondant à un des libellés (pas juste la
    première), et retourne la première valeur qui correspond au motif attendu
    (regex) dans les lignes suivantes. Plus robuste que 'juste la première
    occurrence du libellé' : évite par exemple de confondre le titre de la
    carte ('CARTE D'IDENTITE CEDEAO') avec le vrai libellé du numéro."""
    for i, ligne in enumerate(lignes_normalisees):
        if any(ligne_contient_libelle(ligne, lib) for lib in synonymes):
            for j in range(i, min(i + offset_max, len(lignes_originales))):
                m = re.search(motif_attendu, lignes_originales[j])
                if m:
                    return m.group()
    return ""


def trouver_ligne_libelle(lignes_normalisees, synonymes):
    """Retourne l'index de la première ligne contenant un des libellés donnés
    (recherche mot entier), ou None si aucun trouvé."""
    for i, ligne in enumerate(lignes_normalisees):
        for libelle in synonymes:
            if ligne_contient_libelle(ligne, libelle):
                return i
    return None


def valeur_apres_libelle(lignes_originales, lignes_normalisees, synonymes, nb_lignes=1):
    """Trouve le libellé puis retourne la/les ligne(s) suivante(s) (texte
    original, pas normalisé, pour préserver la casse d'origine des valeurs)."""
    idx = trouver_ligne_libelle(lignes_normalisees, synonymes)
    if idx is None:
        return ""
    valeurs = []
    for j in range(1, nb_lignes + 1):
        if idx + j < len(lignes_originales) and lignes_originales[idx + j].strip():
            valeurs.append(lignes_originales[idx + j].strip())
    return " ".join(valeurs)


def nettoyer_texte(valeur):
    valeur = re.sub(r"[^A-Za-zÀ-ÿ\s'\-]", " ", valeur)
    valeur = re.sub(r"\s+", " ", valeur).strip()
    return valeur


def extraire_date_pres_de(lignes_originales, lignes_normalisees, synonymes):
    """Cherche une date (JJ/MM/AAAA) sur la ligne du libellé lui-même ou sur
    la/les ligne(s) suivante(s) — tolère les deux mises en page rencontrées
    (valeur sur la même ligne que le libellé, ou sur la ligne d'après)."""
    idx = trouver_ligne_libelle(lignes_normalisees, synonymes)
    if idx is None:
        return ""
    for i in range(idx, min(idx + 3, len(lignes_originales))):
        m = re.search(r"\d{1,2}[/\-.]\d{1,2}[/\-.]\d{4}", lignes_originales[i])
        if m:
            return m.group().replace("-", "/").replace(".", "/")
    return ""


def toutes_les_dates(texte):
    """Repli si les libellés de date ne sont pas retrouvés (mise en page
    inconnue) : toutes les dates du document, dans l'ordre d'apparition."""
    return re.findall(r"\d{1,2}[/\-.]\d{1,2}[/\-.]\d{4}", texte)


def extraire_donnees_cni(chemin_image, fraction_haut=0.26, fraction_bas=0.73):
    image_carte = preparer_image_carte(chemin_image, fraction_haut, fraction_bas)
    texte_brut = ocr_pleine_carte(image_carte)

    lignes_originales = [l.strip() for l in texte_brut.split("\n") if l.strip()]
    lignes_normalisees = [normaliser(l) for l in lignes_originales]

    donnees = {}
    champs_a_verifier = []

    donnees["firstname"] = nettoyer_texte(
        valeur_apres_libelle(lignes_originales, lignes_normalisees, LIBELLES["firstname"])
    )
    donnees["lastname"] = nettoyer_texte(
        valeur_apres_libelle(lignes_originales, lignes_normalisees, LIBELLES["lastname"])
    )
    donnees["birth_place"] = nettoyer_texte(
        valeur_apres_libelle(lignes_originales, lignes_normalisees, LIBELLES["birth_place"])
    )
    donnees["delivery_place"] = nettoyer_texte(
        valeur_apres_libelle(lignes_originales, lignes_normalisees, LIBELLES["delivery_place"])
    )
    donnees["address"] = nettoyer_texte(
        valeur_apres_libelle(lignes_originales, lignes_normalisees, LIBELLES["address"])
    )

    if not donnees["firstname"]:
        champs_a_verifier.append("firstname")
    if not donnees["lastname"]:
        champs_a_verifier.append("lastname")

    # --- N° de carte : cherché via toutes les occurrences du libellé, on garde
    # celle dont la ligne suivante contient vraiment une longue suite de chiffres
    # (évite de confondre avec le titre "CARTE D'IDENTITE CEDEAO" en haut de la carte) ---
    donnees["card_id"] = chercher_valeur_validee(
        lignes_originales, lignes_normalisees, LIBELLES["card_id_label"], r"[\d\s]{10,}"
    )
    if donnees["card_id"]:
        donnees["card_id"] = re.sub(r"\s+", " ", donnees["card_id"]).strip()
    else:
        champs_a_verifier.append("card_id")

    # --- Dates : recherche validée par libellé (mots-clés courts, tolérants à
    # une perte de préfixe par l'OCR type "Date de" -> "De de"), repli sur
    # "toutes les dates du document" si le libellé n'est pas retrouvé du tout ---
    motif_date = r"\d{1,2}[/\-.]\d{1,2}[/\-.]\d{4}"
    donnees["birth_date"] = chercher_valeur_validee(
        lignes_originales, lignes_normalisees, LIBELLES["birth_date_label"], motif_date
    )
    donnees["delivery_date"] = chercher_valeur_validee(
        lignes_originales, lignes_normalisees, LIBELLES["delivery_date_label"], motif_date
    )
    donnees["expiration_date"] = chercher_valeur_validee(
        lignes_originales, lignes_normalisees, LIBELLES["expiration_date_label"], motif_date
    )

    # Garde-fou : si deux dates distinctes se retrouvent avec exactement la même
    # valeur, c'est le signe d'une collision de parsing (ex: l'OCR a perdu le
    # séparateur d'une des deux dates sur une ligne qui en contient deux côte à
    # côte) plutôt qu'une vraie coïncidence. On vide la date de délivrance
    # (statistiquement la moins fiable des trois, cf. tests précédents) et on
    # la signale, plutôt que d'afficher une valeur fausse avec l'air fiable.
    if donnees["delivery_date"] and donnees["delivery_date"] == donnees["expiration_date"]:
        donnees["delivery_date"] = ""
    if donnees["delivery_date"] and donnees["delivery_date"] == donnees["birth_date"]:
        donnees["delivery_date"] = ""

    if not (donnees["birth_date"] and donnees["delivery_date"] and donnees["expiration_date"]):
        dates_repli = toutes_les_dates(texte_brut)
        if not donnees["birth_date"] and len(dates_repli) >= 1:
            donnees["birth_date"] = dates_repli[0]
            champs_a_verifier.append("birth_date")
        if not donnees["delivery_date"]:
            champs_a_verifier.append("delivery_date")
        if not donnees["expiration_date"] and len(dates_repli) >= 1:
            donnees["expiration_date"] = dates_repli[-1]
            champs_a_verifier.append("expiration_date")

    # --- Sexe et taille : cherchés sur la ligne du libellé (souvent la même
    # ligne que "Date de naissance", format en colonnes) ---
    idx_naissance = trouver_ligne_libelle(lignes_normalisees, LIBELLES["birth_date_label"])
    zone_sexe_taille = ""
    if idx_naissance is not None:
        for i in range(idx_naissance, min(idx_naissance + 2, len(lignes_originales))):
            zone_sexe_taille += " " + lignes_originales[i]
    match_sexe = re.search(r"\b([MF])\b", zone_sexe_taille)
    donnees["gender"] = match_sexe.group(1) if match_sexe else ""
    match_taille = re.search(r"(\d{2,3})\s*(cm|em)", zone_sexe_taille, re.IGNORECASE)
    donnees["height"] = f"{match_taille.group(1)} cm" if match_taille else ""

    return donnees, champs_a_verifier, texte_brut


def main():
    parser = argparse.ArgumentParser(
        description="OCR Tesseract tolérant aux variations de mise en page des cartes CEDEAO."
    )
    parser.add_argument("image", help="Chemin vers l'image de la CNI (recto)")
    parser.add_argument("--haut", type=float, default=0.26, help="Fraction verticale de début du recadrage (0=désactivé)")
    parser.add_argument("--bas", type=float, default=0.73, help="Fraction verticale de fin du recadrage (1=désactivé)")
    args = parser.parse_args()

    if not os.path.isfile(args.image):
        print(f"ERREUR: fichier introuvable : {args.image}")
        sys.exit(1)

    donnees, champs_a_verifier, texte_brut = extraire_donnees_cni(args.image, args.haut, args.bas)

    resultat = {"results": donnees, "champs_a_verifier": champs_a_verifier, "errors": ""}
    print(json.dumps(resultat, ensure_ascii=False, indent=2))

    base, _ = os.path.splitext(args.image)
    with open(f"{base}_ocr.json", "w", encoding="utf-8") as f:
        json.dump(resultat, f, ensure_ascii=False, indent=2)
    with open(f"{base}_ocr_brut.txt", "w", encoding="utf-8") as f:
        f.write(texte_brut)
    print(f"\nJSON enregistré : {base}_ocr.json")
    print(f"Texte brut (debug) enregistré : {base}_ocr_brut.txt")


if __name__ == "__main__":
    main()
