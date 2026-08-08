package fr.thomasmathis.planif.api;

import java.time.OffsetDateTime;

import io.swagger.v3.oas.annotations.media.Schema;

/**
 * Format unique des reponses d'erreur de l'API (cf. cahier des charges, 4.5).
 * Aucun endpoint ne renvoie une erreur dans un autre format.
 */
@Schema(name = "Erreur", description = "Reponse d'erreur normalisee")
public record ErreurApi(
        @Schema(example = "RESSOURCE_INTROUVABLE") String code,
        @Schema(example = "Occurrence introuvable : 42") String message,
        @Schema(description = "Detail technique, absent en production") String detail,
        @Schema(example = "9f1c2b7e-...") String correlation,
        OffsetDateTime horodatage) {
}
