package fr.thomasmathis.planif.taches;

import java.time.OffsetDateTime;
import java.util.Set;

import io.swagger.v3.oas.annotations.media.Schema;

/**
 * Representation d'une occurrence pour les clients.
 *
 * <p>Elle porte volontairement des informations derivees : le libelle et la
 * categorie de la definition, le retard, et les actions possibles. Aucune
 * logique metier ne doit vivre dans le client : si une application devait
 * calculer elle-meme qu'une tache est en retard, c'est que l'API aurait du le
 * dire (cf. cahier des charges, 8.4).</p>
 */
@Schema(name = "Occurrence")
public record VueOccurrence(
        Long id,
        Long definitionId,
        String definitionCode,
        String libelle,
        CategorieTache categorie,
        short priorite,
        int dureeMinutes,
        Long assigneA,
        OffsetDateTime echeanceMin,
        OffsetDateTime echeanceMax,
        OffsetDateTime creneauDebut,
        OffsetDateTime creneauFin,
        boolean epinglee,
        EtatOccurrence etat,
        OrigineOccurrence origine,
        @Schema(description = "Motif de placement ou de changement d'etat") String motif,
        @Schema(description = "Calcule par l'API, jamais par le client") boolean enRetard,
        @Schema(description = "Transitions possibles depuis l'etat courant") Set<EtatOccurrence> actionsPossibles,
        OffsetDateTime valideeLe,
        Long valideePar,
        Long occurrenceParenteId) {

    public static VueOccurrence de(OccurrenceTache o, DefinitionTache d, OffsetDateTime maintenant) {
        return new VueOccurrence(
                o.getId(),
                o.getDefinitionId(),
                d != null ? d.getCode() : null,
                d != null ? d.getLibelle() : null,
                d != null ? d.getCategorie() : null,
                d != null ? d.getPriorite() : 0,
                d != null ? d.getDureeMinutes() : 0,
                o.getAssigneA(),
                o.getEcheanceMin(),
                o.getEcheanceMax(),
                o.getCreneauDebut(),
                o.getCreneauFin(),
                o.isEpinglee(),
                o.getEtat(),
                o.getOrigine(),
                o.getMotif(),
                o.estEnRetard(maintenant),
                MachineEtatsOccurrence.transitionsPossibles(o.getEtat()),
                o.getValideeLe(),
                o.getValideePar(),
                o.getOccurrenceParenteId());
    }
}
