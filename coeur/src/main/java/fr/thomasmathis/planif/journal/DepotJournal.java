package fr.thomasmathis.planif.journal;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

/**
 * Le journal se filtre sur des criteres tous optionnels. Une requete JPQL du
 * type {@code (:entite IS NULL OR ...)} echouerait sur PostgreSQL, qui ne peut
 * pas deduire le type d'un parametre nul : on passe donc par des Specifications.
 */
public interface DepotJournal extends JpaRepository<JournalEvenement, Long>,
        JpaSpecificationExecutor<JournalEvenement> {
}
