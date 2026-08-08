package fr.thomasmathis.planif.contraintes;

import java.time.OffsetDateTime;
import java.util.List;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import fr.thomasmathis.planif.sante.EtatSante;
import fr.thomasmathis.planif.securite.UtilisateurCourant;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

@RestController
@RequestMapping("/api/v1")
@Tag(name = "Contraintes")
public class OccupationControleur {

    private final ServiceOccupation service;

    public OccupationControleur(ServiceOccupation service) {
        this.service = service;
    }

    @GetMapping("/occupations")
    @Operation(summary = "Occupations sur une periode, toutes sources confondues")
    public List<VueOccupation> lister(
            @RequestParam(required = false) Long utilisateur,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime debut,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime fin) {
        return service.surPeriode(utilisateur, debut, fin).stream().map(VueOccupation::de).toList();
    }

    @PostMapping("/occupations")
    @Operation(summary = "Saisir une occupation a la main",
            description = "Mode degrade utilisable en 30 secondes quand un collecteur est mort.")
    public ResponseEntity<VueOccupation> saisir(@Valid @RequestBody DemandeSaisie demande) {
        Occupation creee = service.saisirManuellement(
                UtilisateurCourant.obligatoire().identifiant(),
                demande.utilisateurId(), demande.type(), demande.debut(), demande.fin(),
                demande.libelle(), demande.lieu());
        return ResponseEntity.status(HttpStatus.CREATED).body(VueOccupation.de(creee));
    }

    @DeleteMapping("/occupations/{id}")
    @Operation(summary = "Annuler une occupation")
    public ResponseEntity<Void> supprimer(@PathVariable Long id) {
        service.supprimer(UtilisateurCourant.obligatoire().identifiant(), id);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/sources/sante")
    @Operation(summary = "Etat de fraicheur de chaque source de contraintes")
    public List<VueSource> sante() {
        return service.rafraichirEtatsSante().stream().map(VueSource::de).toList();
    }

    public record VueOccupation(Long id, Long utilisateurId, Long sourceId, TypeOccupation type,
                                OffsetDateTime debut, OffsetDateTime fin, String lieu, String libelle,
                                String cleExterne, boolean annulee, OffsetDateTime collecteeLe) {

        static VueOccupation de(Occupation o) {
            return new VueOccupation(o.getId(), o.getUtilisateurId(), o.getSourceId(), o.getType(),
                    o.getDebut(), o.getFin(), o.getLieu(), o.getLibelle(),
                    o.getCleExterne(), o.isAnnulee(), o.getCollecteeLe());
        }
    }

    public record VueSource(Long id, String code, String libelle, TypeCollecte typeCollecte,
                            EtatSante etatSante, OffsetDateTime derniereCollecteOk,
                            OffsetDateTime derniereCollecteTentee, int ttlFraicheurHeures, boolean active) {

        static VueSource de(SourceContrainte s) {
            return new VueSource(s.getId(), s.getCode(), s.getLibelle(), s.getTypeCollecte(),
                    s.getEtatSante(), s.getDerniereCollecteOk(), s.getDerniereCollecteTentee(),
                    s.getTtlFraicheurHeures(), s.isActive());
        }
    }

    public record DemandeSaisie(@NotNull Long utilisateurId, @NotNull TypeOccupation type,
                                @NotNull OffsetDateTime debut, @NotNull OffsetDateTime fin,
                                @NotBlank String libelle, String lieu) {
    }
}
