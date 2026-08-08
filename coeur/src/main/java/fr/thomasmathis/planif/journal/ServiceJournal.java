package fr.thomasmathis.planif.journal;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;

import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import fr.thomasmathis.planif.commun.FiltreCorrelation;
import jakarta.persistence.criteria.Predicate;

@Service
public class ServiceJournal {

    private static final int LIMITE_MAX = 500;

    private final DepotJournal depot;
    private final Clock horloge;

    public ServiceJournal(DepotJournal depot, Clock horloge) {
        this.depot = depot;
        this.horloge = horloge;
    }

    @Transactional
    public void tracer(String acteur, String type, String entite, Long entiteId,
                       String valeurAvant, String valeurApres) {
        depot.save(new JournalEvenement(
                OffsetDateTime.now(horloge), acteur, type, entite, entiteId,
                valeurAvant, valeurApres, FiltreCorrelation.courant()));
    }

    @Transactional(readOnly = true)
    public List<JournalEvenement> rechercher(String entite, Long entiteId, OffsetDateTime depuis, int limite) {
        Pageable pagination = PageRequest.of(0, Math.min(Math.max(limite, 1), LIMITE_MAX),
                Sort.by(Sort.Direction.DESC, "date"));

        Specification<JournalEvenement> criteres = (racine, requete, constructeur) -> {
            List<Predicate> predicats = new ArrayList<>();
            if (entite != null && !entite.isBlank()) {
                predicats.add(constructeur.equal(racine.get("entite"), entite));
            }
            if (entiteId != null) {
                predicats.add(constructeur.equal(racine.get("entiteId"), entiteId));
            }
            if (depuis != null) {
                predicats.add(constructeur.greaterThanOrEqualTo(racine.get("date"), depuis));
            }
            return predicats.isEmpty()
                    ? constructeur.conjunction()
                    : constructeur.and(predicats.toArray(Predicate[]::new));
        };

        return depot.findAll(criteres, pagination).getContent();
    }
}
