package fr.thomasmathis.planif.utilisateurs;

import java.util.List;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import fr.thomasmathis.planif.securite.UtilisateurCourant;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

@RestController
@RequestMapping("/api/v1/utilisateurs")
@Tag(name = "Utilisateurs")
public class UtilisateurControleur {

    private final ServiceUtilisateur service;

    public UtilisateurControleur(ServiceUtilisateur service) {
        this.service = service;
    }

    @GetMapping("/moi")
    @Operation(summary = "Profil de l'appelant")
    public VueUtilisateur moi() {
        return VueUtilisateur.de(service.parId(UtilisateurCourant.obligatoire().id()));
    }

    @GetMapping
    @Operation(summary = "Liste des utilisateurs, pour les ecrans d'assignation")
    public List<VueUtilisateur> lister() {
        return service.tous().stream().map(VueUtilisateur::de).toList();
    }

    public record VueUtilisateur(Long id, String nom, String identifiant, Role role,
                                 String fuseau, String canalNotification, boolean actif) {

        static VueUtilisateur de(Utilisateur u) {
            return new VueUtilisateur(u.getId(), u.getNom(), u.getIdentifiant(), u.getRole(),
                    u.getFuseau(), u.getCanalNotification(), u.isActif());
        }
    }
}
