package fr.thomasmathis.planif.taches;

/**
 * Etats d'une occurrence (cf. cahier des charges, 5.3).
 *
 * <p>Les transitions autorisees sont declarees une seule fois, dans
 * {@link MachineEtatsOccurrence}. Aucun service ne modifie l'etat directement.</p>
 */
public enum EtatOccurrence {

    /** Placee par le moteur, pas encore communiquee a l'utilisateur. */
    PLANIFIEE,

    /** Communiquee : le creneau est epingle et ne bouge plus sans raison (6.5). */
    NOTIFIEE,

    /** Faite. Porte la date de validation reelle, qui pilote la recurrence. */
    VALIDEE,

    /** Repoussee : une nouvelle occurrence prend le relais. */
    REPORTEE,

    /** Refusee par l'assigne : reassignation ou report. */
    REFUSEE,

    /** Suspendue par un statut global. Degel possible. */
    GELEE,

    /** Abandonnee. Etat terminal. */
    ANNULEE,

    /** Aucun creneau compatible trouve. N'est jamais supprimee silencieusement (6.4, passe 8). */
    NON_PLANIFIABLE;

    public boolean estTerminal() {
        return this == VALIDEE || this == REPORTEE || this == REFUSEE || this == ANNULEE;
    }

    /** Une occurrence ouverte est encore a faire : elle entre dans l'espace de recherche du moteur. */
    public boolean estOuverte() {
        return !estTerminal();
    }
}
