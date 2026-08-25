*** Settings ***
Documentation     Report des données OCR (nom, prénom, n° de pièce, type de pièce)
...               dans la colonne "Modification client" du dossier Kaabu.
...               Règle métier confirmée : chaque champ est désactivé (disabled) tant que
...               sa case à cocher n'a pas été cochée -> on coche toujours avant de saisir.
Library           SeleniumLibrary
Library           String
Library           Collections
Resource          variables.robot
Resource          keywords.robot
Resource          verification_cni.robot


*** Keywords ***
Cocher La Ligne Du Champ
    [Documentation]    Coche la case à cocher associée au champ donné (même div.k-row),
    ...                sans rien faire si elle est déjà cochée.
    [Arguments]    ${champ_locator}
    ${champ_xpath}=    Remove String    ${champ_locator}    xpath=
    ${case_locator}=    Replace String    ${CASE_A_COCHER_DE_LA_LIGNE_TEMPLATE}    {champ}    ${champ_xpath}
    Wait Until Element Is Visible    ${case_locator}    timeout=${TIMEOUT}
    ${deja_cochee}=    Get Element Attribute    ${case_locator}    checked
    IF    '${deja_cochee}' == '${None}'
        Cliquer Element Avec Retry    ${case_locator}
    END
    RETURN    ${case_locator}

Remplir Champ Texte Modification Client
    [Documentation]    Coche la ligne puis saisit une valeur dans un champ texte simple
    ...                (nom, prénom, numéro de pièce...). Attend que le champ soit activé
    ...                (non-disabled) avant de saisir, puisqu'il dépend de la case à cocher.
    [Arguments]    ${champ_locator}    ${valeur}
    Cocher La Ligne Du Champ    ${champ_locator}
    Wait Until Keyword Succeeds    5x    0.5s
    ...    Champ Doit Etre Active    ${champ_locator}
    Clear Element Text    ${champ_locator}
    Input Text    ${champ_locator}    ${valeur}
    Log    Champ ${champ_locator} rempli avec "${valeur}"    console=True

Champ Doit Etre Active
    [Documentation]    Échoue tant que l'attribut "disabled" est encore présent sur le champ
    ...                (le formulaire l'active en JS après le clic sur la case à cocher).
    [Arguments]    ${champ_locator}
    ${disabled}=    Get Element Attribute    ${champ_locator}    disabled
    Should Be Equal    ${disabled}    ${None}    msg=Le champ est encore désactivé (case non prise en compte ?)

Determiner Valeur Type Piece
    [Documentation]    Déduit le libellé à sélectionner dans le dropdown "Type de pièce" à
    ...                partir de "document_type"/"country" renvoyés par l'OCR :
    ...                - PASSPORT                      -> "Passeport"
    ...                - ID_CARD ET pays == Sénégal     -> "CNI SN"
    ...                - ID_CARD ET pays != Sénégal     -> "CNI CEDEAO" (y compris pays
    ...                  vide/indéterminé, par défaut le plus sûr pour une CNI non-SN)
    ...                Repli sur "CNI SN" (${VALEUR_TYPE_PIECE_FIXE}) si document_type est
    ...                absent/OTHER, pour ne jamais bloquer le report des autres champs.
    [Arguments]    ${donnees_ocr}
    ${document_type}=    Get From Dictionary    ${donnees_ocr}    document_type    default=${EMPTY}
    ${country}=           Get From Dictionary    ${donnees_ocr}    country          default=${EMPTY}
    ${document_type}=    Convert To Upper Case    ${document_type}
    ${country}=           Convert To Upper Case    ${country}

    IF    '${document_type}' == 'PASSPORT'
        RETURN    ${VALEUR_TYPE_PIECE_PASSEPORT}
    ELSE IF    '${document_type}' == 'ID_CARD' and '${country}' != 'SEN'
        RETURN    ${VALEUR_TYPE_PIECE_CEDEAO}
    ELSE IF    '${document_type}' == 'ID_CARD' and '${country}' == 'SEN'
        RETURN    ${VALEUR_TYPE_PIECE_FIXE}
    END
    RETURN    ${VALEUR_TYPE_PIECE_FIXE}

Selectionner Type De Piece
    [Documentation]    Coche la ligne "Type de pièce" puis sélectionne la valeur donnée
    ...                (déterminée par l'appelant via "Determiner Valeur Type Piece" à partir
    ...                de l'OCR — "CNI SN" par défaut si aucune valeur n'est fournie).
    [Arguments]    ${valeur}=${VALEUR_TYPE_PIECE_FIXE}
    Cocher La Ligne Du Champ    ${CHAMP_TYPE_PIECE}
    ${champ_xpath}=    Remove String    ${CHAMP_TYPE_PIECE}    xpath=
    ${conteneur}=    Set Variable    xpath=(${champ_xpath})//div[contains(@class,'ng-select-container')]
    Cliquer Element Avec Retry    ${conteneur}
    Choisir Option Ng Select    ${valeur}
    Log    Type de pièce fixé à "${valeur}"    console=True

Lire Motif Demande
    [Documentation]    Lit le texte du motif de la demande de modification affiché sur le
    ...                dossier (ex: "Le client a déjà un compte avec ce numero: ..."). Sert à
    ...                déterminer quels champs sont explicitement visés par la demande.
    ...                Retourne une chaîne vide si le motif est introuvable (fallback géré par
    ...                l'appelant : tous les champs seront alors proposés par sécurité).
    ${motif_present}=    Run Keyword And Return Status
    ...    Page Should Contain Element    ${CHAMP_MOTIF_DEMANDE}
    IF    not ${motif_present}
        Journaliser Etape
        ...    Champ "Motif" introuvable sur ce dossier — impossible de cibler des champs précis.
        ...    niveau=WARN
        RETURN    ${EMPTY}
    END
    ${motif}=    Get Text    ${CHAMP_MOTIF_DEMANDE}
    ${motif}=    Strip String    ${motif}
    Journaliser Etape    Motif de la demande lu : "${motif}"
    RETURN    ${motif}

Determiner Champs A Modifier
    [Documentation]    Analyse le texte du motif (mots-clés, insensible à la casse) pour détecter
    ...                quels champs métier sont explicitement concernés. Retourne une liste de
    ...                clés parmi : nom, prenom, numero_piece, date_naissance, date_delivrance,
    ...                date_expiration, sexe, adresse, commune.
    ...                ("numero_piece" et "type_piece" sont toujours reportés ensemble — cf.
    ...                Reporter Donnees OCR Dans Modification Client — donc "type_piece" n'est
    ...                pas une clé de détection séparée ici.)
    ...                Liste vide si le motif ne permet d'identifier aucun champ connu — dans ce
    ...                cas l'appelant doit se rabattre sur TOUS les champs par sécurité.
    [Arguments]    ${motif}
    ${motif_min}=    Convert To Lower Case    ${motif}
    ${mots_cles}=    Create Dictionary
    ...    numero_piece=numero,numéro,piece,pièce,cni,type de piece,type de pièce
    ...    nom=nom du client
    ...    prenom=prénom,prenom
    ...    date_naissance=naissance
    ...    date_delivrance=délivrance,delivrance
    ...    date_expiration=expiration
    ...    sexe=sexe
    ...    adresse=adresse
    ...    commune=commune
    ${champs}=    Evaluate    [k for _mm in [$motif_min] for k, mots in $mots_cles.items() if any(re.search(r'\\b' + re.escape(m), _mm) for m in mots.split(','))]    re
    Journaliser Etape    Champs détectés dans le motif : ${champs}
    RETURN    ${champs}

Determiner Extension Doublon
    [Documentation]    Détecte dans le motif un cas de doublon ("le client a déjà un compte /
    ...                déjà 2 comptes avec ce numéro") et calcule l'extension à ajouter au
    ...                numéro de pièce : extension = (nombre de comptes déjà existants) + 1.
    ...                Ex: "déjà un compte" (1 compte) -> extension 2. "déjà 2 comptes" -> 3.
    ...                Retourne l'entier sous forme de chaîne, ou ${EMPTY} si ce n'est pas un
    ...                cas de doublon (auquel cas le numéro OCR est reporté tel quel, sans
    ...                extension).
    [Arguments]    ${motif}
    ${motif_min}=    Convert To Lower Case    ${motif}
    ${est_doublon}=    Evaluate    bool(re.search(r'd[ée]j[àa]\\s+(un|\\d+)\\s+comptes?', $motif_min)) or 'doublon' in $motif_min    re
    IF    not ${est_doublon}
        RETURN    ${EMPTY}
    END
    ${extension}=    Evaluate    (int(m.group(1)) if (m := re.search(r'(\\d+)\\s*comptes?', $motif_min)) else 1) + 1    re
    Journaliser Etape    Cas de doublon détecté dans le motif — extension calculée : "_${extension}"
    RETURN    ${extension}

Verifier Changement Majeur
    [Documentation]    Détecte un cas de "modification majeure" : si nom ET prénom ET date de
    ...                naissance ET numéro de CNI sont TOUS différents entre la CNI (OCR) et les
    ...                données déjà enregistrées côté Tango (panneau "Client sur Tango"), il
    ...                s'agit d'une modification majeure — le dossier doit être ignoré (passage
    ...                au dossier suivant), pas traité comme une modification mineure normale.
    ...                Les champs Tango sont des <input>, donc lus avec "Get Value" (attribut
    ...                "value") et non "Get Text" (qui lit le contenu texte visible et renvoie
    ...                toujours vide sur un <input> — piège classique Selenium).
    [Arguments]    ${donnees_ocr}
    ${nom_ocr}=       Get From Dictionary    ${donnees_ocr}    lastname     default=${EMPTY}
    ${prenom_ocr}=    Get From Dictionary    ${donnees_ocr}    firstname    default=${EMPTY}
    ${naissance_ocr}=  Get From Dictionary    ${donnees_ocr}    birth_date   default=${EMPTY}
    ${numero_ocr}=    Get From Dictionary    ${donnees_ocr}    nin          default=${EMPTY}

    ${nom_tango}=        Get Value    ${CHAMP_TANGO_NOM}
    ${prenom_tango}=     Get Value    ${CHAMP_TANGO_PRENOM}
    ${naissance_tango}=  Get Value    ${CHAMP_TANGO_DATE_NAISSANCE}
    ${numero_tango}=     Get Value    ${CHAMP_TANGO_NUMERO_PIECE}

    ${nom_ocr_n}=         Normaliser Texte    ${nom_ocr}
    ${nom_tango_n}=       Normaliser Texte    ${nom_tango}
    ${prenom_ocr_n}=      Normaliser Texte    ${prenom_ocr}
    ${prenom_tango_n}=    Normaliser Texte    ${prenom_tango}
    ${naissance_ocr_n}=   Normaliser Date     ${naissance_ocr}
    ${naissance_tango_n}=  Normaliser Date    ${naissance_tango}
    ${numero_ocr_n}=      Normaliser Texte    ${numero_ocr}
    ${numero_tango_n}=    Normaliser Texte    ${numero_tango}

    ${nom_ok}=          Evaluate    '${nom_ocr_n}' == '${nom_tango_n}'
    ${prenom_ok}=       Evaluate    '${prenom_ocr_n}' == '${prenom_tango_n}'
    ${naissance_ok}=    Evaluate    '${naissance_ocr_n}' == '${naissance_tango_n}'
    ${numero_ok}=       Evaluate    '${numero_ocr_n}' == '${numero_tango_n}'

    Journaliser Etape
    ...    Comparaison changement majeur — Nom : OCR="${nom_ocr}" / Tango="${nom_tango}" (${nom_ok}) | Prénom : OCR="${prenom_ocr}" / Tango="${prenom_tango}" (${prenom_ok}) | Naissance : OCR="${naissance_ocr}" / Tango="${naissance_tango}" (${naissance_ok}) | Numéro : OCR="${numero_ocr}" / Tango="${numero_tango}" (${numero_ok})

    ${tous_differents}=    Evaluate    not $nom_ok and not $prenom_ok and not $naissance_ok and not $numero_ok
    IF    ${tous_differents}
        Journaliser Etape    ⚠️ Changement majeur détecté : nom, prénom, date de naissance ET numéro de CNI sont TOUS différents entre la CNI et Tango — dossier ignoré.    niveau=WARN
    END
    RETURN    ${tous_differents}

Reporter Donnees OCR Dans Modification Client
    [Documentation]    Point d'entrée principal : lit le motif de la demande, en déduit les
    ...                champs concernés, et ne coche/remplit QUE ces champs (nom, prénom, n° de
    ...                pièce, type de pièce, date de naissance, dates délivrance/expiration,
    ...                sexe, adresse, commune). "Type de pièce" est TOUJOURS reporté en même
    ...                temps que "Numéro de pièce" (décision produit — comme dans le code de
    ...                base), même si le motif ne mentionne que le numéro. Sa valeur est
    ...                déterminée dynamiquement depuis document_type/country de l'OCR (CNI SN /
    ...                CNI CEDEAO / Passeport — cf. Determiner Valeur Type Piece), plutôt que
    ...                fixée à "CNI SN". Le "Numéro de pièce"
    ...                utilise le NIN de l'OCR (pas card_id). Cas particulier "doublon" (motif
    ...                du type "le client a déjà un/N compte(s) avec ce numéro") : le numéro est
    ...                alors préfixé "D_" et suffixé "_N+1" (ex: déjà 1 compte -> "D_<nin>_2").
    ...                Si le motif ne permet d'identifier aucun champ précis, TOUS les champs
    ...                disponibles via l'OCR sont reportés par sécurité (via la case "Tout
    ...                cocher" si trouvée, sinon coche champ par champ). Aucun clic sur
    ...                Valider/Rejeter n'est effectué ici.
    [Arguments]    ${donnees_ocr}
    ${motif}=     Lire Motif Demande
    ${champs}=    Determiner Champs A Modifier    ${motif}
    IF    not $champs
        Journaliser Etape    Aucun champ précis détecté — repli sur TOUS les champs disponibles.
        ${champs}=    Create List
        ...    nom    prenom    numero_piece    date_naissance
        ...    date_delivrance    date_expiration    sexe    adresse    commune
        ${tout_coche}=    Run Keyword And Return Status    Cocher Tout Cocher
        IF    ${tout_coche}
            Journaliser Etape    Case "Tout cocher" activée — toutes les lignes sont déjà déverrouillées.
        END
    END

    ${nom}=              Get From Dictionary    ${donnees_ocr}    lastname       default=${EMPTY}
    ${prenom}=           Get From Dictionary    ${donnees_ocr}    firstname      default=${EMPTY}
    ${numero_piece}=     Get From Dictionary    ${donnees_ocr}    nin            default=${EMPTY}
    ${date_naissance}=   Get From Dictionary    ${donnees_ocr}    birth_date     default=${EMPTY}
    ${date_delivrance}=  Get From Dictionary    ${donnees_ocr}    delivery_date       default=${EMPTY}
    ${date_expiration}=  Get From Dictionary    ${donnees_ocr}    expiration_date    default=${EMPTY}
    ${sexe_ocr}=         Get From Dictionary    ${donnees_ocr}    gender         default=${EMPTY}
    ${adresse}=          Get From Dictionary    ${donnees_ocr}    address        default=${EMPTY}
    ${commune}=          Get From Dictionary    ${donnees_ocr}    municipality   default=${EMPTY}

    IF    'nom' in $champs and '${nom}' != '${EMPTY}'
        Remplir Champ Texte Modification Client    ${CHAMP_NOM}    ${nom}
    END
    IF    'prenom' in $champs and '${prenom}' != '${EMPTY}'
        Remplir Champ Texte Modification Client    ${CHAMP_PRENOM}    ${prenom}
    END
    IF    'numero_piece' in $champs and '${numero_piece}' != '${EMPTY}'
        ${extension}=    Determiner Extension Doublon    ${motif}
        IF    '${extension}' != '${EMPTY}'
            ${numero_piece}=    Set Variable    D_${numero_piece}_${extension}
        END
        Remplir Champ Texte Modification Client    ${CHAMP_NUMERO_PIECE}    ${numero_piece}
        ${valeur_type_piece}=    Determiner Valeur Type Piece    ${donnees_ocr}
        Selectionner Type De Piece    ${valeur_type_piece}
    END
    IF    'date_naissance' in $champs and '${date_naissance}' != '${EMPTY}'
        Definir Date Dans Calendrier    ${CHAMP_DATE_NAISSANCE}    ${date_naissance}
    END
    IF    'date_delivrance' in $champs and '${date_delivrance}' != '${EMPTY}'
        Definir Date Dans Calendrier    ${CHAMP_DATE_DELIVRANCE}    ${date_delivrance}
    END
    IF    'date_expiration' in $champs and '${date_expiration}' != '${EMPTY}'
        Definir Date Dans Calendrier    ${CHAMP_DATE_EXPIRATION}    ${date_expiration}
    END
    IF    'sexe' in $champs and '${sexe_ocr}' != '${EMPTY}'
        Selectionner Sexe    ${sexe_ocr}
    END
    IF    'adresse' in $champs and '${adresse}' != '${EMPTY}'
        Remplir Champ Texte Modification Client    ${CHAMP_ADRESSE}    ${adresse}
    END
    IF    'commune' in $champs and '${commune}' != '${EMPTY}'
        Remplir Champ Texte Modification Client    ${CHAMP_COMMUNE}    ${commune}
    END

    Log    Report OCR -> Modification client terminé pour les champs : ${champs}    console=True

Cocher Tout Cocher
    [Documentation]    Coche la case globale "Tout cocher" (visible en haut du panneau
    ...                "Modification client") pour déverrouiller toutes les lignes en un clic,
    ...                utilisée en repli quand le motif ne cible aucun champ précis.
    ...                Locator confirmé via DOM réel (id="flexCheckDefault1").
    Wait Until Element Is Visible    ${CASE_TOUT_COCHER}    timeout=${TIMEOUT}
    Cliquer Element Avec Retry    ${CASE_TOUT_COCHER}

Selectionner Sexe
    [Documentation]    Coche la ligne "Sexe" et sélectionne "Homme"/"Femme" à partir du code
    ...                OCR ("M"/"F"). Locator confirmé via DOM réel (ancré sur le placeholder
    ...                "Selectionner le sexe", qui reste dans le DOM que le champ soit vide ou
    ...                déjà rempli).
    [Arguments]    ${sexe_ocr}
    ${valeur}=    Set Variable If    '${sexe_ocr}'.upper() == 'M'    Homme    Femme
    Cocher La Ligne Du Champ    ${CHAMP_SEXE}
    Cliquer Element Avec Retry    ${CHAMP_SEXE}
    Choisir Option Ng Select    ${valeur}
    Log    Sexe fixé à "${valeur}" (OCR: "${sexe_ocr}")    console=True


Definir Date Dans Calendrier
    [Documentation]    Définit une date via JavaScript (contourne le widget ngx-daterangepicker-material
    ...                qui ne s'ouvre pas fiablement au clic). ${valeur} au format "DD/MM/YYYY".
    [Arguments]    ${champ_locator}    ${valeur}
    Cocher La Ligne Du Champ    ${champ_locator}
    Wait Until Keyword Succeeds    5x    0.5s
    ...    Champ Doit Etre Active    ${champ_locator}

    ${element}=    Get WebElement    ${champ_locator}
    ${script}=    Catenate    SEPARATOR=;
    ...    arguments[0].value = arguments[1]
    ...    arguments[0].dispatchEvent(new Event('input', {bubbles: true}))
    ...    arguments[0].dispatchEvent(new Event('change', {bubbles: true}))
    Execute JavaScript    ${script}    ARGUMENTS    ${element}    ${valeur}

    Journaliser Etape    Date "${valeur}" définie dans ${champ_locator} (via JS).