#!/usr/bin/env python3
"""Teste l'accès à la boîte, hors de Docker et hors de l'API.

    python3 outils/tester_boite.py            vérifie l'accès et le libellé
    python3 outils/tester_boite.py --corps 2  montre le texte des N derniers

Quand la relève échoue, trois causes se ressemblent : des identifiants
refusés par le serveur, un conteneur qui tourne encore avec l'ancien `.env`, ou
un libellé qui ne porte pas le nom qu'on croit. Ce script ne teste que la
première, précisément pour éliminer les deux autres.

`--corps` sert à autre chose : régler le lecteur. Le format de ces courriels
ne nous appartient pas, et on ne peut pas l'analyser sans l'avoir vu. Le texte
affiché est celui que le lecteur voit, une fois le HTML retiré — donc
exactement ce sur quoi il échoue.

Ce script n'importe rien du projet et n'utilise que la bibliothèque standard.
C'est délibéré : il doit tourner quand l'API ne tourne pas, sur une machine où
aucune dépendance n'est installée, puisque tout vit d'ordinaire dans Docker.
Il lit le `.env` directement et n'affiche jamais le mot de passe.
"""

import email
import email.policy
import email.utils
import html
import imaplib
import re
import sys
import unicodedata
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent

# Recopiées de api/collecteurs/courriel.py, pour rester sans dépendance. Elles
# ne servent qu'à surligner ce que le lecteur reconnaîtrait : si elles
# divergent un jour, le diagnostic reste lisible.
GARES_CONNUES = ("nancy", "saint die", "st die", "luneville", "epinal",
                 "strasbourg", "metz")


def reglages() -> dict[str, str]:
    fichier = RACINE / ".env"
    if not fichier.exists():
        sys.exit("Pas de .env à la racine du dépôt.")

    valeurs = dict(re.findall(r"^(\w+)=(.*)$", fichier.read_text(), re.M))
    return {c: v.strip().strip("\"'") for c, v in valeurs.items()}


def main() -> int:
    conf = reglages()
    hote = conf.get("IMAP_HOTE", "")
    utilisateur = conf.get("IMAP_UTILISATEUR", "")
    secret = conf.get("IMAP_MOT_DE_PASSE", "")
    dossier = conf.get("IMAP_DOSSIER", "INBOX")

    if not (hote and utilisateur and secret):
        return sortir("IMAP_HOTE, IMAP_UTILISATEUR ou IMAP_MOT_DE_PASSE manque dans .env.")

    print(f"Serveur      : {hote}:{conf.get('IMAP_PORT', '993')}")
    print(f"Utilisateur  : {utilisateur}")
    print(f"Mot de passe : {len(secret)} caractères, "
          f"{'que des lettres minuscules' if re.fullmatch(r'[a-z]+', secret) else 'mélangé'}")
    print(f"Dossier visé : {dossier}\n")

    try:
        boite = imaplib.IMAP4_SSL(hote, int(conf.get("IMAP_PORT", 993)))
    except OSError as erreur:
        return sortir(f"Serveur injoignable : {erreur}")

    try:
        boite.login(utilisateur, secret)
    except imaplib.IMAP4.error as erreur:
        print(f"Connexion refusée : {erreur}\n")
        print("Trois causes, par ordre de fréquence :")
        print("  1. Ce n'est pas un mot de passe d'application, mais le mot de")
        print("     passe habituel du compte. Gmail refuse toujours celui-là.")
        print("  2. Le mot de passe d'application a été révoqué, ou appartient")
        print("     à un autre compte Google que celui indiqué ci-dessus.")
        print("  3. Une lettre est fausse. Le régénérer coûte moins cher que")
        print("     de le relire : myaccount.google.com/apppasswords")
        return 1

    print("Connexion acceptée.\n")

    statut, brut = boite.list()
    noms = []
    for ligne in brut or []:
        texte = ligne.decode(errors="replace") if isinstance(ligne, bytes) else str(ligne)
        nom = texte.rsplit(' "/" ', 1)[-1].strip().strip('"')
        if nom:
            noms.append(nom)

    print("Dossiers disponibles :")
    for nom in noms:
        marque = "  ←  celui du .env" if nom == dossier else ""
        print(f"  {nom}{marque}")

    if dossier not in noms:
        print(f"\nLe dossier « {dossier} » ne figure pas dans cette liste.")
        print("Sur Gmail, un libellé n'apparaît qu'une fois qu'il contient au")
        print("moins un message. Vérifie que le filtre a bien été appliqué aux")
        print("conversations existantes.")
        boite.logout()
        return 1

    statut, reponse = boite.select(f'"{dossier}"', readonly=True)
    if statut != "OK":
        boite.logout()
        return sortir(f"Dossier « {dossier} » illisible : {reponse}")

    statut, reponse = boite.search(None, "ALL")
    total = len((reponse[0] or b"").split())
    print(f"\n{total} message(s) dans « {dossier} ».")

    if total:
        statut, reponse = boite.search(None, "FROM", "sncf")
        print(f"{len((reponse[0] or b'').split())} venant d'un expéditeur "
              f"contenant « sncf ».")
    else:
        print("Le libellé est vide : le filtre Gmail n'a rien attrapé.")

    if "--corps" in sys.argv:
        rang = sys.argv.index("--corps")
        combien = int(sys.argv[rang + 1]) if len(sys.argv) > rang + 1 else 1
        montrer_corps(boite, combien, int(conf.get("IMAP_DEPUIS_JOURS", 30)))

    boite.logout()
    print("\nTout est en ordre côté boîte.")
    return 0


def en_texte(message) -> str:
    """Corps en texte, que le courriel soit en clair ou en HTML."""
    corps = message.get_body(preferencelist=("plain", "html"))
    if corps is None:
        return ""

    contenu = corps.get_content()
    if corps.get_content_subtype() == "html":
        contenu = re.sub(r"(?is)<(script|style).*?</\1>", " ", contenu)
        contenu = re.sub(r"(?i)<(br|/p|/div|/tr|/td)[^>]*>", "\n", contenu)
        contenu = re.sub(r"<[^>]+>", " ", contenu)
        contenu = html.unescape(contenu)
    return contenu


def aplatir(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte)
    sans_accent = "".join(c for c in decompose
                          if unicodedata.category(c) != "Mn").lower()
    sans_accent = re.sub(r"[‐-―-]", " ", sans_accent.replace(" ", " "))
    return re.sub(r"[ \t]+", " ", sans_accent)


def montrer_corps(boite: imaplib.IMAP4_SSL, combien: int, depuis_jours: int) -> None:
    """Affiche le texte des derniers courriels, tel que le lecteur le voit.

    On regarde la même fenêtre que l'API, et non les derniers de la boîte :
    l'ordre des numéros IMAP suit l'ordre d'arrivée dans le libellé, qui n'a
    rien à voir avec la date des courriels quand un filtre est appliqué
    rétroactivement. Sans ce filtre, on tombe sur des billets de 2022 pendant
    que l'API bute sur ceux de cette année.

    Seules les lignes portant une gare, une heure ou une date sont montrées :
    un courriel de confirmation fait plusieurs centaines de lignes de pied de
    page, et c'est le récapitulatif qu'on cherche.
    """
    import datetime as dt

    heure = re.compile(r"\b\d{1,2}\s*[h:]\s*\d{2}\b")
    date = re.compile(r"\b\d{1,2}\s+(?:janvier|fevrier|mars|avril|mai|juin|"
                      r"juillet|aout|septembre|octobre|novembre|decembre)\b"
                      r"|\b\d{1,2}/\d{1,2}/\d{4}\b")

    depuis = (dt.datetime.now() - dt.timedelta(days=depuis_jours)).strftime("%d-%b-%Y")
    statut, reponse = boite.search(None, "SINCE", depuis)
    numeros = (reponse[0] or b"").split()
    if not numeros:
        print(f"\nAucun courriel depuis {depuis} : on montre les derniers reçus.")
        statut, reponse = boite.search(None, "ALL")
        numeros = (reponse[0] or b"").split()

    # Trier sur l'en-tête Date, et non sur le numéro IMAP. Un libellé appliqué
    # rétroactivement range les courriels dans l'ordre où l'étiquette a été
    # posée, qui n'a rien à voir avec celui où ils sont arrivés.
    datees = []
    for numero in numeros:
        statut, donnees = boite.fetch(numero, "(BODY.PEEK[HEADER.FIELDS (DATE)])")
        quand = dt.datetime.min
        if statut == "OK" and donnees and isinstance(donnees[0], tuple):
            try:
                quand = email.utils.parsedate_to_datetime(
                    donnees[0][1].decode(errors="replace").partition(":")[2].strip()
                ).replace(tzinfo=None)
            except (TypeError, ValueError, IndexError):
                pass
        datees.append((quand, numero))

    numeros = [numero for _, numero in sorted(datees)][-combien:]

    for numero in numeros:
        statut, donnees = boite.fetch(numero, "(BODY.PEEK[])")
        if statut != "OK" or not donnees or not isinstance(donnees[0], tuple):
            continue

        message = email.message_from_bytes(donnees[0][1], policy=email.policy.default)
        sujet = str(message.get("Subject") or "")
        print("\n" + "=" * 72)
        print("Sujet :", sujet)
        print("Reçu  :", message.get("Date"))

        # Ce que le repli sur le sujet trouverait : deux gares et une date
        # suffisent, même sans horaire.
        plat = aplatir(sujet)
        vues = [g for g in GARES_CONNUES if g in plat]
        print(f"Sujet → gares : {', '.join(vues) or 'aucune'} ; "
              f"date : {'oui' if date.search(plat) else 'non'}")
        print("-" * 72)

        texte = aplatir(en_texte(message))
        vues, montrees = set(), 0
        for ligne in texte.splitlines():
            ligne = " ".join(ligne.split())
            if not ligne or ligne in vues:
                continue
            interessante = (heure.search(ligne) or date.search(ligne)
                            or any(g in ligne for g in GARES_CONNUES))
            if not interessante:
                continue
            vues.add(ligne)
            montrees += 1
            print(" ", ligne[:150])

        if montrees == 0:
            print("  (aucune ligne avec gare, heure ou date — corps peut-être")
            print("   entièrement en image, ou dans une pièce jointe)")


def sortir(message: str) -> int:
    print(message)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
