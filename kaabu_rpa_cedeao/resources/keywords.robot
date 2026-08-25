*** Settings ***
Library     SeleniumLibrary
Library     DateTime
Library     String
Library     OperatingSystem
Library     ../scripts/nationalite_lib.py
Resource    variables.robot


*** Keywords ***
Charger Env Dotenv
    [Documentation]    Lit le fichier .env à la racine du projet et exporte chaque paire
    ...                clé=valeur comme variable d'environnement du process Robot Framework
    ...                en cours (Set Environment Variable), afin que "Get Environment
    ...                Variable" puisse ensuite les lire dans les keywords de connexion.
    ...                Pure Robot Framework, aucun script de lancement externe requis — DOIT
    ...                être le tout premier keyword de chaque Suite Setup, avant tout keyword
    ...                qui a besoin d'identifiants (Se Connecter Sur Kaabu, Outlook, etc.).
    ...                Ignore les lignes vides et les commentaires (#...). Échoue clairement
    ...                si le .env est absent (copier .env.example vers .env et le remplir).
    [Arguments]    ${chemin}=${CURDIR}/../.env
    File Should Exist    ${chemin}
    ...    msg=Fichier .env introuvable (${chemin}). Copier .env.example vers .env et le remplir avant de lancer les tests.
    ${contenu}=    Get File    ${chemin}
    @{lignes}=    Split To Lines    ${contenu}
    FOR    ${ligne}    IN    @{lignes}
        ${ligne}=    Strip String    ${ligne}
        ${est_commentaire}=    Evaluate    '''${ligne}'''.startswith('#')
        ${a_un_egal}=    Evaluate    '=' in '''${ligne}'''
        IF    '${ligne}' != '${EMPTY}' and not ${est_commentaire} and ${a_un_egal}
            ${cle}    ${valeur}=    Split String    ${ligne}    =    1
            ${cle}=    Strip String    ${cle}
            ${valeur}=    Strip String    ${valeur}
            IF    '${valeur}' != '${EMPTY}'
                Set Environment Variable    ${cle}    ${valeur}
            END
        END
    END
    Log    Variables d'environnement chargées depuis ${chemin}    console=True

Initialiser Journal
    [Documentation]    Crée (si besoin) le dossier logs/ et détermine le fichier journal du jour
    ...                (logs/AAAA-MM-JJ.log). Un fichier différent est ainsi utilisé chaque jour,
    ...                pour éviter un unique journal.log qui grossirait indéfiniment. Ne vide
    ...                JAMAIS un fichier existant : chaque session/journée ajoute simplement à la
    ...                suite (append-only).
    Create Directory    ${LOGS_DIR}
    ${date_du_jour}=    Get Current Date    result_format=%Y-%m-%d
    ${fichier_journal}=    Set Variable    ${LOGS_DIR}${/}${date_du_jour}.log
    Set Suite Variable    ${FICHIER_JOURNAL}    ${fichier_journal}

    ${ts}=    Get Current Date    result_format=%Y-%m-%d %H:%M:%S
    ${existe_log}=    Run Keyword And Return Status    File Should Exist    ${FICHIER_JOURNAL}
    IF    not ${existe_log}
        Create File    ${FICHIER_JOURNAL}    ${EMPTY}
    END
    Append To File    ${FICHIER_JOURNAL}    ==================== DÉBUT DE SESSION : ${ts} ====================${\n}

    ${existe_json}=    Run Keyword And Return Status    File Should Exist    ${FICHIER_JOURNAL_JSON}
    IF    not ${existe_json}
        Create File    ${FICHIER_JOURNAL_JSON}    ${EMPTY}
    END

Journaliser Etape
    [Documentation]    Ajoute une ligne horodatée au fichier journal, en plus du log console habituel.
    ...                À utiliser à chaque étape clé du traitement (connexion, filtrage, ouverture
    ...                de dossier, résultat OCR, décision, etc.). Niveaux supportés : INFO, WARN, ERROR.
    [Arguments]    ${message}    ${niveau}=INFO
    ${ts}=    Get Current Date    result_format=%Y-%m-%d %H:%M:%S
    ${ligne}=    Catenate    SEPARATOR=    [${ts}] [${niveau}] ${message}${\n}
    Append To File    ${FICHIER_JOURNAL}    ${ligne}
    Log    ${message}    console=True

Journaliser Erreur Et Echouer
    [Documentation]    Journalise ${message} au niveau ERROR (échec technique bloquant : API
    ...                injoignable, téléchargement impossible, connexion refusée, etc. — à
    ...                distinguer du niveau WARN qui signale une anomalie métier non bloquante,
    ...                ex : un champ divergent), puis interrompt le test en cours avec Fail.
    [Arguments]    ${message}
    Journaliser Etape    ❌ ${message}    niveau=ERROR
    Fail    ${message}

Cliquer Et Journaliser
    [Documentation]    Clique sur l'élément donné (Click Element) puis journalise systématiquement
    ...                l'action dans journal.log, afin que CHAQUE bouton/élément cliqué sur le
    ...                portail apparaisse dans le journal, avec un nom lisible.
    [Arguments]    ${locator}    ${nom_bouton}
    Click Element    ${locator}
    Journaliser Etape    🖱️ Clic sur : ${nom_bouton}
    Sleep    ${DELAI_DEMO}

Cliquer Bouton Et Journaliser
    [Documentation]    Identique à "Cliquer Et Journaliser" mais utilise Click Button (soumission
    ...                de formulaire), pour les cas où SeleniumLibrary exige spécifiquement ce
    ...                keyword (ex : bouton de connexion).
    [Arguments]    ${locator}    ${nom_bouton}
    Click Button    ${locator}
    Journaliser Etape    🖱️ Clic sur : ${nom_bouton}
    Sleep    ${DELAI_DEMO}

Cliquer Et Journaliser Avec Retry
    [Documentation]    Comme "Cliquer Et Journaliser", mais relocalise et retente le clic
    ...                (Wait Until Keyword Succeeds) en cas d'échec transitoire — utile pour les
    ...                éléments qui peuvent être temporairement non interactifs juste après leur
    ...                apparition (ex : bouton d'une popup SweetAlert2 encore en animation
    ...                d'ouverture, ce qui provoque un ElementNotInteractableException si on
    ...                clique trop tôt).
    [Arguments]    ${locator}    ${nom_bouton}    ${tentatives}=5    ${intervalle}=0.5s
    Wait Until Keyword Succeeds    ${tentatives}x    ${intervalle}
    ...    Click Element    ${locator}
    Journaliser Etape    🖱️ Clic sur : ${nom_bouton}
    Sleep    ${DELAI_DEMO}

Journaliser Tableau Comparaison
    [Documentation]    Construit et journalise (niveau INFO), en une seule entrée de journal, un
    ...                tableau récapitulatif "Champ | Ecran | OCR CNI | Décision" pour l'ensemble
    ...                des champs comparés lors de la vérification OCR CNI. ${lignes} est une liste
    ...                de dictionnaires avec les clés : champ, ecran, ocr, decision.
    [Arguments]    ${lignes}
    ${entete}=    Evaluate    "{:<20} | {:<28} | {:<28} | {}".format("Champ", "Ecran", "OCR CNI", "Décision")
    ${separateur}=    Evaluate    "-" * len($entete)
    ${corps}=    Create List    ${entete}    ${separateur}
    FOR    ${ligne}    IN    @{lignes}
        ${texte_ligne}=    Evaluate
        ...    "{:<20} | {:<28} | {:<28} | {}".format(str($ligne['champ']), str($ligne['ecran']), str($ligne['ocr']), str($ligne['decision']))
        Append To List    ${corps}    ${texte_ligne}
    END
    ${tableau}=    Catenate    SEPARATOR=${\n}    @{corps}
    Journaliser Etape    ${\n}==================== COMPARAISON ÉCRAN vs OCR CNI ====================${\n}${tableau}${\n}========================================================================

Enregistrer Dossier Json
    [Documentation]    Ajoute un enregistrement JSON (une ligne = un objet JSON complet, format
    ...                "JSON Lines") au fichier ${FICHIER_JOURNAL_JSON}, résumant le traitement
    ...                complet d'un dossier : MSISDN, résultat OCR CNI, décision de cohérence,
    ...                validation des pièces jointes, résultat OCR du formulaire, et si la
    ...                validation finale a été effectuée.
    [Arguments]    ${enregistrement}
    ${ts}=    Get Current Date    result_format=%Y-%m-%dT%H:%M:%S
    Set To Dictionary    ${enregistrement}    horodatage=${ts}
    ${ligne_json}=    Evaluate    json.dumps($enregistrement, ensure_ascii=False)    json
    Append To File    ${FICHIER_JOURNAL_JSON}    ${ligne_json}${\n}    encoding=UTF-8
    Log    Enregistrement JSON ajouté au journal : ${ligne_json}    console=True

Initialiser Rapport Simple
    [Documentation]    Prépare la liste en mémoire qui accumulera une ligne lisible par dossier
    ...                traité durant CETTE session. Le fichier rapport existant n'est jamais
    ...                effacé — chaque session ajoute son bloc à la suite (append-only).
    ${liste}=    Create List
    Set Suite Variable    ${LISTE_RAPPORT}    ${liste}

Ajouter Au Rapport Simple
    [Documentation]    Ajoute une ligne lisible "MSISDN - statut" au rapport final.
    [Arguments]    ${msisdn}    ${statut}
    Append To List    ${LISTE_RAPPORT}    ${msisdn} — ${statut}

Generer Rapport Simple
    [Documentation]    Ajoute (append) au fichier rapport un bloc résumant la session en cours,
    ...                avec horodatage et total. Ne touche jamais aux sessions précédentes déjà
    ...                présentes dans le fichier.
    ${ts}=    Get Current Date    result_format=%Y-%m-%d %H:%M:%S
    ${total}=    Get Length    ${LISTE_RAPPORT}

    ${existe}=    Run Keyword And Return Status    File Should Exist    ${FICHIER_RAPPORT}
    IF    not ${existe}
        Create File    ${FICHIER_RAPPORT}    ${EMPTY}
    END

    ${lignes}=    Create List
    Append To List    ${lignes}    ==================================================
    Append To List    ${lignes}    RAPPORT D'EXÉCUTION — KAABU RPA
    Append To List    ${lignes}    Session du : ${ts}
    Append To List    ${lignes}    ==================================================
    FOR    ${ligne}    IN    @{LISTE_RAPPORT}
        Append To List    ${lignes}    ${ligne}
    END
    Append To List    ${lignes}    --------------------------------------------------
    Append To List    ${lignes}    Total dossiers traités cette session : ${total}
    Append To List    ${lignes}    ${EMPTY}

    ${texte}=    Catenate    SEPARATOR=${\n}    @{lignes}
    Append To File    ${FICHIER_RAPPORT}    ${texte}${\n}
    Log    Rapport d'exécution mis à jour : ${FICHIER_RAPPORT}    console=True

Finaliser Session
    [Documentation]    Génère le rapport simple puis ferme le navigateur (utilisé comme Suite Teardown).
    Generer Rapport Simple
    Fermer Le Navigateur Kaabu

Ouvrir Le Navigateur Kaabu
    [Documentation]    Ouvre le navigateur et navigue vers le site KAABU.
    IF    ${HEADLESS}
        ${options}=    Evaluate    sys.modules['selenium.webdriver'].ChromeOptions()    sys
        Call Method    ${options}    add_argument    --headless=new
        Call Method    ${options}    add_argument    --window-size=1920,1080
        Open Browser    ${URL}    ${BROWSER}    options=${options}
    ELSE
        Open Browser    ${URL}    ${BROWSER}
        Maximize Browser Window
    END
    Set Selenium Timeout    ${TIMEOUT}
    Initialiser Journal
    Journaliser Etape    Navigateur ouvert sur ${URL}

Se Connecter Sur Kaabu
    [Documentation]    Réalise l'authentification avec les identifiants fournis. Si ${user}/
    ...                ${pwd} ne sont pas passés explicitement, ils sont lus dans l'environnement
    ...                (KAABU_USERNAME / KAABU_PASSWORD) — chargé au préalable par le tout
    ...                premier keyword du Suite Setup, "Charger Env Dotenv". Ne JAMAIS coder
    ...                des identifiants en dur ici ou dans variables.robot.
    [Arguments]    ${user}=${EMPTY}    ${pwd}=${EMPTY}
    IF    '${user}' == '${EMPTY}'
        ${user}=    Get Environment Variable    KAABU_USERNAME
    END
    IF    '${pwd}' == '${EMPTY}'
        ${pwd}=    Get Environment Variable    KAABU_PASSWORD
    END
    Wait Until Element Is Visible    ${LOGIN_USERNAME_FIELD}
    Input Text      ${LOGIN_USERNAME_FIELD}    ${user}
    Input Password  ${LOGIN_PASSWORD_FIELD}    ${pwd}
    Cliquer Bouton Et Journaliser    ${LOGIN_SUBMIT_BUTTON}    Bouton de connexion (login)
    Wait Until Page Contains Element    ${WELCOME_MARKER}    timeout=${TIMEOUT}
    Journaliser Etape    Connexion réussie pour l'utilisateur ${user}

Verifier Connexion Reussie
    [Documentation]    Vérifie qu'aucun message d'erreur de connexion n'est présent.
    ${status}=    Run Keyword And Return Status
    ...    Page Should Contain Element    ${LOGIN_ERROR_MESSAGE}
    Run Keyword If    ${status}    Journaliser Erreur Et Echouer    Échec de connexion : identifiants refusés par le site.

Ouvrir Ng Select
    [Documentation]    Ouvre le panneau d'un ng-select donné par sa position (1, 2, 3...) sur la page.
    [Arguments]    ${index}
    ${locator}=    Set Variable    ${NGSELECT_CONTAINER}[${index}]
    Wait Until Element Is Visible    ${locator}    timeout=${TIMEOUT}
    Cliquer Et Journaliser    ${locator}    Ng-select n°${index}

Cliquer Element Avec Retry
    [Documentation]    Clique sur un élément en relocalisant à chaque tentative, pour survivre
    ...                aux re-rendus Angular qui invalident les références (StaleElementReferenceException).
    [Arguments]    ${locator}    ${tentatives}=5    ${intervalle}=0.5s
    Wait Until Keyword Succeeds    ${tentatives}x    ${intervalle}
    ...    Cliquer Element Frais    ${locator}

Cliquer Element Frais
    [Documentation]    Attend qu'un élément soit visible, le centre dans la zone visible de la
    ...                page (pour éviter qu'un élément fixe/sticky — ex: le header de navigation
    ...                en haut de page — ne le recouvre partiellement, cas des checkboxes
    ...                "flexCheckDefaultN" proches du haut), puis clique dessus (relocalisé à
    ...                chaque appel). Si le clic natif est malgré tout intercepté
    ...                (ElementClickInterceptedException), bascule automatiquement sur un clic
    ...                JavaScript direct qui ignore la superposition visuelle.
    [Arguments]    ${locator}
    Wait Until Element Is Visible    ${locator}    timeout=3s
    ${element}=    Get WebElement    ${locator}
    Execute Javascript    arguments[0].scrollIntoView({block: "center"});    ARGUMENTS    ${element}
    Sleep    0.2s

    ${clic_natif_ok}=    Run Keyword And Return Status    Click Element    ${locator}
    IF    not ${clic_natif_ok}
        Journaliser Etape    ⚠️ Clic natif intercepté sur "${locator}" — bascule sur clic JavaScript.    niveau=WARN
        ${element}=    Get WebElement    ${locator}
        Execute Javascript    arguments[0].click();    ARGUMENTS    ${element}
    END

    Journaliser Etape    🖱️ Clic sur élément : ${locator}
    Sleep    ${DELAI_DEMO}

Choisir Option Ng Select
    [Documentation]    Clique sur l'option visible correspondant au texte donné dans le panneau ng-select ouvert.
    [Arguments]    ${texte_option}
    ${locator}=    Replace String    ${NGSELECT_OPTION_BY_TEXT}    {option}    ${texte_option}
    Cliquer Element Avec Retry    ${locator}

Filtrer Dossiers Par Etat Et Type
    [Documentation]    Applique le filtre "Etat du dossier" puis "Type de dossier" sur la liste des dossiers.
    [Arguments]    ${etat}=${FILTRE_ETAT_VALEUR}    ${type_dossier}=${FILTRE_TYPE_VALEUR}
    Cliquer Element Avec Retry    ${NGSELECT_ETAT_DOSSIER}
    Choisir Option Ng Select    ${etat}
    Sleep    0.5s
    Cliquer Element Avec Retry    ${NGSELECT_TYPE_DOSSIER}
    Choisir Option Ng Select    ${type_dossier}
    Journaliser Etape    Filtres appliqués : Etat="${etat}", Type="${type_dossier}"

Valider La Recherche
    [Documentation]    Clique sur le bouton OK pour lancer la recherche avec les filtres appliqués.
    Wait Until Element Is Visible    ${BOUTON_OK_RECHERCHE}    timeout=${TIMEOUT}
    Cliquer Et Journaliser    ${BOUTON_OK_RECHERCHE}    Bouton OK (lancer la recherche)
    Journaliser Etape    Recherche lancée.

Compter Dossiers A Traiter
    [Documentation]    Détermine dynamiquement le nombre de dossiers renvoyés par la recherche, en
    ...                augmentant si possible le nombre de lignes par page (pour tout avoir sur une
    ...                seule page) puis en comptant les lignes du tableau. À appeler juste après
    ...                "Valider La Recherche" et avant d'ouvrir le premier dossier. Retourne 0 si
    ...                aucun dossier ne correspond aux filtres.
    ${select_present}=    Run Keyword And Return Status
    ...    Wait Until Element Is Visible    ${SELECT_LIGNES_PAR_PAGE}    timeout=3s
    IF    ${select_present}
        Select From List By Label    ${SELECT_LIGNES_PAR_PAGE}    ${LIGNES_PAR_PAGE_MAX}
        Sleep    1s
    ELSE
        Journaliser Etape    Sélecteur "lignes par page" introuvable — comptage sur la page par défaut uniquement.    niveau=WARN
    END

    ${total}=    Get Element Count    ${DOSSIER_TOUTES_LIGNES}
    Journaliser Etape    📊 Nombre de dossiers détectés pour ce filtre : ${total}

    IF    ${total} >= ${LIGNES_PAR_PAGE_MAX}
        Journaliser Etape    Le nombre de dossiers (${total}) atteint la limite d'affichage par page (${LIGNES_PAR_PAGE_MAX}) — il pourrait y en avoir davantage. Vérifier manuellement si besoin.    niveau=WARN
    END

    RETURN    ${total}

Cliquer Sur Le Dossier Du Client
    [Documentation]    Clique sur la ligne du tableau correspondant au client (par MSISDN ou autre valeur unique).
    ...                Si aucune valeur n'est fournie, clique sur la première ligne de résultat.
    [Arguments]    ${valeur}=${EMPTY}
    IF    '${valeur}' != '${EMPTY}'
        ${locator}=    Replace String    ${DOSSIER_LIGNE_PAR_VALEUR}    {valeur}    ${valeur}
    ELSE
        ${locator}=    Set Variable    ${DOSSIER_PREMIERE_LIGNE}
    END
    Wait Until Element Is Visible    ${locator}    timeout=${TIMEOUT}
    Cliquer Et Journaliser    ${locator}    Ligne dossier (critère: "${valeur}")
    Journaliser Etape    Dossier client ouvert (critère: "${valeur}").

Logger Le Msisdn Du Dossier
    [Documentation]    Lit le MSISDN affiché sur la fiche et le journalise, pour identifier
    ...                facilement à quel numéro correspond chaque bloc de logs de traitement.
    ...                Deux mises en page possibles selon le type de dossier :
    ...                - Inscription : écran de détail avec label/value (ancien comportement).
    ...                - Modification : pas d'écran de détail intermédiaire, le MSISDN est dans
    ...                  la cellule du tableau d'en-tête (colonne "MSISDN"), via
    ...                  ${ECRAN_MSISDN_MODIFICATION} (déjà présent dans variables.robot).
    ${detail_present}=    Run Keyword And Return Status
    ...    Wait Until Element Is Visible    ${ECRAN_MSISDN}    timeout=3s
    IF    ${detail_present}
        ${msisdn}=    Get Text    ${ECRAN_MSISDN}
    ELSE
        Wait Until Element Is Visible    ${ECRAN_MSISDN_MODIFICATION}    timeout=${TIMEOUT}
        ${msisdn}=    Get Text    ${ECRAN_MSISDN_MODIFICATION}
    END
    ${msisdn}=    Strip String    ${msisdn}
    Journaliser Etape    ${\n}========== TRAITEMENT DU DOSSIER — MSISDN : ${msisdn} ==========
    RETURN    ${msisdn}

Capturer Preuve
    [Documentation]    Prend une capture d'écran horodatée dans le dossier results.
    [Arguments]    ${nom_fichier}=preuve
    ${ts}=    Get Current Date    result_format=%Y%m%d_%H%M%S
    Capture Page Screenshot    ${DOWNLOAD_DIR}${/}${nom_fichier}_${ts}.png

Capturer Preuve Erreur
    [Documentation]    Prend une capture d'écran du dossier en erreur (non validé) et l'enregistre
    ...                dans le dossier results/error, nommée "{msisdn}_{AAAAMMJJ}.png". La date
    ...                dans le nom permet au script de rapport quotidien de savoir quelles
    ...                captures appartiennent à quel jour sans dépendre du mtime du fichier (qui
    ...                peut changer si les fichiers sont copiés/déplacés). Écrase seulement une
    ...                éventuelle capture précédente du MÊME dossier LE MÊME JOUR (ex: dossier
    ...                retraité plusieurs fois dans la journée) — les captures des jours
    ...                précédents pour ce MSISDN restent intactes.
    [Arguments]    ${msisdn}
    Create Directory    ${ERROR_DIR}
    ${date_du_jour}=    Get Current Date    result_format=%Y%m%d
    ${chemin}=    Set Variable    ${ERROR_DIR}${/}${msisdn}_${date_du_jour}.png
    Capture Page Screenshot    ${chemin}
    Journaliser Etape    Capture d'écran enregistrée : ${chemin}    niveau=WARN

Verifier Nationalite Eligible
    [Documentation]    Lit le champ "Nationalité" du dossier ouvert et retourne True si la CNI de
    ...                ce pays est acceptée pour l'inscription/modification (voir
    ...                PAYS_CNI_ACCEPTEE dans scripts/schemas.py — actuellement les pays CEDEAO
    ...                plus quelques ajouts métier KAABU), False sinon.
    ...                Deux mises en page possibles selon le type de dossier :
    ...                - Inscription : écran de détail avec label/value (ancien comportement).
    ...                - Modification : pas d'écran de détail intermédiaire, le dossier ouvre
    ...                  directement le panneau "Modification client" avec un ng-select
    ...                  Nationalité déjà pré-rempli. Locator confirmé via DOM réel (ancré sur
    ...                  le placeholder "Selectionner la nationalité").
    ${detail_present}=    Run Keyword And Return Status
    ...    Wait Until Element Is Visible    ${LOCATOR_NATIONALITE_DETAIL}    timeout=3s
    IF    ${detail_present}
        ${nationalite}=    Get Text    ${LOCATOR_NATIONALITE_DETAIL}
    ELSE
        Wait Until Element Is Visible    ${CHAMP_NATIONALITE}    timeout=${TIMEOUT}
        ${nationalite}=    Get Text    ${CHAMP_NATIONALITE}//span[contains(@class,'ng-value-label')]
    END
    ${nationalite}=    Strip String    ${nationalite}
    ${nationalite}=    Convert To Upper Case    ${nationalite}
    Journaliser Etape    Nationalité détectée : ${nationalite}
    ${est_eligible}=    Nationalite Est Eligible    ${nationalite}
    RETURN    ${est_eligible}

Aller Au Dossier Suivant
    [Documentation]    Clique sur le bouton "Dossier suivant" pour passer au dossier suivant
    ...                (utilisé notamment quand la pièce d'identité n'est pas éligible).
    Fermer Popup Confirmation Si Present
    Wait Until Element Is Visible
    ...    xpath://div[contains(@class,'barre_suivante')][.//span[contains(text(),'Dossier suivant')]]
    ...    timeout=${TIMEOUT}
    Cliquer Et Journaliser
    ...    xpath://div[contains(@class,'barre_suivante')][.//span[contains(text(),'Dossier suivant')]]
    ...    Bouton Dossier suivant
    Sleep    1s    # laisser Angular re-render le nouveau dossier

Confirmer Fin De Liste Avec Retry
    [Documentation]    Appelée quand le MSISDN lu est identique au précédent — signe possible de
    ...                fin de liste, mais peut aussi être un FAUX positif dû à un rendu Angular pas
    ...                encore à jour juste après le clic "Dossier suivant" (la page affiche encore
    ...                brièvement l'ancien dossier). Avant de conclure à une vraie fin de liste,
    ...                retente jusqu'à ${max_tentatives} fois : pause, nouveau clic "Dossier
    ...                suivant", relecture du MSISDN. Dès que le MSISDN change, la reprise est
    ...                considérée normale. Si le MSISDN reste identique après ${max_tentatives}
    ...                tentatives, la fin de liste est confirmée.
    ...                RETURN : ${fin_de_liste} (booléen), ${msisdn} (dernier MSISDN lu).
    [Arguments]    ${msisdn_precedent}    ${max_tentatives}=3
    FOR    ${tentative}    IN RANGE    1    ${max_tentatives} + 1
        Journaliser Etape
        ...    ⚠️ MSISDN identique au précédent (${msisdn_precedent}) — tentative ${tentative}/${max_tentatives} avant de conclure à la fin de liste.
        ...    niveau=WARN
        Sleep    1s
        Aller Au Dossier Suivant
        ${msisdn}=    Logger Le Msisdn Du Dossier
        IF    '${msisdn}' != '${msisdn_precedent}'
            Journaliser Etape
            ...    ✅ Nouveau dossier détecté (MSISDN : ${msisdn}) après ${tentative} tentative(s) — reprise normale, ce n'était pas la fin de liste.
            RETURN    ${False}    ${msisdn}
        END
    END
    Journaliser Etape
    ...    Fin de liste confirmée après ${max_tentatives} tentatives infructueuses (MSISDN toujours identique : ${msisdn_precedent}).
    ...    niveau=WARN
    RETURN    ${True}    ${msisdn_precedent}

Traiter Dossier Kaabu
    [Documentation]    Point d'entrée du traitement d'un dossier : vérifie la nationalité de la
    ...                pièce d'identité. Si son pays n'est pas éligible (CNI non acceptée), passe
    ...                au dossier suivant et revérifie, et ainsi de suite, jusqu'à trouver un
    ...                dossier éligible (auquel cas il faut lancer l'OCR) ou jusqu'à épuiser
    ...                ${max_dossiers} tentatives (sécurité anti-boucle-infinie, ex: fin de liste).
    ...                Retourne True si un dossier éligible a été trouvé et doit être traité,
    ...                False si aucun dossier éligible n'a été trouvé dans la limite fixée.
    [Arguments]    ${max_dossiers}=20
    FOR    ${i}    IN RANGE    1    ${max_dossiers} + 1
        ${est_eligible}=    Verifier Nationalite Eligible
        IF    ${est_eligible}
            Journaliser Etape    Dossier éligible trouvé après ${i} dossier(s) examiné(s) — traitement OCR.
            RETURN    ${True}
        END
        Journaliser Etape    Dossier ${i}/${max_dossiers} ignoré : pièce d'identité non éligible (pays non accepté) — passage au suivant.
        Aller Au Dossier Suivant
    END
    Journaliser Etape    Aucun dossier éligible trouvé après ${max_dossiers} tentatives.    niveau=WARN
    RETURN    ${False}

Valider Le Dossier
    [Documentation]    Clique sur le bouton final "Valider" du dossier, après vérification OCR
    ...                et validation des pièces jointes. Ferme ensuite le popup de confirmation
    ...                SweetAlert2 qui apparaît après validation (sinon il reste au premier plan
    ...                et intercepte le prochain clic, ex: "Dossier suivant").
    Wait Until Element Is Visible
    ...    xpath://button[contains(@class,'valider')]
    ...    timeout=${TIMEOUT}
    Cliquer Et Journaliser
    ...    xpath://button[contains(@class,'valider')]
    ...    Bouton Valider (dossier)
    Journaliser Etape    Dossier validé.
    Fermer Popup Confirmation Si Present

Traiter Dossier Modification
    [Documentation]    Équivalent de "Traiter Dossier Kaabu" pour le cas d'usage "Modification" :
    ...                vérifie la nationalité de la pièce d'identité du dossier ouvert, passe au
    ...                dossier suivant si son pays n'est pas éligible, et ainsi de suite jusqu'à
    ...                trouver un dossier éligible (ou épuiser ${max_dossiers} tentatives,
    ...                sécurité anti-boucle-infinie). Retourne un couple (trouve, msisdn) :
    ...                - trouve=True et le MSISDN du dossier éligible trouvé, prêt à traiter ;
    ...                - trouve=False et msisdn=${EMPTY} si aucun dossier éligible n'a été trouvé.
    [Arguments]    ${max_dossiers}=20
    FOR    ${i}    IN RANGE    1    ${max_dossiers} + 1
        ${est_eligible}=    Verifier Nationalite Eligible
        IF    ${est_eligible}
            ${msisdn}=    Logger Le Msisdn Du Dossier
            Journaliser Etape    Dossier éligible trouvé après ${i} dossier(s) examiné(s) — traitement OCR.
            RETURN    ${True}    ${msisdn}
        END
        Journaliser Etape    Dossier ${i}/${max_dossiers} ignoré : pièce d'identité non éligible (pays non accepté) — passage au suivant.
        Aller Au Dossier Suivant
    END
    Journaliser Etape    Aucun dossier éligible trouvé après ${max_dossiers} tentatives.    niveau=WARN
    RETURN    ${False}    ${EMPTY}

Confirmer Validation Dossier
    [Documentation]    Clique sur le bouton "Valider" du popup de confirmation "Modification
    ...                client OM" qui apparaît après le premier clic sur "Valider" (flux
    ...                Modification : validation en deux temps). Locator confirmé via DOM réel :
    ...                classe "btn-orange" + "ng-star-inserted" (élément inséré dynamiquement
    ...                par Angular, donc n'existe dans le DOM que popup ouvert) — à distinguer du
    ...                bouton principal du dossier qui a la classe "valider" (minuscule).
    ${bouton_popup}=    Set Variable
    ...    xpath=//button[contains(@class,'btn-orange') and normalize-space(.)='Valider']
    Wait Until Element Is Visible    ${bouton_popup}    timeout=${TIMEOUT}
    Cliquer Et Journaliser Avec Retry
    ...    ${bouton_popup}
    ...    Bouton confirmation (2e Valider — popup "Modification client OM")
    Wait Until Page Does Not Contain Element    ${bouton_popup}    timeout=${TIMEOUT}
    Journaliser Etape    Validation confirmée (2e clic).

Fermer Popup Confirmation Si Present
    [Documentation]    Attend la fermeture du popup SweetAlert2 (confirmation/succès) s'il apparaît.
    ...                Ce popup se ferme automatiquement après quelques secondes (timer interne) :
    ...                on se contente donc d'attendre sa disparition, sans cliquer dessus (un clic
    ...                trop tôt pendant son animation d'ouverture provoque un
    ...                ElementNotInteractableException). Si, exceptionnellement, il ne se ferme pas
    ...                tout seul avant ${TIMEOUT}, on clique alors sur son bouton de confirmation en
    ...                secours (avec retry, pour tolérer une éventuelle non-interactivité passagère).
    ${popup_present}=    Run Keyword And Return Status
    ...    Wait Until Element Is Visible    xpath://div[contains(@class,'swal2-container')]    timeout=5s
    IF    ${popup_present}
        Journaliser Etape    Popup de confirmation détecté — attente de sa fermeture automatique.
        ${ferme_automatiquement}=    Run Keyword And Return Status
        ...    Wait Until Element Is Not Visible
        ...    xpath://div[contains(@class,'swal2-container')]
        ...    timeout=${TIMEOUT}
        IF    ${ferme_automatiquement}
            Journaliser Etape    Popup fermé automatiquement.
        ELSE
            Journaliser Etape    ⚠️ Popup toujours présent après ${TIMEOUT} — clic de secours sur le bouton de confirmation.    niveau=WARN
            Cliquer Et Journaliser Avec Retry    xpath://button[contains(@class,'swal2-confirm')]    Bouton confirmation popup (swal2 — secours)
            Wait Until Element Is Not Visible
            ...    xpath://div[contains(@class,'swal2-container')]
            ...    timeout=${TIMEOUT}
        END
    END

Fermer Le Navigateur Kaabu
    [Documentation]    Ferme proprement le navigateur.
    Journaliser Etape    Fin de session — fermeture du navigateur.
    Close All Browsers