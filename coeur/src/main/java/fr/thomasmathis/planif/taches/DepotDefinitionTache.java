package fr.thomasmathis.planif.taches;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DepotDefinitionTache extends JpaRepository<DefinitionTache, Long> {

    Optional<DefinitionTache> findByCode(String code);

    boolean existsByCode(String code);

    List<DefinitionTache> findByActiveTrueOrderByPrioriteAscCodeAsc();

    List<DefinitionTache> findByCategorieOrderByCodeAsc(CategorieTache categorie);
}
