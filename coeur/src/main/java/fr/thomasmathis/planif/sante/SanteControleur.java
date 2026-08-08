package fr.thomasmathis.planif.sante;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Deux chemins volontairement :
 * <ul>
 *   <li>{@code /sante} : sonde d'infrastructure, hors versionnement, utilisee par
 *       Docker et la supervision. Son contrat ne bougera pas.</li>
 *   <li>{@code /api/v1/sante} : la meme information, dans l'API versionnee
 *       consommee par les clients (bot, future application Angular).</li>
 * </ul>
 */
@RestController
@Tag(name = "Systeme")
public class SanteControleur {

    private final ServiceSante service;

    public SanteControleur(ServiceSante service) {
        this.service = service;
    }

    @GetMapping({"/sante", "/api/v1/sante"})
    @Operation(summary = "Etat de sante du service et de ses dependances")
    public ResponseEntity<ReponseSante> sante() {
        ReponseSante reponse = service.etatCourant();
        HttpStatus statut = reponse.etat() == EtatSante.MORT
                ? HttpStatus.SERVICE_UNAVAILABLE
                : HttpStatus.OK;
        return ResponseEntity.status(statut).body(reponse);
    }
}
