package fr.thomasmathis.planif.commun;

import java.io.IOException;
import java.util.UUID;

import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Attribue un identifiant de correlation a chaque requete, le place dans le MDC
 * pour les journaux structures et le renvoie dans l'en-tete de reponse.
 * C'est cet identifiant que l'on retrouve dans les erreurs normalisees (4.5).
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class FiltreCorrelation extends OncePerRequestFilter {

    public static final String EN_TETE = "X-Correlation-Id";
    public static final String CLE_MDC = "correlation";

    @Override
    protected void doFilterInternal(HttpServletRequest requete,
                                    HttpServletResponse reponse,
                                    FilterChain chaine) throws ServletException, IOException {
        String correlation = requete.getHeader(EN_TETE);
        if (correlation == null || correlation.isBlank()) {
            correlation = UUID.randomUUID().toString();
        }
        MDC.put(CLE_MDC, correlation);
        reponse.setHeader(EN_TETE, correlation);
        try {
            chaine.doFilter(requete, reponse);
        } finally {
            MDC.remove(CLE_MDC);
        }
    }

    /** Identifiant de correlation de la requete en cours, jamais nul. */
    public static String courant() {
        String correlation = MDC.get(CLE_MDC);
        return correlation != null ? correlation : "hors-requete";
    }
}
