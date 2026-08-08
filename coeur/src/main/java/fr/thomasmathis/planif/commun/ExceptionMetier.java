package fr.thomasmathis.planif.commun;

import org.springframework.http.HttpStatus;

/**
 * Exception applicative portant un code stable et un statut HTTP.
 * Le code est destine aux clients de l'API : il ne doit jamais changer
 * sans changement de version de l'interface.
 */
public class ExceptionMetier extends RuntimeException {

    private final String code;
    private final HttpStatus statut;

    public ExceptionMetier(String code, HttpStatus statut, String message) {
        super(message);
        this.code = code;
        this.statut = statut;
    }

    public static ExceptionMetier introuvable(String entite, Object id) {
        return new ExceptionMetier(
                "RESSOURCE_INTROUVABLE",
                HttpStatus.NOT_FOUND,
                "%s introuvable : %s".formatted(entite, id));
    }

    public static ExceptionMetier regleViolee(String message) {
        return new ExceptionMetier("REGLE_METIER_VIOLEE", HttpStatus.CONFLICT, message);
    }

    public String code() {
        return code;
    }

    public HttpStatus statut() {
        return statut;
    }
}
