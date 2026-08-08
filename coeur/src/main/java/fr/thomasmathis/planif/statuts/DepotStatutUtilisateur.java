package fr.thomasmathis.planif.statuts;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DepotStatutUtilisateur extends JpaRepository<StatutUtilisateur, Long> {

    Optional<StatutUtilisateur> findByUtilisateurIdAndFinReelleIsNull(Long utilisateurId);

    List<StatutUtilisateur> findByUtilisateurIdOrderByDebutDesc(Long utilisateurId);

    List<StatutUtilisateur> findByFinReelleIsNull();
}
