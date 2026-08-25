*** Variables ***
# --- Environnement ---
${URL}                  https://kaabu.orange-sonatel.com
${BROWSER}              chrome
${HEADLESS}             ${FALSE}
${TIMEOUT}              20s
${DELAI_DEMO}           0s
# ↑ Pause marquée après chaque clic, pour que le processus soit clairement visible pendant une démo.
#   Mettre à "0s" (ou commenter les "Sleep ${DELAI_DEMO}" dans keywords.robot) pour revenir à la
#   vitesse normale en exécution réelle/production.
${DOWNLOAD_DIR}         ${CURDIR}${/}..${/}results
${LOGS_DIR}                ${CURDIR}${/}..${/}results${/}logs
# ↑ Un fichier journal différent est créé chaque jour dans ce dossier : logs/AAAA-MM-JJ.log
#   (voir le keyword "Initialiser Journal" dans keywords.robot), pour éviter un journal.log unique
#   qui grossit indéfiniment.
${FICHIER_JOURNAL_JSON}    ${CURDIR}${/}..${/}results${/}journal.jsonl

# --- Identifiants : PAS lus ici (la section Variables est évaluée trop tôt, avant que le
#     .env ne soit chargé). Ils sont récupérés au moment de l'appel via "Get Environment
#     Variable" dans "Se Connecter Sur Kaabu" et "Ouvrir Outlook Et Se Connecter Pour Rapport"
#     (resources/keywords.robot et resources/rapport_quotidien.robot), après que le Suite
#     Setup de chaque suite ait appelé "Charger Env Dotenv" en tout premier. Voir .env.example.

# --- Locators : page de connexion (confirmés via inspection DOM) ---
${LOGIN_USERNAME_FIELD}     name:username
${LOGIN_PASSWORD_FIELD}     name:password
${LOGIN_SUBMIT_BUTTON}      css:button.submit-login
${LOGIN_ERROR_MESSAGE}      css:.alert-danger

# --- Locators : page "Liste des dossiers" ---
${WELCOME_MARKER}           xpath://*[contains(text(),'Liste des dossiers')]

# Valeurs de filtre demandées
${FILTRE_ETAT_VALEUR}       Créée
${FILTRE_TYPE_VALEUR}       Subscription Orange Money

# Ciblage par proximité du libellé texte (plus robuste qu'un index ou qu'une classe devinée)
${NGSELECT_ETAT_DOSSIER}    xpath=//*[contains(text(),'Etat du dossier')]/following::ng-select[1]
${NGSELECT_TYPE_DOSSIER}    xpath=//*[contains(text(),'Type de dossier')]/following::ng-select[1]

${NGSELECT_OPTION_BY_TEXT}  xpath=//div[contains(@class,'ng-option')]//span[contains(@class,'ng-option-label') and normalize-space(text())='{option}']

# Locators génériques réutilisables pour tout ng-select de la page
${NGSELECT_CONTAINER}       xpath=(//div[contains(@class,'ng-select-container')])
${NGSELECT_OPTION_BY_TEXT}  xpath=//div[contains(@class,'ng-option')]//span[contains(@class,'ng-option-label') and normalize-space(text())='{option}']

# --- Locators : ligne de résultat / dossier (TODO à confirmer) ---
# À inspecter : une ligne du tableau "Liste des dossiers" une fois filtrée,
# et le bouton "Valider" vu dans la vidéo initiale.
${BOUTON_OK_RECHERCHE}      css:button.button_recherche

# --- Locators : tableau de résultats ---
# Cible une ligne <tr> du tableau .table_demande contenant une valeur donnée (ex: le MSISDN)
${DOSSIER_LIGNE_PAR_VALEUR}     xpath=//table[contains(@class,'table_demande')]//tr[td[contains(normalize-space(.),'{valeur}')]]
${DOSSIER_PREMIERE_LIGNE}       xpath=(//table[contains(@class,'table_demande')]//tbody//tr)[1]
${DOSSIER_TOUTES_LIGNES}        xpath=//table[contains(@class,'table_demande')]//tbody//tr

# --- Comptage du nombre de dossiers à traiter (avant lancement de la boucle) ---
# Locator confirmé par inspection DOM : <select> natif en bas à gauche du tableau,
# options réelles : 10, 25, 50, 100, 250, 500, 1000, 5000 (pas d'attribut "value" explicite,
# donc value == label texte).
${SELECT_LIGNES_PAR_PAGE}       xpath=//*[contains(text(),'ligne par Page')]/following::select[1]
${LIGNES_PAR_PAGE_MAX}          5000
# ↑ Plus grande option disponible, pour être quasi certain d'afficher tous les dossiers du
#   filtre sur une seule page avant de les compter.

${ECRAN_MSISDN}    xpath://label[contains(@class,'libelle')][contains(text(),'MSISDN')]/following-sibling::label[contains(@class,'value')][1]

${FICHIER_RAPPORT}    ${CURDIR}${/}..${/}results${/}rapport_execution.txt
${ERROR_DIR}    ${CURDIR}${/}..${/}results${/}error

# --- Rapport quotidien par email ---
${RAPPORT_QUOTIDIEN_SCRIPT}      ${CURDIR}${/}..${/}scripts${/}generer_rapport_quotidien.py
${OUTLOOK_URL}                   https://webmail.orange-sonatel.com
# ↑ Pour un compte outlook.com / hotmail.com personnel (hors compte professionnel Microsoft 365),
#   utiliser plutôt : https://outlook.live.com/mail/
# --- Compte Outlook (OWA) : PAS lu ici, voir remarque "Identifiants" plus haut ---
# ↑ Si le compte a la double authentification (MFA) activée, prévoir soit un mot de passe
#   d'application (Sécurité > Mots de passe d'application), soit exclure ce compte du MFA côté
#   politique Azure AD, sans quoi Selenium restera bloqué sur l'étape de validation MFA.
${OUTLOOK_DESTINATAIRE_RAPPORT}    AbdoulWahab.Sall@orange-sonatel.com
${OBJET_RAPPORT_QUOTIDIEN}       Rapport quotidien — RPA KAABU


${FILTRE_TYPE_MODIFICATION_VALEUR}    Modification info compte Orange Money
${ECRAN_MSISDN_MODIFICATION}    xpath=//tr[td[normalize-space(text())='MSISDN']]/following-sibling::tr[1]/td[count(//tr[td[normalize-space(text())='MSISDN']]/td[normalize-space(text())='MSISDN']/preceding-sibling::td)+1]
${VALEUR_TYPE_PIECE_FIXE}       CNI SN
# ↑ Conservée comme valeur par défaut/repli (CNI sénégalaise). Depuis l'ajout du support
#   CEDEAO, la valeur réellement injectée est déterminée dynamiquement à partir de
#   "document_type"/"country" de l'OCR — voir "Determiner Valeur Type Piece" dans
#   report_modification_client.robot. Les deux libellés ci-dessous sont ceux CONFIRMÉS sur
#   le DOM réel du dropdown Kaabu (ng-select "typePiece", inspection du 24/08) — attention,
#   l'option CEDEAO contient une coquille ("CDEAO", pas "CEDEAO") et un suffixe "OMVS" côté
#   Kaabu, et "PASSEPORT" est tout en majuscules : on reprend le texte exact tel quel.
${VALEUR_TYPE_PIECE_CEDEAO}     CNI CDEAO OMVS
${VALEUR_TYPE_PIECE_PASSEPORT}  PASSEPORT

${CHAMP_NOM}                    xpath=(//input[@name='nom'])[1]
${CHAMP_PRENOM}                 xpath=(//input[@name='prenom'])[1]
${CHAMP_NUMERO_PIECE}           xpath=(//input[@name='numeroPiece'])[1]
${CHAMP_TYPE_PIECE}             xpath=//ng-select[@name='typePiece']

# Confirmés via DOM réel (14/08) :
${CHAMP_MOTIF_DEMANDE}      xpath=//td[contains(@class,'box')]
${CHAMP_ADRESSE}            xpath=(//input[@name='adresse'])[1]
${CASE_TOUT_COCHER}         xpath=//input[@id='flexCheckDefault1']
# Repris par convention (label-proximité / name sur ng-select comme typePiece et nationalite) —
# à confirmer si le premier run échoue dessus :
${CHAMP_DATE_NAISSANCE}     xpath=//label[contains(text(),'naissance')]/following::input[contains(@class,'input_date_recherche')][1]
${CHAMP_SEXE}                xpath=//div[contains(@class,'ng-placeholder') and contains(text(),'sexe')]/ancestor::div[contains(@class,'ng-select-container')][1]
${CHAMP_NATIONALITE}         xpath=//div[contains(@class,'ng-placeholder') and contains(text(),'nationalité')]/ancestor::div[contains(@class,'ng-select-container')][1]
${LOCATOR_NATIONALITE_DETAIL}    xpath=//label[contains(@class,'libelle')][contains(text(),'Nationalité')]/following-sibling::label[contains(@class,'value')][1]
${CHAMP_COMMUNE}             xpath=(//input[@name='commune'])[1]

# Panneau "Client sur Tango" (référence en lecture seule, à droite) — confirmé via DOM réel
# (17/08). ⚠️ Les deux panneaux partagent les mêmes attributs "name" : [1] = panneau éditable
# "Modification client" (gauche), [2] = panneau référence "Client sur Tango" (droite). Utilisés
# pour la détection "changement majeur" (comparaison OCR vs valeurs déjà enregistrées).
${CHAMP_TANGO_NOM}              xpath=(//input[@name='nom'])[2]
${CHAMP_TANGO_PRENOM}           xpath=(//input[@name='prenom'])[2]
${CHAMP_TANGO_NUMERO_PIECE}     xpath=(//input[@name='numeroPiece'])[2]
${CHAMP_TANGO_DATE_NAISSANCE}   xpath=(//label[contains(text(),'naissance')])[2]/following::input[contains(@class,'input_date_recherche')][1]

${CASE_A_COCHER_DE_LA_LIGNE_TEMPLATE}    xpath=({champ})/ancestor::div[contains(@class,'k-row')][1]//input[@type='checkbox']
${MODIF_NATIONALITE_VALEUR_TEXTE}    xpath=//ng-select[@name='nationalite']//span[contains(@class,'ng-value-label')]
${CHAMP_DATE_DELIVRANCE}    xpath=//label[contains(text(),'Date délivrance')]/following::input[contains(@class,'input_date_recherche')][1]
${CHAMP_DATE_EXPIRATION}    xpath=//label[contains(text(),'expiration')]/following::input[contains(@class,'input_date_recherche')][1]

${CALENDRIER_MOIS_HEADER}    xpath=//div[contains(@class,'calendar') and contains(@class,'left')]//th[contains(@class,'month')]
${CALENDRIER_BOUTON_PREV}    xpath=//div[contains(@class,'calendar') and contains(@class,'left')]//th[contains(@class,'prev')]
${CALENDRIER_BOUTON_NEXT}    xpath=//div[contains(@class,'calendar') and contains(@class,'left')]//th[contains(@class,'next')]
${CALENDRIER_JOUR_TEMPLATE}  xpath=//div[contains(@class,'calendar') and contains(@class,'left')]//td[contains(@class,'available') and not(contains(@class,'off'))]/span[text()='{jour}']