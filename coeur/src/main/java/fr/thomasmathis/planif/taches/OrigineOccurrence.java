package fr.thomasmathis.planif.taches;

/** Provenance d'une occurrence. Sert au diagnostic et aux regles de rattrapage (7.5 E.3). */
public enum OrigineOccurrence {

    /** Generee par la recurrence de la definition. */
    AUTOMATIQUE,

    /** Creee ou forcee a la main. Epinglee d'office. */
    MANUELLE,

    /** Declenchee par une dependance (poussiere puis aspirateur). */
    DEPENDANCE,

    /** Recreee a la sortie d'un statut, pour solder la dette. */
    RATTRAPAGE
}
