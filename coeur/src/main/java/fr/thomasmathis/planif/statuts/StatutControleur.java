package fr.thomasmathis.planif.statuts;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import fr.thomasmathis.planif.securite.UtilisateurCourant;
import fr.thomasmathis.planif.taches.CategorieTache;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;

@RestController
@RequestMapping("/api/v1/statuts")
@Tag(name = "Statuts")
public class StatutControleur {

    private final ServiceStatut service;

    public StatutControleur(ServiceStatut service) {
        this.service = service;
    }

    @GetMapping("/courant")
    @Operation(summary = "Statut ouvert d'un utilisateur, avec les effets applicables")
    public VueStatutCourant courant(@RequestParam(required = false) Long utilisateur) {
        Long cible = utilisateur != null ? utilisateur : UtilisateurCourant.obligatoire().id();
        TypeStatut type = service.typeCourant(cible);
        return new VueStatutCourant(
                cible,
                type,
                service.courant(cible).map(VueStatut::de).orElse(null),
                service.effets(type));
    }

    @GetMapping("/historique")
    @Operation(summary = "Historique des statuts d'un utilisateur")
    public List<VueStatut> historique(@RequestParam(required = false) Long utilisateur) {
        Long cible = utilisateur != null ? utilisateur : UtilisateurCourant.obligatoire().id();
        return service.historique(cible).stream().map(VueStatut::de).toList();
    }

    @PostMapping
    @Operation(summary = "Declarer un statut ; le precedent est ferme automatiquement")
    public ResponseEntity<VueStatut> declarer(@Valid @RequestBody DemandeDeclaration demande) {
        UtilisateurCourant acteur = UtilisateurCourant.obligatoire();
        Long cible = demande.utilisateurId() != null ? demande.utilisateurId() : acteur.id();
        acteur.verifierDroitSur(cible);

        StatutUtilisateur statut = service.declarer(acteur.identifiant(), cible, demande.type(),
                demande.debut(), demande.finPrevue(), demande.lieu(), demande.commentaire());
        return ResponseEntity.status(HttpStatus.CREATED).body(VueStatut.de(statut));
    }

    @PostMapping("/{id}/terminer")
    @Operation(summary = "Terminer un statut et revenir a la normale")
    public VueStatut terminer(@PathVariable Long id, @RequestBody(required = false) DemandeFin demande) {
        UtilisateurCourant acteur = UtilisateurCourant.obligatoire();
        return VueStatut.de(service.terminer(acteur.identifiant(), id, demande != null ? demande.fin() : null));
    }

    public record VueStatut(Long id, Long utilisateurId, TypeStatut type, String lieu,
                            OffsetDateTime debut, OffsetDateTime finPrevue, OffsetDateTime finReelle,
                            String commentaire, boolean ouvert) {

        static VueStatut de(StatutUtilisateur s) {
            return new VueStatut(s.getId(), s.getUtilisateurId(), s.getType(), s.getLieu(),
                    s.getDebut(), s.getFinPrevue(), s.getFinReelle(), s.getCommentaire(), s.estOuvert());
        }
    }

    public record VueStatutCourant(Long utilisateurId, TypeStatut type, VueStatut statut,
                                   Map<CategorieTache, EffetStatut> effetsParCategorie) {
    }

    public record DemandeDeclaration(Long utilisateurId, @NotNull TypeStatut type,
                                     OffsetDateTime debut, OffsetDateTime finPrevue,
                                     String lieu, String commentaire) {
    }

    public record DemandeFin(OffsetDateTime fin) {
    }
}
