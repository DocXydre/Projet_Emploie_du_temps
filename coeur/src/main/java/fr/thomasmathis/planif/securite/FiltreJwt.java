package fr.thomasmathis.planif.securite;

import java.io.IOException;

import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Lit le jeton d'acces de l'en-tete Authorization et pose l'identite dans le
 * contexte de securite. Un jeton absent laisse la requete anonyme : c'est
 * Spring Security qui decide ensuite si l'endpoint l'autorise.
 */
@Component
public class FiltreJwt extends OncePerRequestFilter {

    private static final String PREFIXE = "Bearer ";

    private final ServiceJeton serviceJeton;

    public FiltreJwt(ServiceJeton serviceJeton) {
        this.serviceJeton = serviceJeton;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest requete,
                                    HttpServletResponse reponse,
                                    FilterChain chaine) throws ServletException, IOException {
        String enTete = requete.getHeader("Authorization");

        if (enTete != null && enTete.startsWith(PREFIXE)
                && SecurityContextHolder.getContext().getAuthentication() == null) {
            try {
                ServiceJeton.JetonLu jeton =
                        serviceJeton.lire(enTete.substring(PREFIXE.length()), ServiceJeton.USAGE_ACCES);

                UtilisateurCourant courant =
                        new UtilisateurCourant(jeton.utilisateurId(), jeton.identifiant(), jeton.role());

                var authentification = new UsernamePasswordAuthenticationToken(
                        courant, null, courant.autorites());
                SecurityContextHolder.getContext().setAuthentication(authentification);
            } catch (ExceptionMetier e) {
                // Jeton illisible : on reste anonyme. L'endpoint decidera.
                SecurityContextHolder.clearContext();
            }
        }

        chaine.doFilter(requete, reponse);
    }
}
