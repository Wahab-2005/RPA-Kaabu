*** Settings ***
Documentation    Envoie par email le rapport quotidien d'exécution du RPA KAABU (inscriptions +
...              modifications), généré à partir de results/journal.jsonl, via Outlook Web (OWA).
...              À exécuter une fois par jour, en fin de journée (ex : tâche planifiée Windows
...              Task Scheduler à 18h), après la ou les dernière(s) exécution(s) de
...              inscription_kaabu.robot / modification_kaabu.robot de la journée.
Resource         ../resources/variables.robot
Resource         ../resources/keywords.robot
Resource         ../resources/rapport_quotidien.robot
Suite Setup      Run Keywords    Charger Env Dotenv    AND    Initialiser Journal


*** Test Cases ***
Envoyer Le Rapport Quotidien Par Email
    [Documentation]    Génère le résumé du jour (total traités, réussites, échecs détaillés avec
    ...                distinction erreur métier / technique) et l'envoie par email avec le CSV
    ...                complet et les captures d'écran des dossiers en erreur en pièces jointes.
    [Tags]    rapport    email    quotidien
    Envoyer Rapport Quotidien Par Email
