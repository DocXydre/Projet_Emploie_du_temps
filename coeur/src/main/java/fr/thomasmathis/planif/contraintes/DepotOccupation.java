package fr.thomasmathis.planif.contraintes;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface DepotOccupation extends JpaRepository<Occupation, Long> {

    Optional<Occupation> findBySourceIdAndCleExterne(Long sourceId, String cleExterne);

    /**
     * Occupations non annulees chevauchant la periode. Base de la passe 1 du moteur.
     *
     * <p>Deux methodes plutot qu'un {@code :utilisateurId IS NULL OR ...} :
     * PostgreSQL ne sait pas deduire le type d'un parametre nul et rejette la
     * requete.</p>
     */
    @Query("""
            SELECT o FROM Occupation o
            WHERE o.annulee = false
              AND o.utilisateurId = :utilisateurId
              AND o.debut < :fin
              AND o.fin > :debut
            ORDER BY o.debut ASC
            """)
    List<Occupation> surPeriodePourUtilisateur(@Param("utilisateurId") Long utilisateurId,
                                               @Param("debut") OffsetDateTime debut,
                                               @Param("fin") OffsetDateTime fin);

    @Query("""
            SELECT o FROM Occupation o
            WHERE o.annulee = false
              AND o.debut < :fin
              AND o.fin > :debut
            ORDER BY o.debut ASC
            """)
    List<Occupation> surPeriode(@Param("debut") OffsetDateTime debut,
                                @Param("fin") OffsetDateTime fin);

    List<Occupation> findBySourceIdAndAnnuleeFalse(Long sourceId);
}
