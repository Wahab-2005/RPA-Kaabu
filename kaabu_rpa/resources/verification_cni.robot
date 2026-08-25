*** Settings ***
Library    SeleniumLibrary
Library    OperatingSystem
Library    Process
Library    Collections
Library    String
Library    JSONLibrary
Resource   variables.robot
Resource   keywords.robot


*** Variables ***
# Confirmés via inspection DOM : images servies par une vraie API de téléchargement
${CNI_RECTO_IMG}    xpath=//img[@alt='photo-recto']
${CNI_VERSO_IMG}    xpath=//img[@alt='photo-verso']

${OCR_TEMP_DIR}      ${CURDIR}${/}..${/}results${/}ocr_tmp
${OCR_SCRIPT}        ${CURDIR}${/}..${/}scripts${/}ocr_cni.py

# Localisation des valeurs déjà affichées sur la fiche "Détails de la demande",
# pour comparaison avec ce que l'API OCR retourne.
${ECRAN_NOM}                xpath=//*[contains(text(),'Nom')]/following::*[1]
${ECRAN_PRENOM}             xpath=//*[contains(text(),'Prenom')]/following::*[1]
${ECRAN_NUMERO_PIECE}       xpath=//*[contains(text(),'Numéro de pièce')]/following::*[1]
${ECRAN_DATE_NAISSANCE}     xpath=//*[contains(text(),'Date de naissance')]/following::*[1]
${ECRAN_LIEU_NAISSANCE}     xpath=//*[contains(text(),'Lieu de naissance')]/following::*[1]
${ECRAN_DATE_DELIVRANCE}    xpath=//*[contains(text(),'Date délivrance')]/following::*[1]
${ECRAN_DATE_EXPIRATION}    xpath=//*[contains(text(),"Date d'expiration")]/following::*[1]
${ECRAN_ADRESSE}            xpath=//*[contains(text(),'Adresse')]/following::*[1]

${BOUTON_PDF_FORMULAIRE}    css:span.fa.fa-file-pdf-o
${PDF_SCRIPT}                ${CURDIR}${/}..${/}scripts${/}extraire_texte_pdf.py

# Champs texte : comparaison directe (après normalisation majuscules/espaces)
&{MAPPING_CHAMPS_TEXTE}
...    lastname=${ECRAN_NOM}
...    firstname=${ECRAN_PRENOM}
...    nin=${ECRAN_NUMERO_PIECE}

# Champs date : l'API renvoie JJ/MM/AAAA, l'écran affiche AAAA-MM-JJ -> normalisation avant comparaison
&{MAPPING_CHAMPS_DATE}
...    delivery_date=${ECRAN_DATE_DELIVRANCE}
...    expiration_date=${ECRAN_DATE_EXPIRATION}


*** Keywords ***
Telecharger Image CNI En Pleine Resolution
    [Documentation]    Récupère l'URL réelle de l'image (résolue en absolu par le navigateur),
    ...                la télécharge via fetch() dans la session déjà authentifiée, et
    ...                l'enregistre en local. Retente automatiquement jusqu'à ${max_tentatives}
    ...                fois (pause croissante) en cas d'échec réseau/connexion passager, pour ne
    ...                pas faire échouer tout le dossier à cause d'un simple aléa de connexion.
    [Arguments]    ${locator}    ${nom_fichier}    ${tentative}=1    ${max_tentatives}=3
    Create Directory    ${OCR_TEMP_DIR}
    Wait Until Element Is Visible    ${locator}    timeout=${TIMEOUT}
    ${url_image}=    Get Element Attribute    ${locator}    src

    ${b64}=    Execute Async Javascript
    ...    var callback = arguments[arguments.length - 1];
    ...    fetch(arguments[0], {credentials: 'include'})
    ...      .then(r => r.blob())
    ...      .then(blob => {
    ...          var reader = new FileReader();
    ...          reader.onloadend = () => callback(reader.result.split(',')[1]);
    ...          reader.readAsDataURL(blob);
    ...      })
    ...      .catch(e => callback('ERROR:' + e));
    ...    ARGUMENTS
    ...    ${url_image}

    ${echec_telechargement}=    Run Keyword And Return Status    Should Start With    ${b64}    ERROR:
    IF    ${echec_telechargement}
        ${peut_retenter}=    Evaluate    ${tentative} < ${max_tentatives}
        IF    ${peut_retenter}
            ${pause}=    Evaluate    ${tentative} * 5
            Journaliser Etape
            ...    ⚠️ Échec réseau au téléchargement de l'image CNI (tentative ${tentative}/${max_tentatives}) : ${b64} — nouvel essai dans ${pause}s.
            ...    niveau=WARN
            Sleep    ${pause}s
            ${nouvelle_tentative}=    Evaluate    ${tentative} + 1
            ${chemin}=    Telecharger Image CNI En Pleine Resolution
            ...    ${locator}    ${nom_fichier}    tentative=${nouvelle_tentative}    max_tentatives=${max_tentatives}
            RETURN    ${chemin}
        END
        Journaliser Erreur Et Echouer
        ...    Échec du téléchargement de l'image CNI depuis ${url_image} après ${max_tentatives} tentatives : ${b64}
    END

    ${chemin}=    Set Variable    ${OCR_TEMP_DIR}${/}${nom_fichier}.jpg
    ${bytes}=     Evaluate    base64.b64decode('''${b64}''')    base64
    Create Binary File    ${chemin}    ${bytes}
    RETURN    ${chemin}

Appeler API OCR CNI
    [Documentation]    Envoie le recto/verso à l'API OCR interne et retourne les données extraites
    ...                (contenu de la clé "results") sous forme de dictionnaire Robot Framework.
    ...                Retente automatiquement jusqu'à ${max_tentatives} fois (pause croissante)
    ...                en cas d'échec TECHNIQUE (script sans réponse, erreur API/réseau), pour ne
    ...                pas déclarer un dossier "à ignorer" à cause d'un simple problème de
    ...                connexion passager — sinon le dossier reste non validé sur le portail et le
    ...                prochain passage du RPA le retrouve dans le même état, sans certitude qu'il
    ...                sera correctement repris. Ne retente PAS quand l'OCR a répondu normalement
    ...                mais sans donnée exploitable (cas métier, ex: photo illisible) : retenter
    ...                ne changerait rien dans ce cas.
    [Arguments]    ${chemin_recto}    ${chemin_verso}    ${tentative}=1    ${max_tentatives}=3
    ${result}=    Run Process    python    ${OCR_SCRIPT}    ${chemin_recto}    ${chemin_verso}

    Log    Code retour : ${result.rc}    console=True
    Log    STDOUT : ${result.stdout}    console=True
    Log    STDERR : ${result.stderr}    console=True

    ${stdout_vide}=    Run Keyword And Return Status    Should Be Empty    ${result.stdout}
    IF    ${stdout_vide}
        ${donnees}=    Retenter Ou Abandonner Appel OCR
        ...    ${chemin_recto}    ${chemin_verso}    ${tentative}    ${max_tentatives}
        ...    Script OCR sans réponse. STDERR: ${result.stderr}
        RETURN    ${donnees}
    END

    Create Directory    ${OCR_TEMP_DIR}
    Create File    ${OCR_TEMP_DIR}${/}reponse_ocr.json    ${result.stdout}

    ${reponse}=    Convert String To Json    ${result.stdout}

    ${a_erreur}=    Run Keyword And Return Status
    ...    Dictionary Should Contain Key    ${reponse}    erreur
    IF    ${a_erreur}
        ${donnees}=    Retenter Ou Abandonner Appel OCR
        ...    ${chemin_recto}    ${chemin_verso}    ${tentative}    ${max_tentatives}
        ...    L'API OCR a retourné une erreur : ${reponse}[erreur]
        RETURN    ${donnees}
    END

    ${erreurs_api}=    Get From Dictionary    ${reponse}    errors    default=${EMPTY}
    IF    $erreurs_api
        ${donnees}=    Retenter Ou Abandonner Appel OCR
        ...    ${chemin_recto}    ${chemin_verso}    ${tentative}    ${max_tentatives}
        ...    L'API OCR a retourné une erreur : ${erreurs_api}
        RETURN    ${donnees}
    END

    ${donnees}=    Get From Dictionary    ${reponse}    results    default=${EMPTY}
    IF    not $donnees
        Journaliser Etape    ⚠️ L'API OCR n'a retourné aucune donnée exploitable — dossier ignoré.    niveau=WARN
        ${vide}=    Create Dictionary
        RETURN    ${vide}
    END
    RETURN    ${donnees}

Retenter Ou Abandonner Appel OCR
    [Documentation]    Utilisé uniquement par "Appeler API OCR CNI" en cas d'échec TECHNIQUE
    ...                (script sans réponse, erreur API/réseau). Si des tentatives restent,
    ...                journalise un WARN, attend une pause croissante puis rappelle "Appeler API
    ...                OCR CNI". Sinon, journalise l'échec technique confirmé (dossier ignoré,
    ...                à retraiter au prochain passage) et retourne un dictionnaire vide.
    [Arguments]    ${chemin_recto}    ${chemin_verso}    ${tentative}    ${max_tentatives}    ${motif}
    ${peut_retenter}=    Evaluate    ${tentative} < ${max_tentatives}
    IF    ${peut_retenter}
        ${pause}=    Evaluate    ${tentative} * 5
        Journaliser Etape
        ...    ⚠️ ${motif} (tentative ${tentative}/${max_tentatives}) — nouvel essai dans ${pause}s.
        ...    niveau=WARN
        Sleep    ${pause}s
        ${nouvelle_tentative}=    Evaluate    ${tentative} + 1
        ${donnees}=    Appeler API OCR CNI
        ...    ${chemin_recto}    ${chemin_verso}    tentative=${nouvelle_tentative}    max_tentatives=${max_tentatives}
        RETURN    ${donnees}
    END
    Journaliser Etape
    ...    ⚠️ ${motif} — échec technique confirmé après ${max_tentatives} tentatives — dossier ignoré (à retraiter au prochain passage).
    ...    niveau=WARN
    ${vide}=    Create Dictionary
    RETURN    ${vide}

Normaliser Texte
    [Documentation]    Met en majuscules, retire les espaces superflus en début/fin, et
    ...                collapse les espaces multiples internes en un seul espace (les PDF de
    ...                formulaires ont souvent des espacements internes irréguliers entre mots
    ...                distants sur une même ligne, ce qui casse les comparaisons exactes).
    [Arguments]    ${texte}
    ${t}=    Convert To Upper Case    ${texte}
    ${t}=    Strip String    ${t}
    ${t}=    Evaluate    re.sub(r'\\s+', ' ', """${t}""")    re
    RETURN    ${t}

Normaliser Date
    [Documentation]    Convertit une date JJ/MM/AAAA ou AAAA-MM-JJ vers AAAA-MM-JJ pour comparaison.
    ...                Retourne la chaîne d'origine (nettoyée) si le format n'est pas reconnu.
    [Arguments]    ${texte_date}
    ${t}=    Strip String    ${texte_date}
    ${match_slash}=    Run Keyword And Return Status
    ...    Should Match Regexp    ${t}    ^\\d{2}/\\d{2}/\\d{4}$
    IF    ${match_slash}
        ${jour}=      Get Substring    ${t}    0    2
        ${mois}=      Get Substring    ${t}    3    5
        ${annee}=     Get Substring    ${t}    6    10
        RETURN    ${annee}-${mois}-${jour}
    END
    ${match_iso}=    Run Keyword And Return Status
    ...    Should Match Regexp    ${t}    ^\\d{4}-\\d{2}-\\d{2}$
    IF    ${match_iso}
        RETURN    ${t}
    END
    RETURN    ${t}

Comparer Champ Texte OCR
    [Documentation]    Compare une valeur texte OCR à la valeur affichée à l'écran. Ne journalise
    ...                plus champ par champ : le résultat (${ok}, ${valeur_ecran}) est utilisé par
    ...                "Verifier Coherence CNI" pour construire le tableau récapitulatif unique
    ...                (Champ | Ecran | OCR CNI | Décision) journalisé en une seule fois.
    [Arguments]    ${nom_champ}    ${valeur_ocr}    ${locator_ecran}
    ${valeur_ecran}=    Get Text    ${locator_ecran}
    ${ocr_norm}=      Normaliser Texte    ${valeur_ocr}
    ${ecran_norm}=    Normaliser Texte    ${valeur_ecran}
    ${ok}=    Evaluate    '${ocr_norm}' == '${ecran_norm}'
    RETURN    ${ok}    ${valeur_ecran}

Comparer Champ Date OCR
    [Documentation]    Compare une valeur date OCR à la valeur affichée à l'écran, après
    ...                normalisation. Ne journalise plus champ par champ (voir Comparer Champ
    ...                Texte OCR ci-dessus pour l'explication).
    [Arguments]    ${nom_champ}    ${valeur_ocr}    ${locator_ecran}
    ${valeur_ecran}=    Get Text    ${locator_ecran}
    ${ocr_norm}=      Normaliser Date    ${valeur_ocr}
    ${ecran_norm}=    Normaliser Date    ${valeur_ecran}
    ${ok}=    Evaluate    '${ocr_norm}' == '${ecran_norm}'
    RETURN    ${ok}    ${valeur_ecran}

Verifier Coherence CNI
    [Documentation]    Télécharge le recto/verso, les envoie à l'API OCR interne, puis compare
    ...                chaque champ retourné à ce qui est affiché sur la fiche. Tolère UN SEUL
    ...                champ divergent parmi nom/prénom/dates (l'OCR peut être imprécis sur une
    ...                photo floue, la saisie écran peut contenir une erreur humaine). Le NIN
    ...                reste STRICT dans tous les cas : toute divergence ou absence du NIN rend
    ...                le dossier incohérent, quel que soit le nombre d'autres divergences.
    ...                RETURN: ${tout_coherent} (booléen), ${rapport} (dictionnaire détaillé),
    ...                ${donnees_ocr} (dictionnaire brut renvoyé par l'API OCR, pour journalisation).

    ${chemin_recto}=    Telecharger Image CNI En Pleine Resolution    ${CNI_RECTO_IMG}    cni_recto
    ${chemin_verso}=    Telecharger Image CNI En Pleine Resolution    ${CNI_VERSO_IMG}    cni_verso

    ${donnees_ocr}=    Appeler API OCR CNI    ${chemin_recto}    ${chemin_verso}

    IF    not $donnees_ocr
        Journaliser Etape    ⚠️ Aucune donnée OCR disponible — vérification impossible, dossier à ignorer.    niveau=WARN
        ${rapport_vide}=    Create Dictionary    ocr=AUCUNE_DONNEE
        ${donnees_vides}=    Create Dictionary
        RETURN    ${FALSE}    ${rapport_vide}    ${donnees_vides}
    END

    Journaliser Etape    ${\n}==================== DONNÉES EXTRAITES PAR L'OCR ====================
    FOR    ${cle}    ${valeur}    IN    &{donnees_ocr}
        Journaliser Etape    ${cle} : ${valeur}
    END
    Journaliser Etape    =======================================================================

    ${rapport}=    Create Dictionary
    ${nb_divergences}=    Set Variable    ${0}
    ${lignes_tableau}=    Create List

    FOR    ${cle_ocr}    ${locator_ecran}    IN    &{MAPPING_CHAMPS_TEXTE}
        ${present}=    Run Keyword And Return Status
        ...    Dictionary Should Contain Key    ${donnees_ocr}    ${cle_ocr}
        IF    ${present}
            ${valeur_ocr}=    Get From Dictionary    ${donnees_ocr}    ${cle_ocr}
            ${ok}    ${valeur_ecran}=    Comparer Champ Texte OCR    ${cle_ocr}    ${valeur_ocr}    ${locator_ecran}
            Set To Dictionary    ${rapport}    ${cle_ocr}=${ok}
            ${decision}=    Set Variable If    ${ok}    OK    NON
            ${ligne}=    Create Dictionary    champ=${cle_ocr}    ecran=${valeur_ecran}    ocr=${valeur_ocr}    decision=${decision}
            Append To List    ${lignes_tableau}    ${ligne}
            IF    not ${ok} and '${cle_ocr}' != 'nin'
                ${nb_divergences}=    Evaluate    ${nb_divergences} + 1
            END
        ELSE
            Journaliser Etape    ⚠️ Champ "${cle_ocr}" absent de la réponse OCR.    niveau=WARN
            Set To Dictionary    ${rapport}    ${cle_ocr}=ABSENT
            ${ligne}=    Create Dictionary    champ=${cle_ocr}    ecran=N/A    ocr=ABSENT    decision=NON (absent)
            Append To List    ${lignes_tableau}    ${ligne}
            IF    '${cle_ocr}' != 'nin'
                ${nb_divergences}=    Evaluate    ${nb_divergences} + 1
            END
        END
    END

    FOR    ${cle_ocr}    ${locator_ecran}    IN    &{MAPPING_CHAMPS_DATE}
        ${present}=    Run Keyword And Return Status
        ...    Dictionary Should Contain Key    ${donnees_ocr}    ${cle_ocr}
        IF    ${present}
            ${valeur_ocr}=    Get From Dictionary    ${donnees_ocr}    ${cle_ocr}
            ${ok}    ${valeur_ecran}=    Comparer Champ Date OCR    ${cle_ocr}    ${valeur_ocr}    ${locator_ecran}
            Set To Dictionary    ${rapport}    ${cle_ocr}=${ok}
            ${decision}=    Set Variable If    ${ok}    OK    NON
            ${ligne}=    Create Dictionary    champ=${cle_ocr}    ecran=${valeur_ecran}    ocr=${valeur_ocr}    decision=${decision}
            Append To List    ${lignes_tableau}    ${ligne}
            IF    not ${ok}
                ${nb_divergences}=    Evaluate    ${nb_divergences} + 1
            END
        ELSE
            Journaliser Etape    ⚠️ Champ "${cle_ocr}" absent de la réponse OCR.    niveau=WARN
            Set To Dictionary    ${rapport}    ${cle_ocr}=ABSENT
            ${ligne}=    Create Dictionary    champ=${cle_ocr}    ecran=N/A    ocr=ABSENT    decision=NON (absent)
            Append To List    ${lignes_tableau}    ${ligne}
            ${nb_divergences}=    Evaluate    ${nb_divergences} + 1
        END
    END

    Journaliser Tableau Comparaison    ${lignes_tableau}

    ${nin_valeur}=    Get From Dictionary    ${rapport}    nin    default=ABSENT
    ${nin_ok}=    Evaluate    "${nin_valeur}" == "True"

    ${tout_coherent}=    Evaluate    (${nb_divergences} <= 1) and $nin_ok

    IF    not $nin_ok
        Journaliser Etape    ⚠️ NIN absent ou divergent — champ critique, dossier incohérent quel que soit le reste.    niveau=WARN
    ELSE IF    ${nb_divergences} == 0
        Journaliser Etape    ✅ Tous les champs vérifiés correspondent (recto/verso OCR vs écran).
    ELSE IF    ${nb_divergences} == 1
        Journaliser Etape    ⚠️ 1 champ divergent toléré (hors NIN) — dossier considéré comme cohérent : ${rapport}    niveau=WARN
    ELSE
        Journaliser Etape    ⚠️ ${nb_divergences} champs divergents (seuil de tolérance dépassé) — vérification manuelle requise avant Valider.    niveau=WARN
    END

    RETURN    ${tout_coherent}    ${rapport}    ${donnees_ocr}

Valider Une Piece Jointe
    [Documentation]    Clique sur une vignette (recto ou verso) pour ouvrir sa visionneuse,
    ...                puis clique sur le bouton "Valider" propre à cette image.
    [Arguments]    ${locator_vignette}
    Wait Until Element Is Visible    ${locator_vignette}    timeout=${TIMEOUT}
    Cliquer Et Journaliser    ${locator_vignette}    Vignette pièce jointe (${locator_vignette})

    ${bouton_valider}=    Set Variable    css:button.btn.bt-valid
    Wait Until Element Is Visible    ${bouton_valider}    timeout=${TIMEOUT}
    Cliquer Et Journaliser    ${bouton_valider}    Bouton Valider (pièce jointe)
    Journaliser Etape    Pièce jointe validée.

Valider Les Pieces Jointes CNI
    [Documentation]    Valide le recto puis le verso de la CNI, chacun via sa propre visionneuse.
    Valider Une Piece Jointe    ${CNI_RECTO_IMG}
    Sleep    0.5s
    Valider Une Piece Jointe    ${CNI_VERSO_IMG}
    Sleep    0.5s

Telecharger Et Lire Formulaire PDF
    [Documentation]    Clique sur l'icône PDF pour ouvrir le formulaire signé dans un nouvel onglet,
    ...                récupère son contenu (blob) depuis ce nouvel onglet, l'enregistre en local,
    ...                puis en extrait le texte brut. Retourne le texte extrait.
    ${fenetre_originale}=    Get Window Handles
    Set Suite Variable    ${FENETRE_ORIGINALE}    ${fenetre_originale}[0]

    Wait Until Element Is Visible    ${BOUTON_PDF_FORMULAIRE}    timeout=${TIMEOUT}
    Cliquer Et Journaliser    ${BOUTON_PDF_FORMULAIRE}    Icône PDF (formulaire signé)
    Sleep    1s

    ${toutes_fenetres}=    Get Window Handles
    ${nouvelle_fenetre}=    Set Variable    ${toutes_fenetres}[-1]
    Switch Window    ${nouvelle_fenetre}

    ${url_pdf}=    Get Location

    ${b64}=    Execute Async Javascript
    ...    var callback = arguments[arguments.length - 1];
    ...    fetch(arguments[0])
    ...      .then(r => r.blob())
    ...      .then(blob => {
    ...          var reader = new FileReader();
    ...          reader.onloadend = () => callback(reader.result.split(',')[1]);
    ...          reader.readAsDataURL(blob);
    ...      })
    ...      .catch(e => callback('ERROR:' + e));
    ...    ARGUMENTS
    ...    ${url_pdf}

    Close Window
    Switch Window    ${FENETRE_ORIGINALE}

    ${echec_telechargement}=    Run Keyword And Return Status    Should Start With    ${b64}    ERROR:
    IF    ${echec_telechargement}
        Journaliser Erreur Et Echouer    Échec du téléchargement du formulaire PDF depuis ${url_pdf} : ${b64}
    END

    Create Directory    ${OCR_TEMP_DIR}
    ${chemin_pdf}=    Set Variable    ${OCR_TEMP_DIR}${/}formulaire.pdf
    ${bytes}=    Evaluate    base64.b64decode('''${b64}''')    base64
    Create Binary File    ${chemin_pdf}    ${bytes}

    ${result}=    Run Process    python    ${PDF_SCRIPT}    ${chemin_pdf}
    ${extraction_vide}=    Run Keyword And Return Status    Should Be Empty    ${result.stdout}
    IF    ${extraction_vide}
        Journaliser Erreur Et Echouer    Extraction du texte PDF vide. STDERR: ${result.stderr}
    END
    ${echec_extraction}=    Run Keyword And Return Status    Should Start With    ${result.stdout}    ERREUR:
    IF    ${echec_extraction}
        Journaliser Erreur Et Echouer    Échec extraction PDF: ${result.stdout}
    END

    RETURN    ${result.stdout}

Verifier Tous Les Mots Presents
    [Documentation]    Découpe ${valeur_norm} en mots et vérifie que chacun apparaît dans
    ...                ${texte_pdf_norm}. Journalise précisément quel(s) mot(s) manque(nt) le cas
    ...                échéant. ${label} sert uniquement à un affichage lisible dans les logs.
    ...                Comparaison tolérante aux espacements irréguliers, retours à la ligne
    ...                internes, et ordre des mots — plus robuste qu'une correspondance de
    ...                chaîne complète, notamment pour les noms/prénoms composés.
    ...                RETURN: ${ok} (booléen), ${mots_manquants} (liste, vide si tout est trouvé).
    [Arguments]    ${valeur_norm}    ${texte_pdf_norm}    ${label}
    ${mots}=    Split String    ${valeur_norm}    ${SPACE}
    ${mots_manquants}=    Create List
    FOR    ${mot}    IN    @{mots}
        ${present}=    Run Keyword And Return Status
        ...    Should Contain    ${texte_pdf_norm}    ${mot}
        IF    not ${present}
            Append To List    ${mots_manquants}    ${mot}
        END
    END

    IF    ${mots_manquants}
        Journaliser Etape    ⚠️ "${label}" : mot(s) NON retrouvé(s) dans le PDF : ${mots_manquants}    niveau=WARN
        RETURN    ${FALSE}    ${mots_manquants}
    ELSE
        Journaliser Etape    ✅ "${label}" : tous les mots retrouvés dans le formulaire PDF.
        RETURN    ${TRUE}    ${mots_manquants}
    END

Verifier Nom Prenom Formulaire
    [Documentation]    Vérifie que chaque mot du nom et du prénom affichés sur la fiche apparaît
    ...                dans le texte du formulaire PDF signé (comparaison par tokens, tolérante
    ...                aux espacements irréguliers, retours à la ligne, et ordre des mots).
    ...                RETURN: ${ok} (booléen global), ${detail} (dictionnaire avec le détail
    ...                nom/prénom, pour journalisation JSON).
    ${texte_pdf}=    Telecharger Et Lire Formulaire PDF
    ${texte_pdf_norm}=    Normaliser Texte    ${texte_pdf}

    ${nom_ecran}=      Get Text    ${ECRAN_NOM}
    ${prenom_ecran}=   Get Text    ${ECRAN_PRENOM}
    ${nom_norm}=       Normaliser Texte    ${nom_ecran}
    ${prenom_norm}=    Normaliser Texte    ${prenom_ecran}

    ${nom_present}       ${mots_manquants_nom}=       Verifier Tous Les Mots Presents    ${nom_norm}    ${texte_pdf_norm}    ${nom_ecran}
    ${prenom_present}    ${mots_manquants_prenom}=    Verifier Tous Les Mots Presents    ${prenom_norm}    ${texte_pdf_norm}    ${prenom_ecran}

    ${detail}=    Create Dictionary
    ...    nom=${nom_ecran}
    ...    nom_ok=${nom_present}
    ...    mots_manquants_nom=${mots_manquants_nom}
    ...    prenom=${prenom_ecran}
    ...    prenom_ok=${prenom_present}
    ...    mots_manquants_prenom=${mots_manquants_prenom}

    ${ok}=    Evaluate    ${nom_present} and ${prenom_present}
    RETURN    ${ok}    ${detail}