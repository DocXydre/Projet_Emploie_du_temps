package fr.thomasmathis.planif.utilisateurs;

/**
 * Roles du systeme (cf. cahier des charges, 3.1).
 *
 * <p>Deux roles suffisent : l'administrateur configure les regles et force des
 * creneaux, l'utilisateur standard consulte et valide ce qui le concerne.</p>
 */
public enum Role {
    ADMINISTRATEUR,
    STANDARD;

    /** Autorite Spring Security correspondante. */
    public String autorite() {
        return "ROLE_" + name();
    }
}
