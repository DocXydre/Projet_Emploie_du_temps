"""La correspondance entre ce que dit l'application Santé et nos disciplines.

Le nom que la montre donne à une séance est gardé tel quel (SAN-2). La
discipline en est déduite ici, par une table et non par du code : une activité
que le module ne couvre pas (natation, vélo dehors, marche) reste « autre » et
ne crée pas de séance.
"""

DISCIPLINES_DE_LA_MONTRE = {
    "running": "course",
    "trailrunning": "course",
    "traditionalstrengthtraining": "musculation",
    "functionalstrengthtraining": "musculation",
    "coretraining": "musculation",
    "elliptical": "cardio",
    "rowing": "cardio",
    "stairclimbing": "cardio",
    "stairs": "cardio",
    "stepper": "cardio",
    "indoorcycling": "cardio",
    "highintensityintervaltraining": "cardio",
    "mixedcardio": "cardio",
    "crosstraining": "cardio",
    "skierg": "cardio",
}


def discipline_de(type_montre: str) -> str:
    """« HKWorkoutActivityTypeRunning », « running » ou « Course à pied »."""
    nom = (type_montre or "").lower().replace("hkworkoutactivitytype", "")
    nom = "".join(c for c in nom if c.isalnum())
    if nom in DISCIPLINES_DE_LA_MONTRE:
        return DISCIPLINES_DE_LA_MONTRE[nom]
    if "course" in nom or "run" in nom:
        return "course"
    if "muscu" in nom or "strength" in nom or "force" in nom:
        return "musculation"
    return "autre"
