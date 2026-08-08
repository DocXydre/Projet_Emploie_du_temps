package fr.thomasmathis.planif.taches;

import java.time.LocalTime;
import java.util.List;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import fr.thomasmathis.planif.securite.UtilisateurCourant;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;

@RestController
@RequestMapping("/api/v1/taches/definitions")
@Tag(name = "Taches")
public class DefinitionControleur {

    private final ServiceDefinitionTache service;

    public DefinitionControleur(ServiceDefinitionTache service) {
        this.service = service;
    }

    @GetMapping
    @Operation(summary = "Lister les definitions de taches recurrentes")
    public List<VueDefinition> lister(@RequestParam(defaultValue = "true") boolean seulementActives) {
        return service.toutes(seulementActives).stream().map(this::enVue).toList();
    }

    @GetMapping("/{id}")
    @Operation(summary = "Detail d'une definition, dependances comprises")
    public VueDefinition detail(@PathVariable Long id) {
        return enVue(service.parId(id));
    }

    @PostMapping
    @PreAuthorize("hasRole('ADMINISTRATEUR')")
    @Operation(summary = "Creer une definition (administrateur)")
    public ResponseEntity<VueDefinition> creer(@Valid @RequestBody DemandeCreation demande) {
        DefinitionTache definition = new DefinitionTache(
                demande.code(), demande.libelle(), demande.categorie(), demande.priorite(),
                demande.dureeMinutes(), demande.intervalleMinJours(), demande.intervalleMaxJours());
        definition.setAssignationParDefaut(demande.assignationParDefaut());
        definition.setGelable(demande.gelable() == null || demande.gelable());
        definition.setFenetreHoraireDebut(demande.fenetreHoraireDebut());
        definition.setFenetreHoraireFin(demande.fenetreHoraireFin());

        DefinitionTache creee = service.creer(UtilisateurCourant.obligatoire().identifiant(), definition);
        return ResponseEntity.status(HttpStatus.CREATED).body(enVue(creee));
    }

    @PatchMapping("/{id}")
    @PreAuthorize("hasRole('ADMINISTRATEUR')")
    @Operation(summary = "Modifier une definition (administrateur)")
    public VueDefinition modifier(@PathVariable Long id,
                                  @Valid @RequestBody ServiceDefinitionTache.MiseAJour miseAJour) {
        return enVue(service.modifier(UtilisateurCourant.obligatoire().identifiant(), id, miseAJour));
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasRole('ADMINISTRATEUR')")
    @Operation(summary = "Desactiver une definition et annuler ses occurrences ouvertes")
    public ResponseEntity<Void> desactiver(@PathVariable Long id) {
        service.desactiver(UtilisateurCourant.obligatoire().identifiant(), id);
        return ResponseEntity.noContent().build();
    }

    private VueDefinition enVue(DefinitionTache definition) {
        List<VueDefinition.Declenchement> declenchements = service.dependancesDe(definition.getId()).stream()
                .map(d -> new VueDefinition.Declenchement(
                        d.getDefinitionCibleId(), d.getType(), d.getDelaiMaxHeures()))
                .toList();
        return VueDefinition.de(definition, declenchements);
    }

    public record DemandeCreation(
            @NotBlank @Pattern(regexp = "[A-Z0-9_]{3,40}",
                    message = "code en majuscules, chiffres et tirets bas") String code,
            @NotBlank String libelle,
            @NotNull CategorieTache categorie,
            @Min(0) @Max(5) short priorite,
            @Min(1) int dureeMinutes,
            @Min(1) int intervalleMinJours,
            @Min(1) int intervalleMaxJours,
            Long assignationParDefaut,
            Boolean gelable,
            LocalTime fenetreHoraireDebut,
            LocalTime fenetreHoraireFin) {
    }
}
