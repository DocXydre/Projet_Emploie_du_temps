package fr.thomasmathis.planif.statuts;

/**
 * Statuts globaux d'un utilisateur (cf. cahier des charges, 2 et 7.5).
 *
 * <p>Le statut {@code LUSSE} de la v1 est devenu {@code ABSENT} avec un champ
 * {@code lieu} : un statut ne doit pas porter un nom de commune, sinon la regle
 * n'est plus reutilisable pour des vacances ou un deplacement.</p>
 */
public enum TypeStatut {
    ACTIF,
    MALADE,
    ABSENT
}
