package fr.thomasmathis.planif.taches;

import java.time.Clock;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.util.List;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.journal.ServiceJournal;

@Service
public class ServiceDefinitionTache {

    private final DepotDefinitionTache depot;
    private final DepotDependanceTache depotDependances;
    private final DepotOccurrenceTache depotOccurrences;
    private final ServiceJournal journal;
    private final Clock horloge;

    public ServiceDefinitionTache(DepotDefinitionTache depot,
                                  DepotDependanceTache depotDependances,
                                  DepotOccurrenceTache depotOccurrences,
                                  ServiceJournal journal,
                                  Clock horloge) {
        this.depot = depot;
        this.depotDependances = depotDependances;
        this.depotOccurrences = depotOccurrences;
        this.journal = journal;
        this.horloge = horloge;
    }

    @Transactional(readOnly = true)
    public List<DefinitionTache> toutes(boolean seulementActives) {
        return seulementActives ? depot.findByActiveTrueOrderByPrioriteAscCodeAsc() : depot.findAll();
    }

    @Transactional(readOnly = true)
    public DefinitionTache parId(Long id) {
        return depot.findById(id).orElseThrow(() -> ExceptionMetier.introuvable("Definition", id));
    }

    @Transactional(readOnly = true)
    public DefinitionTache parCode(String code) {
        return depot.findByCode(code).orElseThrow(() -> ExceptionMetier.introuvable("Definition", code));
    }

    @Transactional(readOnly = true)
    public List<DependanceTache> dependancesDe(Long definitionId) {
        return depotDependances.findByDefinitionSourceId(definitionId);
    }

    @Transactional
    public DefinitionTache creer(String acteur, DefinitionTache definition) {
        if (depot.existsByCode(definition.getCode())) {
            throw ExceptionMetier.regleViolee("Code de definition deja utilise : " + definition.getCode());
        }
        verifierCoherence(definition);
        DefinitionTache enregistree = depot.save(definition);
        journal.tracer(acteur, "DEFINITION_CREEE", "definition_tache", enregistree.getId(),
                null, enregistree.getCode());
        return enregistree;
    }

    @Transactional
    public DefinitionTache modifier(String acteur, Long id, MiseAJour miseAJour) {
        DefinitionTache definition = parId(id);
        String avant = decrire(definition);

        if (miseAJour.libelle() != null) {
            definition.setLibelle(miseAJour.libelle());
        }
        if (miseAJour.priorite() != null) {
            definition.setPriorite(miseAJour.priorite());
        }
        if (miseAJour.dureeMinutes() != null) {
            definition.setDureeMinutes(miseAJour.dureeMinutes());
        }
        if (miseAJour.intervalleMinJours() != null) {
            definition.setIntervalleMinJours(miseAJour.intervalleMinJours());
        }
        if (miseAJour.intervalleMaxJours() != null) {
            definition.setIntervalleMaxJours(miseAJour.intervalleMaxJours());
        }
        if (miseAJour.assignationParDefaut() != null) {
            definition.setAssignationParDefaut(miseAJour.assignationParDefaut());
        }
        if (miseAJour.gelable() != null) {
            definition.setGelable(miseAJour.gelable());
        }
        if (miseAJour.fenetreHoraireDebut() != null) {
            definition.setFenetreHoraireDebut(miseAJour.fenetreHoraireDebut());
        }
        if (miseAJour.fenetreHoraireFin() != null) {
            definition.setFenetreHoraireFin(miseAJour.fenetreHoraireFin());
        }
        if (miseAJour.active() != null) {
            definition.setActive(miseAJour.active());
        }

        verifierCoherence(definition);
        DefinitionTache enregistree = depot.save(definition);
        journal.tracer(acteur, "DEFINITION_MODIFIEE", "definition_tache", id, avant, decrire(enregistree));
        return enregistree;
    }

    /**
     * Desactivation plutot que suppression : les occurrences passees gardent
     * leur definition, et l'historique reste lisible. Les occurrences ouvertes
     * sont annulees, pas laissees orphelines.
     */
    @Transactional
    public void desactiver(String acteur, Long id) {
        DefinitionTache definition = parId(id);
        definition.setActive(false);
        depot.save(definition);

        List<OccurrenceTache> ouvertes = depotOccurrences.findByDefinitionIdAndEtatInOrderByEcheanceMaxAsc(
                id, List.of(EtatOccurrence.PLANIFIEE, EtatOccurrence.NOTIFIEE,
                        EtatOccurrence.GELEE, EtatOccurrence.NON_PLANIFIABLE));

        OffsetDateTime maintenant = OffsetDateTime.now(horloge);
        for (OccurrenceTache occurrence : ouvertes) {
            MachineEtatsOccurrence.appliquer(occurrence, EtatOccurrence.ANNULEE);
            occurrence.setMotif("Definition desactivee le " + maintenant);
            depotOccurrences.save(occurrence);
        }

        journal.tracer(acteur, "DEFINITION_DESACTIVEE", "definition_tache", id,
                "active", "inactive, %d occurrence(s) annulee(s)".formatted(ouvertes.size()));
    }

    private void verifierCoherence(DefinitionTache definition) {
        if (definition.getIntervalleMaxJours() < definition.getIntervalleMinJours()) {
            throw ExceptionMetier.regleViolee(
                    "L'intervalle maximum doit etre superieur ou egal a l'intervalle minimum");
        }
        LocalTime debut = definition.getFenetreHoraireDebut();
        LocalTime fin = definition.getFenetreHoraireFin();
        if ((debut == null) != (fin == null)) {
            throw ExceptionMetier.regleViolee(
                    "La fenetre horaire doit etre renseignee des deux cotes, ou pas du tout");
        }
    }

    private String decrire(DefinitionTache d) {
        return "%s p%d %d min, %d-%d j, active=%s"
                .formatted(d.getCode(), d.getPriorite(), d.getDureeMinutes(),
                        d.getIntervalleMinJours(), d.getIntervalleMaxJours(), d.isActive());
    }

    /** Modification partielle : tout champ nul est laisse inchange. */
    public record MiseAJour(String libelle, Short priorite, Integer dureeMinutes,
                            Integer intervalleMinJours, Integer intervalleMaxJours,
                            Long assignationParDefaut, Boolean gelable,
                            LocalTime fenetreHoraireDebut, LocalTime fenetreHoraireFin,
                            Boolean active) {
    }
}
