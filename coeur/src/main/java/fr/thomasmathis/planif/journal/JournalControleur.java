package fr.thomasmathis.planif.journal;

import java.time.OffsetDateTime;
import java.util.List;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

@RestController
@RequestMapping("/api/v1/journal")
@Tag(name = "Systeme")
public class JournalControleur {

    private final ServiceJournal service;

    public JournalControleur(ServiceJournal service) {
        this.service = service;
    }

    @GetMapping
    @PreAuthorize("hasRole('ADMINISTRATEUR')")
    @Operation(summary = "Journal filtrable des actions et des changements d'etat")
    public List<VueEvenement> rechercher(
            @RequestParam(required = false) String entite,
            @RequestParam(required = false) Long entiteId,
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime depuis,
            @RequestParam(defaultValue = "100") int limite) {
        return service.rechercher(entite, entiteId, depuis, limite).stream().map(VueEvenement::de).toList();
    }

    public record VueEvenement(Long id, OffsetDateTime date, String acteur, String type,
                               String entite, Long entiteId, String valeurAvant, String valeurApres,
                               String correlation) {

        static VueEvenement de(JournalEvenement e) {
            return new VueEvenement(e.getId(), e.getDate(), e.getActeur(), e.getType(),
                    e.getEntite(), e.getEntiteId(), e.getValeurAvant(), e.getValeurApres(),
                    e.getCorrelation());
        }
    }
}
