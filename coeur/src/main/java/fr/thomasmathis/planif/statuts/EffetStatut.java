package fr.thomasmathis.planif.statuts;

/** Effet d'un statut sur une categorie de taches (cf. 5.1, table regle_statut). */
public enum EffetStatut {

    /** Suspendue, degelee au retour. Les bonus geles sont abandonnes, pas rattrapes. */
    GELER,

    /** Repoussee au dela de la periode de statut. */
    REPORTER,

    /** Confiee a l'autre utilisateur pendant la periode. */
    REASSIGNER,

    /** Reste due normalement. Cas de la litiere. */
    MAINTENIR
}
