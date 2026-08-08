package fr.thomasmathis.planif.taches;

import java.time.LocalTime;
import java.util.List;

import io.swagger.v3.oas.annotations.media.Schema;

@Schema(name = "DefinitionTache")
public record VueDefinition(
        Long id,
        String code,
        String libelle,
        CategorieTache categorie,
        @Schema(description = "P0 a P5, le plus bas gagne") short priorite,
        int dureeMinutes,
        int intervalleMinJours,
        int intervalleMaxJours,
        Long assignationParDefaut,
        boolean gelable,
        LocalTime fenetreHoraireDebut,
        LocalTime fenetreHoraireFin,
        boolean active,
        @Schema(description = "Definitions declenchees par la validation de celle-ci")
        List<Declenchement> declenche) {

    public static VueDefinition de(DefinitionTache d, List<Declenchement> declenche) {
        return new VueDefinition(
                d.getId(), d.getCode(), d.getLibelle(), d.getCategorie(), d.getPriorite(),
                d.getDureeMinutes(), d.getIntervalleMinJours(), d.getIntervalleMaxJours(),
                d.getAssignationParDefaut(), d.isGelable(),
                d.getFenetreHoraireDebut(), d.getFenetreHoraireFin(), d.isActive(),
                declenche);
    }

    public record Declenchement(Long definitionCibleId, TypeDependance type, int delaiMaxHeures) {
    }
}
