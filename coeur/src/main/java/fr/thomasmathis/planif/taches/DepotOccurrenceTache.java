package fr.thomasmathis.planif.taches;

import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface DepotOccurrenceTache extends JpaRepository<OccurrenceTache, Long> {

    List<OccurrenceTache> findByEtatInOrderByEcheanceMaxAsc(Collection<EtatOccurrence> etats);

    List<OccurrenceTache> findByAssigneAAndEtatInOrderByEcheanceMaxAsc(Long assigneA,
                                                                      Collection<EtatOccurrence> etats);

    List<OccurrenceTache> findByDefinitionIdAndEtatInOrderByEcheanceMaxAsc(Long definitionId,
                                                                          Collection<EtatOccurrence> etats);

    /**
     * Derniere validation reelle d'une definition. C'est elle, et non la date
     * theorique, qui sert de point de depart a la recurrence (6.4, passe 3).
     */
    @Query("""
            SELECT MAX(o.valideeLe) FROM OccurrenceTache o
            WHERE o.definitionId = :definitionId AND o.etat = fr.thomasmathis.planif.taches.EtatOccurrence.VALIDEE
            """)
    OffsetDateTime derniereValidation(@Param("definitionId") Long definitionId);

    /**
     * Occurrences ouvertes d'une definition dont la fenetre d'echeance chevauche
     * l'intervalle donne. Sert a la regle anti-doublon sur les dependances :
     * on repositionne une occurrence existante au lieu d'en creer une seconde.
     */
    @Query("""
            SELECT o FROM OccurrenceTache o
            WHERE o.definitionId = :definitionId
              AND o.etat IN :etats
              AND o.echeanceMin <= :fin
              AND o.echeanceMax >= :debut
            ORDER BY o.echeanceMax ASC
            """)
    List<OccurrenceTache> ouvertesDansFenetre(@Param("definitionId") Long definitionId,
                                              @Param("etats") Collection<EtatOccurrence> etats,
                                              @Param("debut") OffsetDateTime debut,
                                              @Param("fin") OffsetDateTime fin);

    @Query("""
            SELECT o FROM OccurrenceTache o
            WHERE o.etat IN :etats AND o.echeanceMax < :maintenant
            ORDER BY o.echeanceMax ASC
            """)
    List<OccurrenceTache> enRetard(@Param("etats") Collection<EtatOccurrence> etats,
                                   @Param("maintenant") OffsetDateTime maintenant);
}
