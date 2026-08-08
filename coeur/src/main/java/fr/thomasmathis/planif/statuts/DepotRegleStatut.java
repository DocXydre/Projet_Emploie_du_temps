package fr.thomasmathis.planif.statuts;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

import fr.thomasmathis.planif.taches.CategorieTache;

public interface DepotRegleStatut extends JpaRepository<RegleStatut, Long> {

    Optional<RegleStatut> findByTypeStatutAndCategorieTache(TypeStatut typeStatut, CategorieTache categorie);

    List<RegleStatut> findByTypeStatut(TypeStatut typeStatut);
}
