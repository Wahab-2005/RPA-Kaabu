"""
Génère le rapport quotidien d'exécution du RPA KAABU à partir de results/journal.jsonl
et des captures d'écran d'erreur (results/error/), pour être envoyé par email en fin
de journée.

Usage :
    python3 generer_rapport_quotidien.py [AAAA-MM-JJ]

    Si aucune date n'est fournie, la date du jour est utilisée.

Affiche un unique JSON sur stdout (rien d'autre), avec la structure :
{
    "date": "2026-08-07",
    "heure_debut": "08:00:00",
    "heure_fin": "08:22:00",
    "duree_minutes": 22,
    "total": 50,
    "reussies": 45,
    "echecs": 5,
    "taux_reussite": 90.0,
    "detail_echecs": [
        {"msisdn": "...", "type_dossier": "Inscription", "etape": "...",
         "type_erreur": "metier"|"technique", "motif": "..."},
        ...
    ],
    "csv_path": "C:\\...\\rapport_execution_20260807.csv",
    "zip_path": "C:\\...\\captures_erreurs_20260807.zip"  ou null si aucune capture,
    "html_body": "<div>...</div>"
}
En cas d'erreur fatale (ex: journal.jsonl introuvable), affiche
{"erreur": "..."} sur stdout et sort avec le code 1.
"""
import csv
import glob
import json
import os
import re
import sys
import zipfile
from datetime import datetime, date

# Sur Windows, la console utilise souvent l'encodage cp1252 par défaut, qui ne sait pas
# encoder les emojis (📊, 🔴...) présents dans le corps HTML généré ci-dessous. On force donc
# stdout/stderr en UTF-8, indépendamment de l'encodage de la console appelante.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS_DIR = os.path.join(RACINE, "results")
JOURNAL_JSONL = os.path.join(RESULTS_DIR, "journal.jsonl")
ERROR_DIR = os.path.join(RESULTS_DIR, "error")


def lire_entrees_du_jour(date_cible):
    """Lit journal.jsonl et ne garde que les enregistrements dont l'horodatage
    correspond à date_cible (objet date)."""
    entrees = []
    if not os.path.exists(JOURNAL_JSONL):
        return entrees
    with open(JOURNAL_JSONL, "r", encoding="utf-8") as f:
        for ligne in f:
            ligne = ligne.strip()
            if not ligne:
                continue
            try:
                enregistrement = json.loads(ligne)
            except json.JSONDecodeError:
                continue
            horodatage = enregistrement.get("horodatage")
            if not horodatage:
                continue
            try:
                dt = datetime.fromisoformat(horodatage)
            except ValueError:
                continue
            if dt.date() == date_cible:
                entrees.append((dt, enregistrement))
    entrees.sort(key=lambda t: t[0])
    return entrees


def classifier_echec(enregistrement):
    """Détermine l'étape de blocage, le type d'erreur (métier/technique) et le
    motif, pour un dossier en échec (inscription ou modification)."""
    type_dossier = enregistrement.get("type", "Inscription")

    if type_dossier == "Modification":
        raison = enregistrement.get("raison", "Cause inconnue")
        return "Report des champs (Modification)", "metier", raison

    rapport_cni = enregistrement.get("rapport_cni", {}) or {}

    # Erreur technique : l'appel à l'API OCR a lui-même échoué (clé "ocr" du rapport).
    if "ocr" in rapport_cni:
        return "Appel API OCR CNI", "technique", str(rapport_cni.get("ocr"))

    # Sinon, erreur métier : incohérence(s) entre l'écran et l'OCR CNI.
    champs_en_defaut = [
        champ for champ, valeur in rapport_cni.items()
        if valeur is False or valeur == "ABSENT"
    ]
    if champs_en_defaut:
        motif = "Champ(s) divergent(s) ou absent(s) : " + ", ".join(champs_en_defaut)
    else:
        motif = "Incohérence détectée (détail non disponible)"
    return "Vérification Pièces (OCR CNI)", "metier", motif


def construire_resume(entrees):
    total = len(entrees)
    reussies = sum(
        1 for _, e in entrees
        if e.get("validation_finale") is True or e.get("valide") is True
    )
    echecs_liste = []
    for dt, e in entrees:
        est_reussi = e.get("validation_finale") is True or e.get("valide") is True
        if est_reussi:
            continue
        etape, type_erreur, motif = classifier_echec(e)
        echecs_liste.append({
            "msisdn": e.get("msisdn", "?"),
            "type_dossier": e.get("type", "Inscription"),
            "etape": etape,
            "type_erreur": type_erreur,
            "motif": motif,
        })

    heure_debut = entrees[0][0].strftime("%H:%M:%S") if entrees else "-"
    heure_fin = entrees[-1][0].strftime("%H:%M:%S") if entrees else "-"
    duree_minutes = 0
    if entrees:
        duree_minutes = round((entrees[-1][0] - entrees[0][0]).total_seconds() / 60)

    taux_reussite = round((reussies / total) * 100, 1) if total else 0.0

    return {
        "total": total,
        "reussies": reussies,
        "echecs": len(echecs_liste),
        "taux_reussite": taux_reussite,
        "heure_debut": heure_debut,
        "heure_fin": heure_fin,
        "duree_minutes": duree_minutes,
        "detail_echecs": echecs_liste,
    }


def generer_csv(entrees, date_cible, resume):
    Create = os.makedirs
    Create(RESULTS_DIR, exist_ok=True)
    nom_fichier = "rapport_execution_{}.csv".format(date_cible.strftime("%Y%m%d"))
    chemin = os.path.join(RESULTS_DIR, nom_fichier)
    with open(chemin, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f, delimiter=";")
        writer.writerow(["Horodatage", "MSISDN", "Type dossier", "Statut", "Étape / Motif"])
        for dt, e in entrees:
            est_reussi = e.get("validation_finale") is True or e.get("valide") is True
            if est_reussi:
                statut = "Validé"
                motif = ""
            else:
                etape, type_erreur, motif_txt = classifier_echec(e)
                statut = "Échec ({})".format("métier" if type_erreur == "metier" else "technique")
                motif = "{} — {}".format(etape, motif_txt)
            writer.writerow([
                dt.strftime("%Y-%m-%d %H:%M:%S"),
                e.get("msisdn", "?"),
                e.get("type", "Inscription"),
                statut,
                motif,
            ])
    return chemin


def generer_zip_captures(date_cible):
    """Zippe les captures d'écran d'erreur (results/error/*.png) datées ${date_cible}.
    La date est d'abord lue dans le nom du fichier (format "{msisdn}_{AAAAMMJJ}.png",
    fiable même si le fichier est copié/déplacé) ; si le nom ne suit pas ce format
    (anciennes captures générées avant ce changement, nommées juste "{msisdn}.png"),
    on se rabat sur la date de dernière modification du fichier.
    Retourne le chemin du zip, ou None si aucune capture pertinente."""
    if not os.path.isdir(ERROR_DIR):
        return None
    pattern_date = re.compile(r"_(\d{8})\.png$")
    fichiers_du_jour = []
    for chemin_png in glob.glob(os.path.join(ERROR_DIR, "*.png")):
        nom_fichier = os.path.basename(chemin_png)
        m = pattern_date.search(nom_fichier)
        if m:
            try:
                date_fichier = datetime.strptime(m.group(1), "%Y%m%d").date()
            except ValueError:
                date_fichier = datetime.fromtimestamp(os.path.getmtime(chemin_png)).date()
        else:
            date_fichier = datetime.fromtimestamp(os.path.getmtime(chemin_png)).date()
        if date_fichier == date_cible:
            fichiers_du_jour.append(chemin_png)
    if not fichiers_du_jour:
        return None

    nom_fichier = "captures_erreurs_{}.zip".format(date_cible.strftime("%Y%m%d"))
    chemin_zip = os.path.join(RESULTS_DIR, nom_fichier)
    with zipfile.ZipFile(chemin_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        for chemin_png in fichiers_du_jour:
            zf.write(chemin_png, arcname=os.path.basename(chemin_png))
    return chemin_zip


def construire_html(date_cible, resume, csv_path, zip_path):
    style_carte = (
        "font-family:Arial,Helvetica,sans-serif;max-width:700px;margin:0 auto;"
        "color:#1f2937;"
    )
    style_table = (
        "width:100%;border-collapse:collapse;margin:12px 0 24px 0;"
    )
    style_th = (
        "text-align:left;padding:10px 8px;border-bottom:2px solid #e5e7eb;"
        "font-size:13px;color:#6b7280;"
    )
    style_td = (
        "text-align:left;padding:10px 8px;border-bottom:1px solid #f0f0f0;"
        "font-size:14px;"
    )
    style_titre = "font-size:18px;margin:24px 0 4px 0;"
    style_note = "font-size:13px;color:#6b7280;margin:0 0 12px 0;"

    puce_verte = "<span style='color:#22c55e;font-size:16px;'>&#9679;</span>"
    puce_rouge = "<span style='color:#ef4444;font-size:16px;'>&#9679;</span>"

    lignes_resume = "".join([
        "<tr><td style='{td}'><b>Heure de début / fin</b></td>"
        "<td style='{td}'>{hd} - {hf} (Durée : {dm} min)</td></tr>".format(
            td=style_td, hd=resume["heure_debut"], hf=resume["heure_fin"], dm=resume["duree_minutes"]
        ),
        "<tr><td style='{td}'><b>Total de demandes traitées</b></td>"
        "<td style='{td}'>{t}</td></tr>".format(td=style_td, t=resume["total"]),
        "<tr><td style='{td}'><b>Inscriptions / demandes réussies</b></td>"
        "<td style='{td}'>{puce} {r} ({pct}%)</td></tr>".format(
            td=style_td, puce=puce_verte, r=resume["reussies"], pct=resume["taux_reussite"]
        ),
        "<tr><td style='{td}'><b>Demandes en échec / rejetées</b></td>"
        "<td style='{td}'>{puce} {e} ({pctf}%)</td></tr>".format(
            td=style_td, puce=puce_rouge, e=resume["echecs"],
            pctf=round(100 - resume["taux_reussite"], 1) if resume["total"] else 0
        ),
    ])

    if resume["detail_echecs"]:
        lignes_echecs = ""
        for d in resume["detail_echecs"]:
            libelle_type = "Erreur métier" if d["type_erreur"] == "metier" else "Erreur technique"
            lignes_echecs += (
                "<tr>"
                "<td style='{td}'><code>{msisdn}</code></td>"
                "<td style='{td}'>{type_dossier}</td>"
                "<td style='{td}'>{etape}</td>"
                "<td style='{td}'><i>{libelle} :</i> {motif}</td>"
                "</tr>"
            ).format(
                td=style_td, msisdn=d["msisdn"], type_dossier=d["type_dossier"],
                etape=d["etape"], libelle=libelle_type, motif=d["motif"],
            )
        bloc_echecs = (
            "<div style='{titre}'>{puce} Détail des Échecs / Rejets ({n})</div>"
            "<p style='{note}'>Ces demandes nécessitent une intervention manuelle ou une correction de données.</p>"
            "<table style='{table}'>"
            "<tr><th style='{th}'>MSISDN</th><th style='{th}'>Type</th>"
            "<th style='{th}'>Étape du blocage</th><th style='{th}'>Motif / Type d'erreur</th></tr>"
            "{lignes}"
            "</table>"
        ).format(
            titre=style_titre, puce=puce_rouge, n=resume["echecs"], note=style_note,
            table=style_table, th=style_th, lignes=lignes_echecs,
        )
    else:
        bloc_echecs = (
            "<div style='{titre}'>{puce} Détail des Échecs / Rejets (0)</div>"
            "<p style='{note}'>Aucun échec à signaler aujourd'hui. 🎉</p>"
        ).format(titre=style_titre, puce=puce_verte, note=style_note)

    bloc_distinction = (
        "<div style='{titre}'>ℹ️ Distinction des types d'erreurs</div>"
        "<p style='{note}'><b>Erreurs Métier</b> (Business Exceptions) : données manquantes, "
        "champ divergent, pièce jointe invalide. <i>Exige une action côté métier.</i><br>"
        "<b>Erreurs Techniques</b> (System Exceptions) : API OCR indisponible, timeout réseau, "
        "session expirée. <i>Exige une vérification technique / support.</i></p>"
    ).format(titre=style_titre, note=style_note)

    pieces_jointes = ["<code>{}</code> — Journal complet d'exécution au format CSV/Excel".format(
        os.path.basename(csv_path)
    )]
    if zip_path:
        pieces_jointes.append(
            "<code>{}</code> — Captures d'écran des dossiers en erreur".format(os.path.basename(zip_path))
        )
    bloc_pieces_jointes = (
        "<div style='{titre}'>📎 Pièces jointes</div>"
        "<ul style='{note}'>{items}</ul>"
    ).format(
        titre=style_titre, note=style_note,
        items="".join("<li>{}</li>".format(p) for p in pieces_jointes),
    )

    html = (
        "<div style='{carte}'>"
        "<div style='font-size:20px;font-weight:bold;margin-bottom:8px;'>"
        "📊 Synthèse d'exécution — KAABU RPA — {date}</div>"
        "<table style='{table}'>"
        "<tr><th style='{th}'>Métrique</th><th style='{th}'>Valeur</th></tr>"
        "{lignes_resume}"
        "</table>"
        "{bloc_echecs}"
        "{bloc_distinction}"
        "{bloc_pieces_jointes}"
        "<p style='font-size:12px;color:#9ca3af;margin-top:24px;'>"
        "Ce message est généré automatiquement par le robot d'automatisation RPA KAABU.</p>"
        "</div>"
    ).format(
        carte=style_carte, date=date_cible.strftime("%d/%m/%Y"), table=style_table,
        th=style_th, lignes_resume=lignes_resume, bloc_echecs=bloc_echecs,
        bloc_distinction=bloc_distinction, bloc_pieces_jointes=bloc_pieces_jointes,
    )
    return html


def main():
    date_str = sys.argv[1] if len(sys.argv) > 1 else None
    try:
        date_cible = datetime.strptime(date_str, "%Y-%m-%d").date() if date_str else date.today()
    except ValueError:
        print(json.dumps({"erreur": "Format de date invalide, attendu AAAA-MM-JJ : {}".format(date_str)}))
        sys.exit(1)

    entrees = lire_entrees_du_jour(date_cible)
    resume = construire_resume(entrees)
    csv_path = generer_csv(entrees, date_cible, resume)
    zip_path = generer_zip_captures(date_cible)
    html_body = construire_html(date_cible, resume, csv_path, zip_path)

    resultat = {
        "date": date_cible.strftime("%Y-%m-%d"),
        "csv_path": csv_path,
        "zip_path": zip_path,
        "html_body": html_body,
    }
    resultat.update(resume)
    print(json.dumps(resultat, ensure_ascii=False))


if __name__ == "__main__":
    main()