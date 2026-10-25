"""Les demandes : ce qu'un modèle veut changer, et l'accord de l'utilisateur
                                                              (ACC-1 à ACC-14)

Un modèle, que ce soit HAL dans l'appli ou un client MCP, ne change ni le
planning, ni les tâches, ni les absences. Il dépose une demande : une action
d'une liste fermée, ses paramètres, et son motif.

La demande est jouée tout de suite par la route du geste à la main, dans une
transaction annulée (ACC-3) : si la base ou la route refuse, rien n'est
déposé et le modèle lit le motif. Sinon elle attend l'accord. Accepter la
rejoue, pour de bon, par la même route, au nom de l'utilisateur, avec ses
droits (ACC-4). Le résumé montré à l'utilisateur est écrit ici, depuis les
paramètres et la base, jamais par le modèle (ACC-12).

Les routes sont importées au moment de servir : elles importent elles-mêmes
le module HAL, qui importe celui-ci.

Les gestes (ACT-1, ACT-2) : dans la conversation de l'appli, ce que
l'utilisateur demande à HAL ne l'attend pas. C'est une demande essayée de la
même façon, que le serveur accepte seul quelques secondes après la réponse,
sauf si l'utilisateur a touché « Annuler » entre-temps : l'annulation la
refuse. Rien n'est donc à défaire, comme pour les boutons de l'appli (ORB-6).
"""

import json
import logging
import threading
from collections.abc import Callable
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

import psycopg
from fastapi import HTTPException
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field, ValidationError, model_validator

from api import operation
from api.base import executer, lister, transaction_annulee, un_seul
from api.coach.clair import fuseau, jour_en_clair
from api.coach.outils import Outil, RefusOutil
from api.erreurs import message_lisible, refus_coach
from api.securite import Appelant

LOG = logging.getLogger(__name__)

# ACT-2 : l'appli montre « Annuler » cinq secondes ; le serveur attend un peu plus,
# le temps que le refus lui parvienne.
DELAI_GESTE_SECONDES = 8
# Les tests déclenchent les gestes eux-mêmes, sans minuteur qui court en même temps.
MINUTEUR_DES_GESTES = True

# Qui dépose : le client MCP et sa session, posés par le serveur MCP (MCP-10).
# Vides dans une course de HAL : la demande vient alors de HAL (ACC-2).
client_courant: ContextVar[str | None] = ContextVar("client_mcp", default=None)
session_courante: ContextVar[str | None] = ContextVar("session_mcp", default=None)


class DemandeImpossible(Exception):
    """Une demande que la base ou la route refusent, avec leur motif."""

    def __init__(self, code: str, motif: str):
        super().__init__(motif)
        self.code = code
        self.motif = motif


# ---------------------------------------------------------------------------
# Écrire en clair
# ---------------------------------------------------------------------------

def _instant(valeur: datetime | None) -> str:
    if valeur is None:
        return "maintenant"
    ici = valeur.astimezone(fuseau()) if valeur.tzinfo else valeur
    return f"{jour_en_clair(ici.date())} à {ici:%H:%M}"


def _jour(valeur: date | None) -> str:
    return jour_en_clair(valeur) if valeur else "aujourd'hui"


def _libelle_tache(id_tache: int | None) -> str:
    ligne = un_seul("SELECT libelle FROM tache WHERE id_tache = %(t)s", {"t": id_tache})
    return f"« {ligne['libelle']} »" if ligne else f"la tâche {id_tache}"


def _pseudo(id_utilisateur: int | None) -> str | None:
    if id_utilisateur is None:
        return None
    ligne = un_seul("SELECT pseudo FROM utilisateur WHERE id_utilisateur = %(u)s",
                    {"u": id_utilisateur})
    return ligne["pseudo"] if ligne else None


def _appelant(id_utilisateur: int) -> Appelant:
    ligne = un_seul("SELECT id_utilisateur, pseudo, role FROM utilisateur "
                    "WHERE id_utilisateur = %(u)s AND actif", {"u": id_utilisateur})
    if ligne is None:
        raise DemandeImpossible("compte_inactif", "Ce compte n'est pas actif")
    return Appelant(**ligne)


def _fin_du_jour(jour: date) -> datetime:
    return datetime.combine(jour + timedelta(days=1), time(0), fuseau())


# ---------------------------------------------------------------------------
# Les paramètres de chaque action : ceux de la route, sans le « pour qui »
# ---------------------------------------------------------------------------

class PTache(BaseModel):
    """TAC-20 à TAC-24, comme le formulaire de l'appli."""
    libelle: str = Field(min_length=1, max_length=100)
    id_type_tache: int | None = None
    duree_minutes: int | None = Field(default=None, ge=1, le=480)
    pour: int | None = Field(default=None, description="id d'un membre ; vide : à tour de rôle")
    tous_les_jours: int | None = Field(default=None, ge=1, le=730,
                                       description="Régulière : tous les N jours")
    du: date | None = None
    au: date | None = Field(default=None, description="Une fois : à faire au plus tard ce jour")
    apres: int | None = Field(default=None, description="id de la tâche qu'elle suit")
    delai_min_heures: int | None = Field(default=None, ge=0)
    delai_max_heures: int | None = Field(default=None, gt=0)
    heure_min: time | None = None
    heure_max: time | None = None
    si_pas_faite: str = Field(default="reporter", pattern="^(reporter|oublier)$")


class PModification(BaseModel):
    id_tache: int
    libelle: str | None = None
    duree_minutes: int | None = Field(default=None, gt=0)
    periodicite_min_jours: int | None = Field(default=None, gt=0)
    periodicite_max_jours: int | None = Field(default=None, gt=0)
    id_utilisateur_defaut: int | None = Field(default=None,
                                              description="Pour qui ; vide : à tour de rôle")
    id_type_tache: int | None = None
    sans_heure: bool = False
    heure_min: time | None = None
    heure_max: time | None = None


class PArret(BaseModel):
    id_tache: int


class PLien(BaseModel):
    """Poser un lien (id_tache, sorte, id_autre…), ou en retirer un (sorte, id_lien)."""
    sorte: str = Field(pattern="^(ensuite|meme_jour|vaut_aussi)$")
    id_tache: int | None = None
    id_autre: int | None = None
    id_lien: int | None = Field(default=None, description="Donné : le lien à retirer")
    delai_min_heures: int = Field(default=0, ge=0)
    delai_max_heures: int = Field(default=24, gt=0)
    place: str = Field(default="avant", pattern="^(avant|apres)$")
    mention: str | None = Field(default=None, max_length=60)

    @model_validator(mode="after")
    def _un_des_deux(self):
        if self.id_lien is None and (self.id_tache is None or self.id_autre is None):
            raise ValueError("Un lien se pose avec id_tache et id_autre, ou se retire avec id_lien")
        return self


class PReport(BaseModel):
    id_occurrence: int
    refuser: bool = Field(default=False, description="Vrai : ne pas la faire du tout")
    nouvelle_echeance: datetime | None = None
    raison: str | None = Field(default=None, max_length=200)


class PFaite(BaseModel):
    code_tache: str = Field(description="Le code de la tâche, rendu par lire_taches")
    quand: datetime | None = None


class PAbsence(BaseModel):
    """Déclarer une absence (debut, fin), en annuler une des siennes (id_absence),
    ou fermer celle en cours à l'heure du retour (retour)."""
    debut: datetime | None = None
    fin: datetime | None = None
    lieu: str | None = Field(default=None, max_length=100)
    id_lieu_connu: int | None = Field(default=None,
                                      description="Le lieu connu où l'on part (ADR-13)")
    commentaire: str | None = Field(default=None, max_length=200)
    id_absence: int | None = Field(default=None, description="Donné : l'absence à annuler")
    retour: datetime | None = Field(
        default=None, description="Donné : ferme l'absence en cours à cette heure, celle du "
                                  "retour au foyer (ABS-6, POS-8)")

    @model_validator(mode="after")
    def _un_des_deux(self):
        if self.id_absence is None and self.retour is None \
                and (self.debut is None or self.fin is None):
            raise ValueError("Une absence se déclare avec debut et fin, s'annule avec "
                             "id_absence, ou se ferme avec retour")
        return self


class POccupation(BaseModel):
    """Ajouter un créneau pris à la main, ou en retirer un (id_occupation)."""
    type: str = Field(default="autre", pattern="^(cours|travail|autre)$")
    libelle: str | None = Field(default=None, max_length=150)
    debut: datetime | None = None
    fin: datetime | None = None
    lieu: str | None = Field(default=None, max_length=100)
    id_occupation: int | None = Field(default=None, description="Donné : le créneau à retirer")

    @model_validator(mode="after")
    def _un_des_deux(self):
        if self.id_occupation is None and not (self.libelle and self.debut and self.fin):
            raise ValueError("Un créneau s'ajoute avec libelle, debut et fin, "
                             "ou se retire avec id_occupation")
        return self


class PAllegement(BaseModel):
    jours: int | None = Field(default=None, ge=1, le=14, description="Vide : arrêter")


class PConflit(BaseModel):
    id_conflit: int
    garder: str = Field(pattern="^(existante|nouvelle)$")


class PSeance(BaseModel):
    """Déplacer une séance (debut, id_lieu), ou la supprimer."""
    id_occurrence: int
    supprimer: bool = False
    debut: datetime | None = None
    id_lieu: int | None = None


class PSemaine(BaseModel):
    """La semaine de sport à valider, par son lundi ; vide, la semaine en cours."""
    lundi: date | None = None


class PSeanceSeule(BaseModel):
    id_occurrence: int


# ---------------------------------------------------------------------------
# Faire : la route du geste à la main. `essai` : sans replacer le planning.
# ---------------------------------------------------------------------------

def _faire_tache(qui: Appelant, p: PTache, essai: bool):
    from api.routeurs.taches import NouvelleTache, creer_depuis_l_appli
    return creer_depuis_l_appli(NouvelleTache(**p.model_dump()), qui)


def _faire_modification(qui: Appelant, p: PModification, essai: bool):
    from api.routeurs.taches import ModificationTache, modifier
    champs = p.model_dump(exclude={"id_tache"}, exclude_unset=True)
    return modifier(p.id_tache, ModificationTache(**champs), qui)


def _faire_arret(qui: Appelant, p: PArret, essai: bool):
    from api.routeurs.taches import desactiver
    return desactiver(p.id_tache, qui)


def _faire_lien(qui: Appelant, p: PLien, essai: bool):
    from api.routeurs.taches import NouveauLien, delier, lier
    if p.id_lien is not None:
        return delier(p.sorte, p.id_lien, qui)
    return lier(p.id_tache, NouveauLien(sorte=p.sorte, id_autre=p.id_autre,
                                        delai_min_heures=p.delai_min_heures,
                                        delai_max_heures=p.delai_max_heures,
                                        place=p.place, mention=p.mention), qui)


def _faire_report(qui: Appelant, p: PReport, essai: bool):
    from api.routeurs.occurrences import DemandeReport, refuser, reporter
    corps = DemandeReport(nouvelle_echeance=p.nouvelle_echeance, motif=p.raison)
    return (refuser if p.refuser else reporter)(p.id_occurrence, qui, corps)


def _faire_faite(qui: Appelant, p: PFaite, essai: bool):
    from api.routeurs.occurrences import DemandeSpontanee, faite
    return faite(DemandeSpontanee(code_tache=p.code_tache, quand=p.quand), qui)


def _faire_absence(qui: Appelant, p: PAbsence, essai: bool):
    from api.routeurs.absences import DemandeAbsence, annuler, declarer
    if p.retour is not None:
        from api import absences, ordonnanceur
        ferme = absences.rentrer(qui.id_utilisateur, p.retour)
        if ferme is None:
            raise DemandeImpossible("aucune_absence", "Aucune absence en cours à cette heure-là")
        if not essai:
            ordonnanceur.placer()
        return ferme
    if p.id_absence is not None:
        # Une demande n'annule que ses propres absences.
        if un_seul("SELECT 1 AS ok FROM absence WHERE id_absence = %(a)s "
                   "AND id_utilisateur = %(u)s", {"a": p.id_absence,
                                                  "u": qui.id_utilisateur}) is None:
            raise DemandeImpossible("introuvable", "Cette absence n'est pas la tienne")
        return annuler(p.id_absence, qui, replacer=not essai)
    return declarer(DemandeAbsence(debut=p.debut, fin=p.fin, lieu=p.lieu,
                                   id_lieu_connu=p.id_lieu_connu,
                                   commentaire=p.commentaire), qui, replacer=not essai)


def _faire_occupation(qui: Appelant, p: POccupation, essai: bool):
    from api.routeurs.contraintes import (
        DemandeOccupation,
        creer_occupation,
        supprimer_occupation,
    )
    if p.id_occupation is not None:
        # Seulement un créneau à soi, posé à la main : un cours collecté revient
        # à la collecte suivante.
        if un_seul("""SELECT 1 AS ok FROM occupation o JOIN source s ON s.id_source = o.id_source
                       WHERE o.id_occupation = %(o)s AND o.id_utilisateur = %(u)s
                         AND s.code = 'MANUELLE'""",
                   {"o": p.id_occupation, "u": qui.id_utilisateur}) is None:
            raise DemandeImpossible("introuvable",
                                    "Seul un créneau à toi, posé à la main, se retire")
        return supprimer_occupation(p.id_occupation, qui)
    return creer_occupation(DemandeOccupation(type=p.type, libelle=p.libelle, debut=p.debut,
                                              fin=p.fin, lieu=p.lieu), qui,
                            replacer=not essai)


def _faire_allegement(qui: Appelant, p: PAllegement, essai: bool):
    from api.routeurs.appli import DemandeAllegement, activer_allegement, arreter_allegement
    if p.jours is None:
        return arreter_allegement(qui)
    return activer_allegement(DemandeAllegement(jours=p.jours), qui)


def _faire_conflit(qui: Appelant, p: PConflit, essai: bool):
    from api.routeurs.contraintes import Arbitrage, resoudre_conflit
    if un_seul("""SELECT 1 AS ok FROM conflit c JOIN source s ON s.id_source = c.id_source
                   WHERE c.id_conflit = %(c)s AND s.id_utilisateur = %(u)s""",
               {"c": p.id_conflit, "u": qui.id_utilisateur}) is None:
        raise DemandeImpossible("introuvable", "Ce conflit n'est pas le tien")
    return resoudre_conflit(p.id_conflit, Arbitrage(garder=p.garder), qui)


def _faire_seance(qui: Appelant, p: PSeance, essai: bool):
    from api.routeurs.coach import Deplacement, deplacer_seance, supprimer_seance
    if p.supprimer:
        return supprimer_seance(qui, p.id_occurrence)
    if p.debut is None and p.id_lieu is None:
        raise DemandeImpossible("requete_invalide",
                                "Un déplacement donne un nouveau début, ou un lieu")
    return deplacer_seance(qui, p.id_occurrence, Deplacement(debut=p.debut, id_lieu=p.id_lieu))


def _faire_valider_semaine(qui: Appelant, p: PSemaine, essai: bool):
    from api.routeurs.coach import valider_semaine
    return valider_semaine(qui, p.lundi)


def _faire_valider_seance(qui: Appelant, p: PSeanceSeule, essai: bool):
    from api.routeurs.coach import valider_seance
    return valider_seance(qui, p.id_occurrence)


def _faire_pas_faite(qui: Appelant, p: PSeanceSeule, essai: bool):
    from api.routeurs.coach import declarer_pas_faite
    return declarer_pas_faite(qui, p.id_occurrence)


# ---------------------------------------------------------------------------
# Résumer : ce qui changerait, en une phrase (ACC-12)
# ---------------------------------------------------------------------------

def _resumer_tache(u: int, p: PTache) -> str:
    morceaux = [f"Ajouter la tâche « {p.libelle} »"]
    if p.tous_les_jours:
        morceaux.append(f"tous les {p.tous_les_jours} jours" if p.tous_les_jours > 1
                        else "tous les jours")
    elif p.apres:
        morceaux.append(f"après {_libelle_tache(p.apres)}")
    elif p.au:
        morceaux.append(f"une fois, d'ici {_jour(p.au)}" if p.du is None
                        else f"une fois, entre {_jour(p.du)} et {_jour(p.au)}")
    else:
        morceaux.append("une fois, aujourd'hui")
    if p.heure_min:
        morceaux.append(f"vers {p.heure_min:%H:%M}")
    pour = _pseudo(p.pour)
    morceaux.append(f"pour {pour}" if pour else "à tour de rôle")
    return ", ".join(morceaux)


def _resumer_modification(u: int, p: PModification) -> str:
    changes = []
    champs = p.model_dump(exclude={"id_tache"}, exclude_unset=True)
    if "libelle" in champs:
        changes.append(f"nom « {p.libelle} »")
    if p.duree_minutes:
        changes.append(f"{p.duree_minutes} min")
    if p.periodicite_min_jours or p.periodicite_max_jours:
        changes.append(f"tous les {p.periodicite_min_jours or '?'} à "
                       f"{p.periodicite_max_jours or '?'} jours")
    if "id_utilisateur_defaut" in champs:
        changes.append(f"pour {_pseudo(p.id_utilisateur_defaut) or 'chacun à tour de rôle'}")
    if p.sans_heure:
        changes.append("sans heure")
    elif p.heure_min:
        changes.append(f"entre {p.heure_min:%H:%M} et "
                       f"{p.heure_max.strftime('%H:%M') if p.heure_max else '?'}")
    if p.id_type_tache:
        ligne = un_seul("SELECT libelle FROM type_tache WHERE id_type_tache = %(t)s",
                        {"t": p.id_type_tache})
        changes.append(f"type « {(ligne or {}).get('libelle', p.id_type_tache)} »")
    return f"Modifier {_libelle_tache(p.id_tache)} : " + (", ".join(changes) or "rien")


def _resumer_arret(u: int, p: PArret) -> str:
    return f"Arrêter la tâche {_libelle_tache(p.id_tache)}"


def _resumer_lien(u: int, p: PLien) -> str:
    if p.id_lien is not None:
        ligne = un_seul("SELECT libelle_de, libelle_vers FROM v_lien_tache "
                        "WHERE sorte = %(s)s AND id_lien = %(l)s",
                        {"s": p.sorte, "l": p.id_lien})
        if ligne:
            return f"Retirer le lien entre « {ligne['libelle_de']} » et « {ligne['libelle_vers']} »"
        return f"Retirer le lien {p.id_lien}"
    sens = {"ensuite": "suivie de", "meme_jour": "le même jour que",
            "vaut_aussi": "qui vaut aussi"}[p.sorte]
    return f"Relier {_libelle_tache(p.id_tache)}, {sens} {_libelle_tache(p.id_autre)}"


def _resumer_report(u: int, p: PReport) -> str:
    ligne = un_seul("SELECT tache_libelle, assigne_a FROM v_occurrence "
                    "WHERE id_occurrence = %(o)s", {"o": p.id_occurrence})
    nom = f"« {ligne['tache_libelle']} » de {ligne['assigne_a']}" if ligne \
        else f"l'occurrence {p.id_occurrence}"
    if p.refuser:
        return f"Ne pas faire {nom}"
    return f"Reporter {nom}" + (f" au {_instant(p.nouvelle_echeance)}"
                                if p.nouvelle_echeance else "")


def _resumer_faite(u: int, p: PFaite) -> str:
    ligne = un_seul("SELECT libelle FROM tache WHERE code = %(c)s", {"c": p.code_tache})
    nom = f"« {ligne['libelle']} »" if ligne else p.code_tache
    return f"Déclarer {nom} faite, {_instant(p.quand)}"


def _resumer_absence(u: int, p: PAbsence) -> str:
    if p.id_absence is not None:
        ligne = un_seul("SELECT lower(periode) AS debut, lieu FROM absence "
                        "WHERE id_absence = %(a)s", {"a": p.id_absence})
        return "Annuler l'absence" + (f" du {_instant(ligne['debut'])}" if ligne else "")
    if p.retour is not None:
        return f"Rentré {_instant(p.retour)}"
    return (f"Absent du {_instant(p.debut)} au {_instant(p.fin)}"
            + (f", à {p.lieu}" if p.lieu else ""))


def _resumer_occupation(u: int, p: POccupation) -> str:
    if p.id_occupation is not None:
        ligne = un_seul("SELECT libelle, lower(periode) AS debut FROM occupation "
                        "WHERE id_occupation = %(o)s", {"o": p.id_occupation})
        return (f"Retirer « {ligne['libelle']} » du {_instant(ligne['debut'])}" if ligne
                else f"Retirer le créneau {p.id_occupation}")
    return f"Ajouter « {p.libelle} » du {_instant(p.debut)} au {_instant(p.fin)}"


def _resumer_allegement(u: int, p: PAllegement) -> str:
    if p.jours is None:
        return "Arrêter le mode allégé"
    return f"Passer en mode allégé pour {p.jours} jour{'s' if p.jours > 1 else ''}"


def _resumer_conflit(u: int, p: PConflit) -> str:
    ligne = un_seul("""SELECT c.libelle AS nouvelle, o.libelle AS existante
                         FROM conflit c JOIN occupation o ON o.id_occupation = c.id_occupation
                        WHERE c.id_conflit = %(c)s""", {"c": p.id_conflit})
    if not ligne:
        return f"Trancher le conflit {p.id_conflit}"
    gardee, laissee = (ligne["nouvelle"], ligne["existante"]) if p.garder == "nouvelle" \
        else (ligne["existante"], ligne["nouvelle"])
    return f"Garder « {gardee} » plutôt que « {laissee} »"


def _resumer_seance(u: int, p: PSeance) -> str:
    ligne = un_seul("""SELECT type_seance, discipline, debut FROM v_seance_coach
                        WHERE id_occurrence = %(o)s""", {"o": p.id_occurrence})
    nom = (f"« {ligne['type_seance'] or ligne['discipline']} » du {_instant(ligne['debut'])}"
           if ligne else f"la séance {p.id_occurrence}")
    if p.supprimer:
        return f"Supprimer la séance {nom}"
    vers = []
    if p.debut:
        vers.append(f"au {_instant(p.debut)}")
    if p.id_lieu:
        lieu = un_seul("SELECT libelle FROM lieu_sport WHERE id_lieu = %(l)s",
                       {"l": p.id_lieu})
        vers.append(f"à {(lieu or {}).get('libelle', 'un autre lieu')}")
    return f"Déplacer la séance {nom} " + " ".join(vers)


def _nom_de_seance(id_occurrence: int) -> str:
    ligne = un_seul("""SELECT type_seance, discipline, debut FROM v_seance_coach
                        WHERE id_occurrence = %(o)s""", {"o": id_occurrence})
    return (f"« {ligne['type_seance'] or ligne['discipline']} » du {_instant(ligne['debut'])}"
            if ligne else f"la séance {id_occurrence}")


def _resumer_valider_semaine(u: int, p: PSemaine) -> str:
    return ("Valider la semaine de sport du " + _jour(p.lundi)) if p.lundi \
        else "Valider la semaine de sport en cours"


def _resumer_valider_seance(u: int, p: PSeanceSeule) -> str:
    return f"Valider la séance {_nom_de_seance(p.id_occurrence)}"


def _resumer_pas_faite(u: int, p: PSeanceSeule) -> str:
    return f"Déclarer pas faite la séance {_nom_de_seance(p.id_occurrence)}"


# ---------------------------------------------------------------------------
# Le catalogue des actions (F.8.2)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Action:
    nom: str
    outil: str
    description: str
    modele: type[BaseModel]
    faire: Callable
    resumer: Callable
    # ACC-8 : ce que vise la demande ; elle expire avec.
    echeance: Callable[[BaseModel], datetime | None] = lambda p: None


ACTIONS: dict[str, Action] = {a.nom: a for a in (
    Action("tache", "demander_tache",
           "Demande d'ajouter une tâche de la maison : une fois (au, et du), régulière "
           "(tous_les_jours), ou après une autre (apres) ; à une heure (heure_min, "
           "heure_max) ou dans la journée ; pour un membre (pour) ou à tour de rôle.",
           PTache, _faire_tache, _resumer_tache,
           lambda p: _fin_du_jour(p.au) if p.au else None),
    Action("modification_tache", "demander_modification_tache",
           "Demande de modifier une tâche : nom, durée, rythme (periodicite_min_jours, "
           "periodicite_max_jours), pour qui, type, heure. Ne donner que ce qui change.",
           PModification, _faire_modification, _resumer_modification),
    Action("arret_tache", "demander_arret_tache",
           "Demande d'arrêter une tâche : elle ne sera plus posée, son historique reste.",
           PArret, _faire_arret, _resumer_arret),
    Action("lien", "demander_lien",
           "Demande de relier deux tâches (sorte : ensuite, meme_jour, vaut_aussi), ou de "
           "retirer un lien (sorte et id_lien).",
           PLien, _faire_lien, _resumer_lien),
    Action("report", "demander_report",
           "Demande de reporter une tâche posée (id_occurrence, nouvelle_echeance), ou de ne "
           "pas la faire (refuser).",
           PReport, _faire_report, _resumer_report,
           lambda p: None),
    Action("faite", "demander_faite",
           "Demande de déclarer une tâche faite, prévue ou non (code_tache, quand).",
           PFaite, _faire_faite, _resumer_faite),
    Action("absence", "demander_absence",
           "Demande de déclarer une absence de l'utilisateur (debut, fin, lieu, "
           "id_lieu_connu s'il part dans un lieu connu), d'en annuler une (id_absence), ou "
           "de fermer celle en cours à l'heure de son retour (retour). Une absence gèle son "
           "ménage.",
           PAbsence, _faire_absence, _resumer_absence,
           lambda p: p.debut),
    Action("occupation", "demander_occupation",
           "Demande d'ajouter un créneau pris à son planning (libelle, debut, fin, type : "
           "autre, cours ou travail), ou d'en retirer un posé à la main (id_occupation).",
           POccupation, _faire_occupation, _resumer_occupation,
           lambda p: p.debut),
    Action("allegement", "demander_allegement",
           "Demande de passer en mode allégé pour 1 à 14 jours (jours), ou de l'arrêter "
           "(jours vide).",
           PAllegement, _faire_allegement, _resumer_allegement),
    Action("conflit", "demander_conflit",
           "Demande de trancher un conflit horaire (lire_conflits) : garder l'existante "
           "ou la nouvelle.",
           PConflit, _faire_conflit, _resumer_conflit),
    Action("seance", "demander_seance",
           "Demande de déplacer une séance de sport déjà validée ou posée à la main "
           "(debut, id_lieu), ou de la supprimer. Une séance encore proposée par HAL se "
           "change avec modifier_seance_proposee.",
           PSeance, _faire_seance, _resumer_seance,
           lambda p: None),
    # ACT-1 : les gestes de l'onglet Sport.
    Action("valider_semaine", "demander_validation_semaine",
           "Demande de valider la semaine de sport proposée (lundi ; vide : la semaine "
           "en cours).",
           PSemaine, _faire_valider_semaine, _resumer_valider_semaine),
    Action("valider_seance", "demander_validation_seance",
           "Demande de valider une séance proposée, seule (id_occurrence).",
           PSeanceSeule, _faire_valider_seance, _resumer_valider_seance),
    Action("pas_faite", "demander_pas_faite",
           "Demande de déclarer pas faite une séance du jour ou passée (id_occurrence).",
           PSeanceSeule, _faire_pas_faite, _resumer_pas_faite),
)}


def _schema(action: Action) -> dict:
    """Le schéma de l'outil : les paramètres de l'action, et le motif."""
    schema = action.modele.model_json_schema()
    proprietes = {"motif": {"type": "string", "maxLength": 300,
                            "description": "Pourquoi, en une phrase : l'utilisateur la lira"}}
    proprietes.update(schema.get("properties", {}))
    rendu = {"type": "object", "properties": proprietes,
             "required": ["motif", *schema.get("required", [])]}
    if "$defs" in schema:
        rendu["$defs"] = schema["$defs"]
    return rendu


# ---------------------------------------------------------------------------
# Déposer (ACC-1 à ACC-3, ACC-9)
# ---------------------------------------------------------------------------

def _refus_de(erreur: Exception) -> DemandeImpossible:
    if isinstance(erreur, DemandeImpossible):
        return erreur
    if isinstance(erreur, HTTPException):
        detail = erreur.detail if isinstance(erreur.detail, dict) else {}
        return DemandeImpossible(detail.get("code", "refusee"),
                                 detail.get("message") or str(erreur.detail))
    if isinstance(erreur, psycopg.Error):
        refus = refus_coach(erreur)
        if refus is not None:
            return DemandeImpossible(refus["code"], refus["message"])
        return DemandeImpossible("refusee_par_la_base", message_lisible(erreur))
    raise erreur


def _jouer(action: Action, qui: Appelant, parametres: BaseModel, essai: bool):
    try:
        return action.faire(qui, parametres, essai)
    except (DemandeImpossible, HTTPException, psycopg.Error) as erreur:
        raise _refus_de(erreur) from None


def deposer(id_utilisateur: int, nom: str, arguments: dict, geste: bool = False) -> dict:
    """Essaie l'action sans rien garder, puis dépose la demande. Lève RefusOutil
    si la base ou la route refusent : le modèle lit le motif (MCP-9).

    `geste` : HAL dans l'appli, à la demande de l'utilisateur (ACT-2). La demande
    s'acceptera seule après la réponse, sauf annulation."""
    action = ACTIONS[nom]
    arguments = dict(arguments or {})
    motif = str(arguments.pop("motif", "") or "").strip()
    if not motif:
        raise RefusOutil("requete_invalide", "« motif » est vide : dis pourquoi, en une phrase")
    try:
        parametres = action.modele(**arguments)
    except ValidationError as erreur:
        raise RefusOutil("requete_invalide", "; ".join(
            f"{'.'.join(str(x) for x in e['loc']) or 'demande'} : {e['msg']}"
            for e in erreur.errors())) from None
    qui = _appelant(id_utilisateur)
    try:
        with transaction_annulee():
            _jouer(action, qui, parametres, essai=True)
    except DemandeImpossible as refus:
        raise RefusOutil(refus.code, f"La base refuserait cette demande : {refus.motif}") \
            from None

    resume = action.resumer(id_utilisateur, parametres)
    client = client_courant.get()
    ligne = executer(
        """SELECT deposer_demande(%(u)s, %(a)s, %(p)s, %(r)s, %(m)s, %(c)s, %(s)s, %(e)s)
                  AS id""",
        {"u": id_utilisateur, "a": nom, "p": Jsonb(parametres.model_dump(
            mode="json", exclude_unset=True)), "r": resume, "m": motif, "c": client,
         "s": session_courante.get(), "e": action.echeance(parametres)})
    id_demande = ligne["id"]
    if geste:
        executer("UPDATE demande SET geste = TRUE WHERE id_demande = %(d)s", {"d": id_demande})
        return {"fait": resume, "id_demande": id_demande,
                "note": "C'est fait : dis-le simplement. L'utilisateur voit l'action sous ton "
                        "message et peut l'annuler dans les cinq secondes."}
    if client is not None:
        # ACC-9 : l'utilisateur n'est pas dans l'appli ; la demande vient à lui.
        executer(
            """INSERT INTO notification (id_utilisateur, type, contenu, id_demande)
               VALUES (%(u)s, 'demande', %(c)s, %(d)s)""",
            {"u": id_utilisateur, "c": f"{client} propose : {resume}. {motif}",
             "d": id_demande})
    return {"demande_deposee": id_demande, "resume": resume,
            "note": "Elle attend l'accord de l'utilisateur, dans l'appli HAL : rien n'a "
                    "encore changé. Dis-le-lui."}


# ---------------------------------------------------------------------------
# Décider (ACC-4 à ACC-8)
# ---------------------------------------------------------------------------

def _la_demande(id_utilisateur: int, id_demande: int) -> dict:
    ligne = un_seul("SELECT * FROM demande WHERE id_demande = %(d)s AND id_utilisateur = %(u)s",
                    {"d": id_demande, "u": id_utilisateur})
    if ligne is None:
        raise DemandeImpossible("introuvable", "Cette demande n'existe pas, ou n'est pas la tienne")
    return ligne


def accepter(id_utilisateur: int, id_demande: int) -> dict:
    """ACC-4 : l'action, pour de bon, par la route du geste à la main, au nom de
    l'utilisateur. Un refus de la base, maintenant, fait échouer la demande."""
    executer("SELECT expirer_demandes()")
    demande = _la_demande(id_utilisateur, id_demande)
    if demande["etat"] != "en_attente":
        _decider(id_utilisateur, id_demande, "acceptee")      # lève le bon motif
    action = ACTIONS[demande["action"]]
    parametres = action.modele(**demande["parametres"])
    qui = _appelant(id_utilisateur)
    # NOT-17 : la raison dit d'où vient le changement.
    origine = (f"demandé à HAL par {qui.pseudo} : {demande['resume']}" if demande.get("geste")
               else f"demande de {demande['client'] or 'HAL'} : {demande['resume']}")[:200]
    with operation.ouvrir_a_part(origine, qui.pseudo):
        try:
            resultat = _jouer(action, qui, parametres, essai=False)
        except DemandeImpossible as refus:
            _decider(id_utilisateur, id_demande, "echouee", refus.motif)
            raise
        _decider(id_utilisateur, id_demande, "acceptee")
    return {"demande": etat(id_utilisateur, id_demande),
            "resultat": json.loads(json.dumps(resultat, default=str))}


def refuser(id_utilisateur: int, id_demande: int) -> dict:
    _la_demande(id_utilisateur, id_demande)
    _decider(id_utilisateur, id_demande, "refusee")
    return {"demande": etat(id_utilisateur, id_demande)}


def _decider(id_utilisateur: int, id_demande: int, etat_: str, motif: str | None = None):
    try:
        executer("SELECT decider_demande(%(u)s, %(d)s, %(e)s, %(m)s)",
                 {"u": id_utilisateur, "d": id_demande, "e": etat_, "m": motif})
    except psycopg.Error as erreur:
        raise _refus_de(erreur) from None


COLONNES = """id_demande, action, resume, motif, origine, client, etat, deposee_le, expire_le,
              decidee_le, motif_echec, geste"""


def etat(id_utilisateur: int, id_demande: int) -> dict:
    return un_seul(f"SELECT {COLONNES} FROM demande WHERE id_demande = %(d)s "
                   "AND id_utilisateur = %(u)s", {"d": id_demande, "u": id_utilisateur})


def lister_pour(id_utilisateur: int, seulement_en_attente: bool = False,
                limite: int = 30) -> list[dict]:
    """Les demandes, en attente d'abord. Une demande expirée se voit comme telle."""
    executer("SELECT expirer_demandes()")
    return lister(
        f"""SELECT {COLONNES} FROM demande
             WHERE id_utilisateur = %(u)s AND (NOT %(a)s OR etat = 'en_attente')
               -- ACT-2 : un geste n'attend pas d'accord ; il ne s'affiche pas en attente.
               AND NOT (geste AND etat = 'en_attente')
             ORDER BY etat <> 'en_attente', deposee_le DESC LIMIT %(l)s""",
        {"u": id_utilisateur, "a": seulement_en_attente, "l": limite})


# ---------------------------------------------------------------------------
# Les outils (MCP-4, COA-5)
# ---------------------------------------------------------------------------

def lister_demandes(u: int, a: dict) -> object:
    return {"demandes": [{k: v for k, v in d.items() if v is not None}
                         for d in lister_pour(u, limite=int(a.get("limite") or 15))]}


def retirer_demande(u: int, a: dict) -> object:
    """ACC-11 : un modèle retire une demande qu'il a déposée, tant qu'elle attend."""
    ligne = executer(
        """UPDATE demande SET etat = 'refusee', decidee_le = now()
            WHERE id_demande = %(d)s AND id_utilisateur = %(u)s AND etat = 'en_attente'
              AND origine = CASE WHEN %(c)s::TEXT IS NULL THEN 'HAL' ELSE 'client' END
        RETURNING id_demande""",
        {"d": a.get("id_demande"), "u": u, "c": client_courant.get()})
    if ligne is None:
        raise RefusOutil("introuvable", "Aucune demande en attente de ce numéro, déposée par toi")
    return {"fait": "demande retirée"}


def _outil(action: Action) -> Outil:
    return Outil(action.outil, "demandes", action.description
                 + " Rien ne change sans l'accord de l'utilisateur, donné dans l'appli.",
                 _schema(action), lambda u, a, nom=action.nom: deposer(u, nom, a))


OUTILS: tuple[Outil, ...] = (
    *(_outil(a) for a in ACTIONS.values()),
    Outil("lister_demandes", "demandes",
          "Tes demandes et celles déjà décidées : en attente, acceptées, refusées, "
          "expirées, échouées, avec leur motif.",
          {"type": "object", "properties": {"limite": {"type": "integer", "minimum": 1,
                                                       "maximum": 30}},
           "required": [], "additionalProperties": False}, lister_demandes),
    Outil("retirer_demande", "demandes",
          "Retire une demande que tu as déposée, tant qu'elle attend.",
          {"type": "object", "properties": {"id_demande": {"type": "integer"}},
           "required": ["id_demande"], "additionalProperties": False}, retirer_demande),
)

PAR_NOM = {o.nom: o for o in OUTILS}


# ---------------------------------------------------------------------------
# Les gestes : ce qu'on demande à HAL dans l'appli               (ACT-1, ACT-2)
# ---------------------------------------------------------------------------

# Le nom de l'outil de chaque geste, et ce qu'il dit au modèle. Le geste fait ce
# que fait le bouton : la même route, les mêmes droits, les mêmes refus.
GESTES_MAISON = {
    "tache": "creer_tache", "modification_tache": "modifier_tache",
    "arret_tache": "arreter_tache", "lien": "lier_taches", "report": "reporter_tache",
    "faite": "declarer_faite", "absence": "declarer_absence",
    "occupation": "poser_creneau", "allegement": "regler_mode_allege",
    "conflit": "trancher_conflit",
}
GESTES_SPORT = {
    "seance": "deplacer_ou_supprimer_seance", "valider_semaine": "valider_semaine",
    "valider_seance": "valider_seance", "pas_faite": "declarer_seance_pas_faite",
}


def _description_du_geste(action: Action) -> str:
    texte = action.description
    for avant in ("Demande d'", "Demande de "):
        if texte.startswith(avant):
            texte = texte[len(avant):]
            break
    return (texte[:1].upper() + texte[1:] + " À n'utiliser que si l'utilisateur te le "
            "demande dans ce message, ou vient de te le confirmer. C'est fait tout de suite ; "
            "il peut l'annuler dans les cinq secondes.")


def _outil_de_geste(nom_action: str, nom_outil: str, famille: str) -> Outil:
    action = ACTIONS[nom_action]
    return Outil(nom_outil, famille, _description_du_geste(action), _schema(action),
                 lambda u, a, nom=nom_action: deposer(u, nom, a, geste=True))


OUTILS_GESTES_MAISON: tuple[Outil, ...] = tuple(
    _outil_de_geste(a, o, "gestes") for a, o in GESTES_MAISON.items())
OUTILS_GESTES_SPORT: tuple[Outil, ...] = tuple(
    _outil_de_geste(a, o, "gestes_sport") for a, o in GESTES_SPORT.items())


def programmer_les_gestes(operation_id: str) -> int:
    """ACT-2 : la réponse est rendue ; les gestes de l'appel partiront dans
    quelques secondes, sauf annulation. Rend leur nombre."""
    ligne = executer(
        """WITH dus AS (
               UPDATE demande SET auto_le = now() + make_interval(secs => %(s)s)
                WHERE operation = %(o)s AND geste AND etat = 'en_attente' AND auto_le IS NULL
               RETURNING 1)
           SELECT count(*)::INTEGER AS n FROM dus""",
        {"o": operation_id, "s": DELAI_GESTE_SECONDES})
    nombre = (ligne or {}).get("n", 0)
    if nombre and MINUTEUR_DES_GESTES:
        minuteur = threading.Timer(DELAI_GESTE_SECONDES + 0.5, executer_les_gestes)
        minuteur.daemon = True
        minuteur.start()
    return nombre


def executer_les_gestes() -> int:
    """Accepte les gestes arrivés à leur heure et pas annulés. Appelée par le
    minuteur de la réponse, et par l'ordonnanceur pour ceux qu'un redémarrage
    aurait laissés. Un geste que la base refuse maintenant échoue avec son motif."""
    faits = 0
    for d in lister("""SELECT id_demande, id_utilisateur FROM demande
                        WHERE geste AND etat = 'en_attente' AND auto_le <= now()
                        ORDER BY id_demande"""):
        try:
            accepter(d["id_utilisateur"], d["id_demande"])
            faits += 1
        except DemandeImpossible as refus:
            LOG.info("Geste %s échoué : %s", d["id_demande"], refus.motif)
        except Exception:  # noqa: BLE001 - un geste en échec n'arrête pas les autres
            LOG.exception("Geste %s en erreur", d["id_demande"])
    return faits
