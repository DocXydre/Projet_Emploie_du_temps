package fr.thomasmathis.planif.contraintes;

import java.util.List;
import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DepotSourceContrainte extends JpaRepository<SourceContrainte, Long> {

    Optional<SourceContrainte> findByCode(String code);

    List<SourceContrainte> findAllByOrderByCodeAsc();
}
