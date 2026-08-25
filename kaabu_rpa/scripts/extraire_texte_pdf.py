"""
Extrait le texte brut d'un PDF (formulaire d'inscription signé).

Usage :
    python extraire_texte_pdf.py <chemin_pdf>

Tente d'abord une extraction directe du texte (rapide, précise si le PDF
contient une vraie couche de texte). Si le résultat est vide ou trop court
(probable PDF scanné/image), bascule automatiquement sur de l'OCR
(rasterisation des pages + Tesseract).

Affiche le texte concaténé de toutes les pages sur stdout.
En cas d'erreur, affiche "ERREUR: <message>" sur stdout et sort avec le code 1.
"""
import sys
import io
import subprocess
import tempfile
import os

# --- Fix encodage Windows -------------------------------------------------
# Sous Windows, stdout/stderr utilisent par défaut l'encodage de la console
# (souvent cp1252/"charmap"), qui ne sait pas représenter certains caractères
# extraits des PDF (ex: '\u25a1' = "□"). On force UTF-8 avec remplacement des
# caractères non encodables plutôt que de laisser planter le script.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")
# ---------------------------------------------------------------------------

import pdfplumber

SEUIL_CARACTERES_MINIMUM = 30  # en dessous, on considère l'extraction directe insuffisante


def extraire_texte_direct(chemin_pdf):
    texte_complet = []
    with pdfplumber.open(chemin_pdf) as pdf:
        for page in pdf.pages:
            texte_page = page.extract_text() or ""
            texte_complet.append(texte_page)
    return "\n".join(texte_complet)


def extraire_texte_ocr(chemin_pdf):
    from pdf2image import convert_from_path

    with tempfile.TemporaryDirectory() as tmp_dir:
        pages = convert_from_path(chemin_pdf, dpi=300)
        textes = []
        for i, page_image in enumerate(pages):
            chemin_image = os.path.join(tmp_dir, f"page_{i}.png")
            page_image.save(chemin_image, "PNG")
            result = subprocess.run(
                ["tesseract", chemin_image, "stdout", "--psm", "6"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            textes.append(result.stdout)
        return "\n".join(textes)


def nettoyer_texte(texte):
    """Neutralise les caractères qui ne peuvent pas être encodés en UTF-8
    (sécurité supplémentaire, même si stdout est déjà en UTF-8 avec replace)."""
    return texte.encode("utf-8", errors="replace").decode("utf-8")


def main():
    if len(sys.argv) != 2:
        print("ERREUR: Usage: python extraire_texte_pdf.py <chemin_pdf>")
        sys.exit(1)

    chemin_pdf = sys.argv[1]

    try:
        texte = extraire_texte_direct(chemin_pdf)

        if len(texte.strip()) < SEUIL_CARACTERES_MINIMUM:
            texte_ocr = extraire_texte_ocr(chemin_pdf)
            if len(texte_ocr.strip()) > len(texte.strip()):
                texte = texte_ocr

        texte = nettoyer_texte(texte)

        print(texte)
        sys.exit(0)
    except Exception as e:
        print(f"ERREUR: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()