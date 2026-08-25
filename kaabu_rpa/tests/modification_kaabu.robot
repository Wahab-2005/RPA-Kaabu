*** Settings ***
Documentation    Cas d'usage "Modification" : connexion, filtrage sur Type = "Modification info
...              compte Orange Money" (sans filtre d'état), boucle sur jusqu'à
...              ${NOMBRE_DOSSIERS_A_TRAITER} dossiers : pour chacun, recherche d'un dossier avec
...              pièce éligible, extraction OCR de la CNI, report des champs (nom, prénom, n°
...              pièce, type de pièce, dates, etc.) dans la colonne "Modification client", puis
...              validation du dossier (double clic Valider). S'arrête proprement en cas de fin
...              de liste (dossier identique au précédent) ou si plus aucun dossier éligible.
Resource         ../resources/variables.robot
Resource         ../resources/keywords.robot
Resource         ../resources/verification_cni.robot
Resource         ../resources/report_modification_client.robot
Suite Setup      Run Keywords    Charger Env Dotenv    AND    Ouvrir Le Navigateur Kaabu    AND    Initialiser Rapport Simple
Suite Teardown   Run Keywords    Sleep    30s    AND    Finaliser Session


*** Variables ***
${NOMBRE_DOSSIERS_A_TRAITER}    10
${MSISDN_PRECEDENT}             ${EMPTY}


*** Test Cases ***
Traiter Les Dossiers De Modification
    [Documentation]    Se connecte, filtre sur Type = "Modification info compte Orange Money",
    ...                puis traite jusqu'à ${NOMBRE_DOSSIERS_A_TRAITER} dossiers à la suite :
    ...                pour chacun, recherche d'un dossier avec pièce éligible, extraction OCR
    ...                de la CNI, report des champs, puis validation (uniquement si l'OCR a
    ...                réussi) avec confirmation du second bouton Valider.
    Se Connecter Sur Kaabu
    Verifier Connexion Reussie

    Filtrer Dossiers Par Etat Et Type    ${FILTRE_ETAT_VALEUR}    ${FILTRE_TYPE_MODIFICATION_VALEUR}
    Valider La Recherche
    Sleep    1s
    Cliquer Sur Le Dossier Du Client
    Sleep    1s

    FOR    ${n}    IN RANGE    1    ${NOMBRE_DOSSIERS_A_TRAITER} + 1
        Journaliser Etape    ${\n}########## DOSSIER ${n}/${NOMBRE_DOSSIERS_A_TRAITER} ##########

        ${trouve}    ${msisdn}=    Traiter Dossier Modification
        IF    not ${trouve}
            Journaliser Etape    Aucun dossier éligible supplémentaire trouvé — arrêt.    niveau=WARN
            BREAK
        END

        IF    '${msisdn}' == '${MSISDN_PRECEDENT}'
            # ⚠️ Même remarque que côté Inscription : le dossier atteint via ce retry n'est pas
            # re-vérifié pour l'éligibilité nationalité (repassera par "Traiter Dossier
            # Modification" seulement au tour de boucle suivant).
            ${fin_de_liste}    ${msisdn}=    Confirmer Fin De Liste Avec Retry    ${MSISDN_PRECEDENT}
            IF    ${fin_de_liste}
                Journaliser Etape    Fin de liste confirmée — arrêt.    niveau=WARN
                BREAK
            END
        END
        Set Suite Variable    ${MSISDN_PRECEDENT}    ${msisdn}

        TRY
            ${chemin_recto}=    Telecharger Image CNI En Pleine Resolution    ${CNI_RECTO_IMG}    cni_recto.jpg
            ${chemin_verso}=    Telecharger Image CNI En Pleine Resolution    ${CNI_VERSO_IMG}    cni_verso.jpg
            ${donnees_ocr}=      Appeler API OCR CNI    ${chemin_recto}    ${chemin_verso}

            ${ocr_valide}=    Evaluate    bool($donnees_ocr) and 'erreur' not in $donnees_ocr and bool($donnees_ocr.get('lastname'))

            IF    $ocr_valide
                Journaliser Etape    Données OCR reçues pour MSISDN ${msisdn} : ${donnees_ocr}

                ${changement_majeur}=    Verifier Changement Majeur    ${donnees_ocr}
                IF    ${changement_majeur}
                    Capturer Preuve Erreur    ${msisdn}
                    Ajouter Au Rapport Simple    ${msisdn}    ⏭️ Ignoré (changement majeur) — à traiter manuellement
                    Enregistrer Dossier Json    ${{ {'msisdn': '${msisdn}', 'type': 'Modification', 'ocr': $donnees_ocr, 'champs_reportes': False, 'valide': False, 'raison': 'Changement majeur — hors périmètre RPA'} }}
                ELSE
                    Reporter Donnees OCR Dans Modification Client    ${donnees_ocr}

                    Valider Le Dossier
                    Confirmer Validation Dossier

                    Enregistrer Dossier Json    ${{ {'msisdn': '${msisdn}', 'type': 'Modification', 'ocr': $donnees_ocr, 'champs_reportes': True, 'valide': True} }}
                    Ajouter Au Rapport Simple    ${msisdn}    ✅ Validé
                END
            ELSE
                Journaliser Etape    OCR invalide ou vide pour MSISDN ${msisdn} — aucun champ reporté, dossier non validé, à traiter manuellement.    niveau=WARN
                Capturer Preuve Erreur    ${msisdn}
                Enregistrer Dossier Json    ${{ {'msisdn': '${msisdn}', 'type': 'Modification', 'ocr': $donnees_ocr, 'champs_reportes': False, 'valide': False, 'raison': 'OCR invalide ou en erreur'} }}
                Ajouter Au Rapport Simple    ${msisdn}    ⚠️ Erreur technique (OCR invalide) — à retraiter
            END
        EXCEPT    AS    ${erreur}
            # Filet de sécurité : un plantage inattendu (élément introuvable, timeout, etc.) sur
            # CE dossier ne doit pas interrompre le traitement des dossiers suivants.
            Journaliser Etape    ❌ Erreur inattendue lors du traitement du dossier MSISDN ${msisdn} : ${erreur} — dossier ignoré, passage au suivant.    niveau=ERROR
            Run Keyword And Ignore Error    Capturer Preuve Erreur    ${msisdn}
            Ajouter Au Rapport Simple    ${msisdn}    ❌ Erreur inattendue (${erreur}) — à retraiter manuellement
            Run Keyword And Ignore Error
            ...    Enregistrer Dossier Json    ${{ {'msisdn': '${msisdn}', 'type': 'Modification', 'champs_reportes': False, 'valide': False, 'raison': str($erreur)} }}
        END

        # IMPORTANT : cf. même remarque que côté Inscription — sans cet appel, le prochain tour
        # de boucle revérifie le MÊME dossier déjà à l'écran, ce qui déclenche à tort la
        # détection de fin de liste (MSISDN identique dès le 2e tour).
        # ⚠️ À VÉRIFIER : si le second clic "Valider" (Confirmer Validation Dossier) fait déjà
        # avancer automatiquement vers le dossier suivant côté portail, il faudra rendre cet
        # appel conditionnel (ex: seulement dans le cas OCR invalide) pour éviter de sauter un
        # dossier par erreur.
        Aller Au Dossier Suivant
    END
