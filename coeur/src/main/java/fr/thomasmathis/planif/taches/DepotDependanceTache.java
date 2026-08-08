package fr.thomasmathis.planif.taches;

import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DepotDependanceTache extends JpaRepository<DependanceTache, Long> {

    List<DependanceTache> findByDefinitionSourceId(Long definitionSourceId);

    List<DependanceTache> findByDefinitionCibleId(Long definitionCibleId);
}
