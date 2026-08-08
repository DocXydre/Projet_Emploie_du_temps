package fr.thomasmathis.planif.securite;

import java.util.Collection;
import java.util.List;

import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.utilisateurs.Role;

/**
 * Identite de l'appelant, extraite du jeton et posee dans le contexte de securite.
 *
 * <p>Porte aussi la regle de permission de la section 3.3 : une occurrence
 * assignee a Lorette ne peut etre validee que par Lorette ou par Thomas, en
 * mode depannage, et ce depannage est trace.</p>
 */
public record UtilisateurCourant(Long id, String identifiant, Role role) {

    public boolean estAdministrateur() {
        return role == Role.ADMINISTRATEUR;
    }

    public Collection<GrantedAuthority> autorites() {
        return List.of(new SimpleGrantedAuthority(role.autorite()));
    }

    /** Vrai si l'appelant agit sur une tache qui n'est pas la sienne. */
    public boolean agitPourAutrui(Long assigneA) {
        return assigneA != null && !assigneA.equals(id);
    }

    /**
     * Verifie le droit d'agir sur une occurrence assignee a {@code assigneA}.
     * L'administrateur peut depanner ; un utilisateur standard, non.
     */
    public void verifierDroitSur(Long assigneA) {
        if (assigneA == null || assigneA.equals(id) || estAdministrateur()) {
            return;
        }
        throw new ExceptionMetier("ACTION_NON_AUTORISEE", HttpStatus.FORBIDDEN,
                "Cette tache est assignee a un autre utilisateur");
    }

    /** Appelant courant, ou erreur 401 si la requete n'est pas authentifiee. */
    public static UtilisateurCourant obligatoire() {
        Authentication authentification = SecurityContextHolder.getContext().getAuthentication();
        if (authentification == null || !(authentification.getPrincipal() instanceof UtilisateurCourant courant)) {
            throw new ExceptionMetier("NON_AUTHENTIFIE", HttpStatus.UNAUTHORIZED, "Authentification requise");
        }
        return courant;
    }
}
