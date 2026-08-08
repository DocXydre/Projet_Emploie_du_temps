package fr.thomasmathis.planif.contraintes;

import java.time.OffsetDateTime;
import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DepotTrajet extends JpaRepository<Trajet, Long> {

    List<Trajet> findByUtilisateurIdAndDepartBetweenOrderByDepartAsc(Long utilisateurId,
                                                                    OffsetDateTime debut,
                                                                    OffsetDateTime fin);

    List<Trajet> findByEtatOrderByDepartAsc(Trajet.Etat etat);
}
