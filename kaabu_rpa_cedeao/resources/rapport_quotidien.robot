*** Settings ***
Documentation    Génère le rapport quotidien d'exécution (à partir de journal.jsonl) et l'envoie
...              par email via Outlook (Outlook Web / OWA, automatisation Selenium), avec en
...              pièces jointes le CSV complet et, s'il y en a, le zip des captures d'écran des
...              dossiers en erreur.
Library          SeleniumLibrary
Library          OperatingSystem
Library          Process
Library          Collections
Resource         variables.robot
Resource         keywords.robot


*** Keywords ***
Generer Donnees Rapport Quotidien
    [Documentation]    Exécute le script Python qui lit journal.jsonl (et les captures d'erreur
    ...                du jour) et produit : le résumé de la journée, le CSV complet, le zip des
    ...                captures d'erreur (si besoin) et le corps HTML de l'email. Retourne le
    ...                dictionnaire JSON résultant. ${date} est optionnelle, au format
    ...                AAAA-MM-JJ ; par défaut, la date du jour est utilisée.
    [Arguments]    ${date}=${EMPTY}
    IF    '${date}' != '${EMPTY}'
        ${result}=    Run Process    python    ${RAPPORT_QUOTIDIEN_SCRIPT}    ${date}
        ...    env:PYTHONIOENCODING=utf-8    output_encoding=UTF-8
    ELSE
        ${result}=    Run Process    python    ${RAPPORT_QUOTIDIEN_SCRIPT}
        ...    env:PYTHONIOENCODING=utf-8    output_encoding=UTF-8
    END

    ${stdout_vide}=    Run Keyword And Return Status    Should Be Empty    ${result.stdout}
    IF    ${stdout_vide}
        Journaliser Erreur Et Echouer    Le script de génération du rapport n'a rien renvoyé. STDERR: ${result.stderr}
    END

    ${donnees}=    Evaluate    json.loads($result.stdout)    json
    ${en_erreur}=    Run Keyword And Return Status    Dictionary Should Contain Key    ${donnees}    erreur
    IF    ${en_erreur}
        ${message_erreur}=    Get From Dictionary    ${donnees}    erreur
        Journaliser Erreur Et Echouer    Échec de génération du rapport quotidien : ${message_erreur}
    END

    RETURN    ${donnees}

Ouvrir Outlook Et Se Connecter Pour Rapport
    [Documentation]    Ouvre un Chrome dédié et se connecte à Outlook Web (OWA) avec le compte
    ...                RPA, pour l'envoi du rapport quotidien (session indépendante du navigateur
    ...                KAABU). Fonctionne aussi bien pour un compte Microsoft 365 professionnel
    ...                (Orange-Sonatel) que pour un compte outlook.com personnel — l'URL de
    ...                connexion est paramétrable via ${OUTLOOK_URL}.
    ${options}=    Evaluate
    ...    __import__('selenium.webdriver', fromlist=['ChromeOptions']).ChromeOptions()
    ...    modules=selenium.webdriver
    Evaluate    $options.add_argument("--disable-blink-features=AutomationControlled")    modules=selenium.webdriver
    Evaluate    $options.add_argument("--no-sandbox")    modules=selenium.webdriver
    Evaluate    $options.add_argument("--disable-dev-shm-usage")    modules=selenium.webdriver

    Create Webdriver    Chrome    options=${options}
    Go To    ${OUTLOOK_URL}
    Maximize Browser Window
    Sleep    3s

    # Formulaire de connexion (ADFS / page fédérée) : nom d'utilisateur et mot de passe sont
    # sur la MÊME page (contrairement au flux Microsoft grand public en 2 étapes), confirmé via
    # inspection DOM réelle : <input id="username" name="username" ...>,
    # <input id="password" name="password" type="password" ...>.
    Wait Until Element Is Visible    id:username    timeout=15s
    ${outlook_email}=    Get Environment Variable    OUTLOOK_EMAIL
    ${outlook_password}=    Get Environment Variable    OUTLOOK_PASSWORD
    Input Text    id:username    ${outlook_email}
    Input Text    id:password    ${outlook_password}
    Click Element
    ...    xpath://span[@class='signinTxt'] | //*[@id='submitButton'] | //input[@type='submit'] | //button[contains(.,'Connexion') or contains(.,'Sign in')]
    Sleep    4s

    # Étape 3 : popup "Rester connecté ?" (facultative selon la config du compte/tenant)
    ${popup_reste_connecte}=    Run Keyword And Return Status
    ...    Wait Until Element Is Visible
    ...    xpath=//input[@type='submit' and (@value='Oui' or @value='Yes')]
    ...    timeout=8s
    IF    ${popup_reste_connecte}
        Click Element    xpath=//input[@type='submit' and (@value='Oui' or @value='Yes')]
    END
    Sleep    5s

    Wait Until Element Is Visible
    ...    xpath://span[contains(@class,'o365buttonLabel')][normalize-space(text())='Nouveau' or normalize-space(text())='New'] | //button[contains(@aria-label,'Nouveau message') or contains(@aria-label,'New mail') or contains(@aria-label,'New message')]
    ...    timeout=30s
    Journaliser Etape    Connexion Outlook réussie (compte RPA : ${outlook_email}).

Attendre Fin Upload Piece Jointe
    [Documentation]    Attend la fin de l'upload d'UNE pièce jointe précise (identifiée par son
    ...                nom de fichier), en vérifiant l'attribut aria-busy du conteneur de
    ...                progression propre à cette pièce jointe (confirmé via DOM réel :
    ...                <div role="marquee" aria-busy="false"> une fois l'upload terminé).
    ...                Scope volontairement limité à CETTE pièce jointe, pour ne pas se fier par
    ...                erreur à l'état d'une autre pièce jointe déjà terminée.
    [Arguments]    ${chemin}    ${timeout}=120s
    ${dossier}    ${nom_fichier}=    Split Path    ${chemin}
    ${item_xpath}=    Set Variable
    ...    //a[starts-with(@aria-label, '${nom_fichier}')]/ancestor::div[contains(@class,'_ay_q')][1]
    ${locator_item}=    Set Variable    xpath=${item_xpath}
    Wait Until Element Is Visible    ${locator_item}    timeout=15s

    ${locator_marquee}=    Set Variable    xpath=(${item_xpath})//div[@role='marquee']
    Wait Until Keyword Succeeds    ${timeout}    1s
    ...    Marquee Upload Doit Etre Termine    ${locator_marquee}
    Journaliser Etape    Upload de "${nom_fichier}" terminé.

Marquee Upload Doit Etre Termine
    [Documentation]    Échoue uniquement si aria-busy vaut explicitement "true". Un attribut
    ...                absent (None) ou valant "false" est considéré comme upload terminé —
    ...                certains uploads rapides (petits fichiers) se terminent avant même le
    ...                premier contrôle, et l'attribut est alors retiré plutôt que mis à false.
    [Arguments]    ${locator_marquee}
    ${busy}=    Get Element Attribute    ${locator_marquee}    aria-busy
    Should Not Be Equal    ${busy}    true    msg=Upload encore en cours (aria-busy=true)

Composer Et Envoyer Rapport Quotidien
    [Documentation]    Compose un email au format HTML (corps riche : tableaux, couleurs) avec
    ...                les pièces jointes données, puis l'envoie, via Outlook Web (OWA).
    ...                ${pieces_jointes} est une liste de chemins de fichiers (le zip des
    ...                captures peut être absent selon les jours, filtrer les valeurs vides avant
    ...                l'appel).
    [Arguments]    ${destinataire}    ${objet}    ${html_body}    ${pieces_jointes}

    ${bouton_nouveau_message}=    Set Variable
    ...    xpath://span[contains(@class,'o365buttonLabel')][normalize-space(text())='Nouveau' or normalize-space(text())='New'] | //button[contains(@aria-label,'Nouveau message') or contains(@aria-label,'New mail') or contains(@aria-label,'New message')]
    Wait Until Element Is Visible    ${bouton_nouveau_message}    timeout=20s
    Click Element    ${bouton_nouveau_message}
    Sleep    4s

    # Destinataire ("À") — confirmé via DOM réel : <input ... aria-label="À" role="textbox" ...>
    ${champ_destinataire}=    Set Variable    xpath://input[@aria-label='À']
    Wait Until Element Is Visible    ${champ_destinataire}    timeout=10s
    Click Element    ${champ_destinataire}
    Input Text    ${champ_destinataire}    ${destinataire}
    Sleep    1s
    Press Keys    ${champ_destinataire}    TAB
    Sleep    1s

    # Objet — confirmé via DOM réel : <input ... aria-label="Objet," placeholder="Ajouter un objet" ...>
    ${champ_objet}=    Set Variable    xpath://input[@aria-label='Objet,'] | //input[contains(@aria-label,'Objet')]
    Wait Until Element Is Visible    ${champ_objet}    timeout=10s
    Click Element    ${champ_objet}
    Input Text    ${champ_objet}    ${objet}
    Sleep    1s

    # Corps du message — zone contenteditable (contient un <p><br></p> vide au départ). Inséré en
    # HTML (et non en texte brut) pour conserver la mise en forme (tableaux, puces de couleur) du
    # rapport généré par le script Python.
    ${locator_corps}=    Set Variable
    ...    xpath://div[@role='textbox'][contains(@aria-label,'Corps') or contains(@aria-label,'message')] | //div[@contenteditable='true'][.//p]
    Wait Until Element Is Visible    ${locator_corps}    timeout=10s
    Click Element    ${locator_corps}
    Sleep    1s
    Execute Javascript
    ...    var el = document.activeElement; if(!el || el.getAttribute('contenteditable') !== 'true'){ el = document.querySelector('div[contenteditable="true"]'); } if(el){ el.focus(); document.execCommand('insertHTML', false, arguments[0]); }
    ...    ARGUMENTS    ${html_body}
    Sleep    1s

    # Pièces jointes — confirmé via capture d'écran : bouton texte "Joindre" en haut de la fenêtre
    # de composition. Comme pour les autres interfaces OWA, il faut rouvrir ce menu avant CHAQUE
    # fichier. Après chaque ajout, on attend la fin de l'upload de CETTE pièce jointe précise
    # (aria-busy="false" sur son propre conteneur de progression) plutôt qu'un délai fixe global.
    FOR    ${chemin}    IN    @{pieces_jointes}
        Journaliser Etape    Ajout de la pièce jointe : ${chemin}
        Click Element
        ...    xpath://span[normalize-space(text())='Joindre'] | //button[contains(@aria-label,'Joindre') or contains(@aria-label,'Attach')]
        Sleep    1s
        ${menu_parcourir}=    Run Keyword And Return Status
        ...    Wait Until Element Is Visible
        ...    xpath://*[contains(text(),'Parcourir cet ordinateur') or contains(text(),'Browse this computer')]
        ...    timeout=3s
        IF    ${menu_parcourir}
            Click Element
            ...    xpath://*[contains(text(),'Parcourir cet ordinateur') or contains(text(),'Browse this computer')]
            Sleep    1s
        END
        ${input_file}=    Get WebElement    xpath=(//input[@type='file'])[last()]
        Call Method    ${input_file}    send_keys    ${chemin}

        Attendre Fin Upload Piece Jointe    ${chemin}
    END

    Journaliser Etape    Toutes les pièces jointes sont chargées.

    # Envoi — confirmé via capture d'écran : bouton "Envoyer" (barre du haut ET bouton bleu en
    # bas de la fenêtre de composition). On cible le premier trouvé, peu importe lequel.
    Journaliser Etape    Envoi du rapport quotidien à ${destinataire}...
    Click Element    xpath=(//span[normalize-space(text())='Envoyer'] | //button[contains(.,'Envoyer') or contains(@aria-label,'Send')])[1]
    Sleep    5s
    Journaliser Etape    Rapport quotidien envoyé à ${destinataire}.

Envoyer Rapport Quotidien Par Email
    [Documentation]    Point d'entrée complet : génère les données du rapport du jour, ouvre
    ...                Outlook Web, compose et envoie l'email avec pièces jointes, puis ferme le
    ...                navigateur. À exécuter une fois par jour, en toute fin de journée
    ...                d'exécution (ex : tâche planifiée après la dernière exécution KAABU).
    [Arguments]    ${date}=${EMPTY}
    ${donnees}=    Generer Donnees Rapport Quotidien    ${date}

    ${objet}=    Set Variable    ${OBJET_RAPPORT_QUOTIDIEN} — ${donnees}[date] (${donnees}[reussies]/${donnees}[total] réussis)

    ${pieces_jointes}=    Create List    ${donnees}[csv_path]
    ${zip_present}=    Run Keyword And Return Status
    ...    Should Not Be Equal    ${donnees}[zip_path]    ${None}
    IF    ${zip_present}
        Append To List    ${pieces_jointes}    ${donnees}[zip_path]
    END

    Ouvrir Outlook Et Se Connecter Pour Rapport
    Composer Et Envoyer Rapport Quotidien
    ...    ${OUTLOOK_DESTINATAIRE_RAPPORT}
    ...    ${objet}
    ...    ${donnees}[html_body]
    ...    ${pieces_jointes}
    Close Browser
