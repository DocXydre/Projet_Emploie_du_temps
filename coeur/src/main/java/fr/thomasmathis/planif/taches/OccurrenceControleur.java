package fr.thomasmathis.planif.taches;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

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
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;

@RestController
@RequestMapping("/api/v1/taches/occurrences")
@Tag(name = "Taches")
public class OccurrenceControleur {

    private final ServiceOccurrenceTache service;
    private final DepotDefinitionTache depotDefinitions;
    private final Clock horloge;

    public OccurrenceControleur(ServiceOccurrenceTache service,
                                DepotDefinitionTache depotDefinitions,
                                Clock horloge) {
        this.service = service;
        this.depotDefinitions = depotDefinitions;
        this.horloge = horloge;
    }

    @GetMapping
    @Operation(summary = "Lister les occurrences, par etat et par assigne")
    public List<VueOccurrence> lister(@RequestParam(required = false) List<EtatOccurrence> etat,
                                      @RequestParam(required = false) Long assigne) {
        return enVues(service.rechercher(etat, assigne));
    }

    @GetMapping("/en-retard")
    @Operation(summary = "Occurrences dont l'echeance maximale est depassee")
    public List<VueOccurrence> enRetard() {
        return enVues(service.enRetard());
    }

    @GetMapping("/{id}")
    @Operation(summary = "Detail d'une occurrence")
    public VueOccurrence detail(@PathVariable Long id) {
        return enVues(List.of(service.parId(id))).get(0);
    }

    @PostMapping
    @Operation(summary = "Creer une occurrence a la main, eventuellement hors regles")
    public ResponseEntity<VueOccurrence> creer(@Valid @RequestBody DemandeCreation demande) {
        OccurrenceTache creee = service.creerManuelle(
                UtilisateurCourant.obligatoire(),
                demande.definitionId(), demande.assigneA(),
                demande.echeanceMin(), demande.echeanceMax(),
                demande.creneauDebut(), demande.creneauFin(), demande.motif());
        return ResponseEntity.status(HttpStatus.CREATED).body(enVues(List.of(creee)).get(0));
    }

    @PostMapping("/{id}/valider")
    @Operation(summary = "Valider une occurrence, y compris retroactivement",
            description = "La date reelle fournie devient le point de depart de la prochaine occurrence.")
    public ReponseValidation valider(@PathVariable Long id, @RequestBody(required = false) DemandeValidation demande) {
        OffsetDateTime date = demande != null ? demande.dateReelle() : null;
        var resultat = service.valider(UtilisateurCourant.obligatoire(), id, date);

        return new ReponseValidation(
                enVues(List.of(resultat.validee())).get(0),
                resultat.suivante().map(o -> enVues(List.of(o)).get(0)).orElse(null),
                enVues(resultat.declenchees()));
    }

    @PostMapping("/{id}/reporter")
    @Operation(summary = "Reporter une occurrence : elle est soldee et remplacee")
    public VueOccurrence reporter(@PathVariable Long id, @RequestBody(required = false) DemandeReport demande) {
        OccurrenceTache remplacante = service.reporter(
                UtilisateurCourant.obligatoire(), id,
                demande != null ? demande.nouvelleEcheanceMax() : null,
                demande != null ? demande.motif() : null);
        return enVues(List.of(remplacante)).get(0);
    }

    @PostMapping("/{id}/refuser")
    @Operation(summary = "Refuser une occurrence : elle est recreee desassignee")
    public VueOccurrence refuser(@PathVariable Long id, @RequestBody(required = false) DemandeMotif demande) {
        OccurrenceTache reprise = service.refuser(
                UtilisateurCourant.obligatoire(), id, demande != null ? demande.motif() : null);
        return enVues(List.of(reprise)).get(0);
    }

    @PostMapping("/{id}/reassigner")
    @Operation(summary = "Changer l'assigne d'une occurrence")
    public VueOccurrence reassigner(@PathVariable Long id, @Valid @RequestBody DemandeReassignation demande) {
        return enVues(List.of(service.reassigner(
                UtilisateurCourant.obligatoire(), id, demande.assigneA()))).get(0);
    }

    private List<VueOccurrence> enVues(List<OccurrenceTache> occurrences) {
        if (occurrences.isEmpty()) {
            return List.of();
        }
        Map<Long, DefinitionTache> definitions = depotDefinitions
                .findAllById(occurrences.stream().map(OccurrenceTache::getDefinitionId).distinct().toList())
                .stream()
                .collect(Collectors.toMap(DefinitionTache::getId, Function.identity()));

        OffsetDateTime maintenant = OffsetDateTime.now(horloge);
        return occurrences.stream()
                .map(o -> VueOccurrence.de(o, definitions.get(o.getDefinitionId()), maintenant))
                .toList();
    }

    public record DemandeCreation(@NotNull Long definitionId, Long assigneA,
                                  @NotNull OffsetDateTime echeanceMin, @NotNull OffsetDateTime echeanceMax,
                                  OffsetDateTime creneauDebut, OffsetDateTime creneauFin, String motif) {
    }

    public record DemandeValidation(OffsetDateTime dateReelle) {
    }

    public record DemandeReport(OffsetDateTime nouvelleEcheanceMax, String motif) {
    }

    public record DemandeMotif(String motif) {
    }

    public record DemandeReassignation(@NotNull Long assigneA) {
    }

    public record ReponseValidation(VueOccurrence validee, VueOccurrence suivante,
                                    List<VueOccurrence> declenchees) {
    }
}
