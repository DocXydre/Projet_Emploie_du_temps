package fr.thomasmathis.planif.utilisateurs;

import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DepotUtilisateur extends JpaRepository<Utilisateur, Long> {

    Optional<Utilisateur> findByIdentifiant(String identifiant);

    boolean existsByIdentifiant(String identifiant);
}
