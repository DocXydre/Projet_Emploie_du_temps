package fr.thomasmathis.planif.api;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.commun.FiltreCorrelation;

@RestControllerAdvice
public class GestionnaireErreurs {

    private static final Logger LOG = LoggerFactory.getLogger(GestionnaireErreurs.class);

    private final Clock horloge;
    private final boolean exposerDetail;

    public GestionnaireErreurs(Clock horloge,
                               @Value("${planif.erreurs.exposer-detail:false}") boolean exposerDetail) {
        this.horloge = horloge;
        this.exposerDetail = exposerDetail;
    }

    @ExceptionHandler(ExceptionMetier.class)
    public ResponseEntity<ErreurApi> metier(ExceptionMetier e) {
        return construire(e.statut(), e.code(), e.getMessage(), null);
    }

    /**
     * Refus de la securite au niveau methode ({@code @PreAuthorize}). Sans ce
     * traitement, l'exception remonterait dans le gestionnaire generique et
     * sortirait en 500 au lieu d'un 403.
     */
    @ExceptionHandler(AccessDeniedException.class)
    public ResponseEntity<ErreurApi> accesRefuse(AccessDeniedException e) {
        return construire(HttpStatus.FORBIDDEN, "ACTION_NON_AUTORISEE", "Droits insuffisants", null);
    }

    @ExceptionHandler(AuthenticationException.class)
    public ResponseEntity<ErreurApi> nonAuthentifie(AuthenticationException e) {
        return construire(HttpStatus.UNAUTHORIZED, "NON_AUTHENTIFIE", "Authentification requise", null);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ErreurApi> validation(MethodArgumentNotValidException e) {
        String detail = e.getBindingResult().getFieldErrors().stream()
                .map(erreur -> erreur.getField() + " : " + erreur.getDefaultMessage())
                .collect(Collectors.joining(", "));
        return construire(HttpStatus.BAD_REQUEST, "REQUETE_INVALIDE", "Requete invalide", detail);
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErreurApi> inattendue(Exception e) {
        LOG.error("Erreur inattendue [{}]", FiltreCorrelation.courant(), e);
        return construire(HttpStatus.INTERNAL_SERVER_ERROR, "ERREUR_INTERNE",
                "Une erreur interne est survenue", e.getClass().getSimpleName() + " : " + e.getMessage());
    }

    private ResponseEntity<ErreurApi> construire(HttpStatus statut, String code, String message, String detail) {
        ErreurApi corps = new ErreurApi(
                code,
                message,
                exposerDetail ? detail : null,
                FiltreCorrelation.courant(),
                OffsetDateTime.now(horloge));
        return ResponseEntity.status(statut).body(corps);
    }
}
