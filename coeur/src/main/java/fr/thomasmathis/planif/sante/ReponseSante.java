package fr.thomasmathis.planif.sante;

import java.time.OffsetDateTime;
import java.util.Map;

import io.swagger.v3.oas.annotations.media.Schema;

@Schema(name = "Sante", description = "Etat de sante du service et de ses dependances")
public record ReponseSante(
        @Schema(example = "planif-coeur") String service,
        @Schema(example = "0.1.0") String version,
        EtatSante etat,
        @Schema(description = "Etat de chaque dependance, par nom") Map<String, EtatSante> dependances,
        @Schema(description = "Horodatage UTC de la mesure") OffsetDateTime horodatage) {
}
