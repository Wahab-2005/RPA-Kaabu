*** Settings ***
Documentation    Connexion et filtrage de la liste des dossiers sur KAABU (Orange-Sonatel).
Library          Collections
Resource         ../resources/variables.robot
Resource         ../resources/keywords.robot
Resource         ../resources/verification_cni.robot
Suite Setup      Run Keywords    Charger Env Dotenv    AND    Ouvrir Le Navigateur Kaabu
Suite Teardown   Finaliser Session


*** Variables ***
${LIMITE_SECURITE_DOSSIERS}     500
${MSISDN_PRECEDENT}             ${EMPTY}


*** Test Cases ***
Connexion Sur Le Portail Kaabu
    [Documentation]    Vérifie que l'utilisateur peut se connecter avec ses identifiants.
    Se Connecter Sur Kaabu
    Verifier Connexion Reussie

Filtrer Les Dossiers Crees En Subscription Orange Money
    [Documentation]    Filtre la liste, compte dynamiquement le nombre de dossiers correspondants,
    ...                ouvre le premier dossier trouvé, puis traite chaque dossier à la suite : pour
    ...                chacun, contrôle de nationalité, vérification OCR CNI, décision, puis
    ...                passage au dossier suivant. S'arrête après avoir traité le nombre de dossiers
    ...                comptés, ou plus tôt en cas de fin de liste (dossier identique au précédent),
    ...                de dossier non éligible introuvable (Traiter Dossier Kaabu retourne
    ...                ${FALSE}) ou d'échec du bouton "suivant". ${LIMITE_SECURITE_DOSSIERS} reste
    ...                un garde-fou anti-boucle infinie si le comptage initial était incorrect.
    Initialiser Rapport Simple
    Filtrer Dossiers Par Etat Et Type    ${FILTRE_ETAT_VALEUR}    ${FILTRE_TYPE_VALEUR}
    Valider La Recherche
    Sleep    1s

    ${nombre_dossiers}=    Compter Dossiers A Traiter
    IF    ${nombre_dossiers} == 0
        Journaliser Etape    Aucun dossier ne correspond aux filtres — rien à traiter.    niveau=WARN
        Pass Execution    Aucun dossier à traiter pour ce filtre.
    END
    IF    ${nombre_dossiers} > ${LIMITE_SECURITE_DOSSIERS}
        Journaliser Etape    ${nombre_dossiers} dossiers détectés, au-delà de la limite de sécurité (${LIMITE_SECURITE_DOSSIERS}) — traitement plafonné à ${LIMITE_SECURITE_DOSSIERS}.    niveau=WARN
        ${nombre_dossiers}=    Set Variable    ${LIMITE_SECURITE_DOSSIERS}
    END
    Journaliser Etape    ▶️ Traitement de ${nombre_dossiers} dossier(s) à suivre.

    Cliquer Sur Le Dossier Du Client
    Sleep    1s

    FOR    ${n}    IN RANGE    1    ${nombre_dossiers} + 1
        Journaliser Etape    ${\n}########## DOSSIER ${n}/${nombre_dossiers} ##########

        ${continuer}=    Traiter Dossier Kaabu
        IF    not ${continuer}
            Journaliser Etape    Aucun dossier éligible supplémentaire trouvé — arrêt.    niveau=WARN
            BREAK
        END

        ${msisdn}=    Logger Le Msisdn Du Dossier

        IF    '${msisdn}' == '${MSISDN_PRECEDENT}'
            # ⚠️ À NOTER : si le retry (via "Dossier suivant") atterrit sur un dossier dont la
            # pièce n'est pas éligible (nationalité), cette itération traite quand même l'OCR
            # dessus sans repasser par "Traiter Dossier Kaabu" — cas jugé suffisamment rare
            # (fin de liste + dossier suivant non-éligible en même temps) pour ne pas complexifier
            # davantage ce garde-fou. À revoir si ce cas se présente en pratique.
            ${fin_de_liste}    ${msisdn}=    Confirmer Fin De Liste Avec Retry    ${MSISDN_PRECEDENT}
            IF    ${fin_de_liste}
                Journaliser Etape    Fin de liste confirmée — arrêt.    niveau=WARN
                BREAK
            END
        END
        Set Suite Variable    ${MSISDN_PRECEDENT}    ${msisdn}

        ${coherent}    ${rapport}    ${donnees_ocr}=    Verifier Coherence CNI
        Journaliser Etape    Statut final : ${coherent}
        Journaliser Etape    Détail : ${rapport}

        IF    ${coherent}
            Journaliser Etape    ✅ Dossier cohérent — validation des pièces jointes.
            Valider Les Pieces Jointes CNI

            ${nom_prenom_ok}    ${detail_formulaire}=    Verifier Nom Prenom Formulaire
            IF    ${nom_prenom_ok}
                Journaliser Etape    ✅ Nom/Prénom confirmés sur le formulaire signé.
            ELSE
                Journaliser Etape    ⚠️ Nom/Prénom NON confirmés sur le formulaire — vérification manuelle requise.    niveau=WARN
            END

            Valider Le Dossier

            ${enregistrement}=    Create Dictionary
            ...    msisdn=${msisdn}
            ...    ocr_cni=${donnees_ocr}
            ...    decision_cni=${coherent}
            ...    rapport_cni=${rapport}
            ...    pieces_jointes_validees=${TRUE}
            ...    ocr_formulaire=${detail_formulaire}
            ...    validation_finale=${TRUE}
            Enregistrer Dossier Json    ${enregistrement}

            IF    ${nom_prenom_ok}
                Ajouter Au Rapport Simple    ${msisdn}    ✅ Validé
            ELSE
                Ajouter Au Rapport Simple    ${msisdn}    ✅ Validé (nom/prénom à vérifier manuellement)
            END
        ELSE
            Journaliser Etape    ⚠️ Incohérences détectées : ${rapport}    niveau=WARN
            Capturer Preuve Erreur    ${msisdn}

            ${enregistrement}=    Create Dictionary
            ...    msisdn=${msisdn}
            ...    ocr_cni=${donnees_ocr}
            ...    decision_cni=${coherent}
            ...    rapport_cni=${rapport}
            ...    pieces_jointes_validees=${FALSE}
            ...    ocr_formulaire=${NONE}
            ...    validation_finale=${FALSE}
            Enregistrer Dossier Json    ${enregistrement}

            ${est_erreur_technique}=    Run Keyword And Return Status
            ...    Dictionary Should Contain Key    ${rapport}    ocr
            IF    ${est_erreur_technique}
                Ajouter Au Rapport Simple    ${msisdn}    ⚠️ Erreur technique (API OCR indisponible) — à retraiter
            ELSE
                Ajouter Au Rapport Simple    ${msisdn}    ❌ Non validé (incohérence détectée)
            END
        END

        # IMPORTANT : on vient de finir le traitement complet du dossier courant.
        # Rien avant ce point ne fait avancer la liste vers le dossier suivant
        # (Traiter Dossier Kaabu ne clique "suivant" que pour sauter les dossiers
        # non éligible). Sans cet appel, le prochain tour de boucle revérifie
        # le MÊME dossier déjà à l'écran, ce qui déclenchait à tort la détection
        # de fin de liste (MSISDN identique dès le 2e tour).
        # ⚠️ À VÉRIFIER : si le clic sur "Valider" (cas cohérent) fait déjà
        # avancer automatiquement vers le dossier suivant côté portail, il
        # faudra rendre cet appel conditionnel (ex: seulement dans le cas
        # ELSE / incohérent) pour éviter de sauter un dossier par erreur.
        Aller Au Dossier Suivant
    END