package fr.thomasmathis.planif.securite;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.journal.ServiceJournal;
import fr.thomasmathis.planif.utilisateurs.ServiceUtilisateur;
import fr.thomasmathis.planif.utilisateurs.Utilisateur;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;

@RestController
@RequestMapping("/api/v1/auth")
@Tag(name = "Authentification")
public class AuthControleur {

    private final ServiceUtilisateur serviceUtilisateur;
    private final ServiceJeton serviceJeton;
    private final ServiceJournal journal;

    public AuthControleur(ServiceUtilisateur serviceUtilisateur, ServiceJeton serviceJeton,
                          ServiceJournal journal) {
        this.serviceUtilisateur = serviceUtilisateur;
        this.serviceJeton = serviceJeton;
        this.journal = journal;
    }

    @PostMapping("/connexion")
    @Operation(summary = "Obtenir un jeton d'acces et un jeton de rafraichissement")
    public ReponseJetons connexion(@Valid @RequestBody DemandeConnexion demande) {
        Utilisateur utilisateur = serviceUtilisateur
                .authentifier(demande.identifiant(), demande.motDePasse())
                .orElseThrow(() -> {
                    journal.tracer(demande.identifiant(), "CONNEXION_REFUSEE", "utilisateur", null, null, null);
                    return new ExceptionMetier("IDENTIFIANTS_INVALIDES", HttpStatus.UNAUTHORIZED,
                            "Identifiant ou mot de passe incorrect");
                });

        journal.tracer(utilisateur.getIdentifiant(), "CONNEXION", "utilisateur", utilisateur.getId(), null, null);
        return jetonsPour(utilisateur);
    }

    @PostMapping("/rafraichir")
    @Operation(summary = "Echanger un jeton de rafraichissement contre un nouveau jeton d'acces")
    public ReponseJetons rafraichir(@Valid @RequestBody DemandeRafraichissement demande) {
        ServiceJeton.JetonLu lu =
                serviceJeton.lire(demande.jetonRafraichissement(), ServiceJeton.USAGE_RAFRAICHISSEMENT);

        Utilisateur utilisateur = serviceUtilisateur.parIdentifiantActif(lu.identifiant())
                .orElseThrow(() -> new ExceptionMetier("COMPTE_INACTIF", HttpStatus.UNAUTHORIZED,
                        "Compte inconnu ou desactive"));

        return jetonsPour(utilisateur);
    }

    private ReponseJetons jetonsPour(Utilisateur utilisateur) {
        return new ReponseJetons(
                serviceJeton.emettreAcces(utilisateur),
                serviceJeton.emettreRafraichissement(utilisateur),
                serviceJeton.dureeAcces().toSeconds(),
                utilisateur.getIdentifiant(),
                utilisateur.getRole().name());
    }

    public record DemandeConnexion(@NotBlank String identifiant, @NotBlank String motDePasse) {
    }

    public record DemandeRafraichissement(@NotBlank String jetonRafraichissement) {
    }

    public record ReponseJetons(String jetonAcces, String jetonRafraichissement,
                                long expireDansSecondes, String identifiant, String role) {
    }
}
