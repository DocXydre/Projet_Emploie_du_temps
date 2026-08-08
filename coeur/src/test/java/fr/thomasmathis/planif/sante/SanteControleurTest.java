package fr.thomasmathis.planif.sante;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.OffsetDateTime;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/**
 * Le contrat de /sante est fige des le lot 0 : c'est la sonde utilisee par
 * Docker, la CI et la supervision. Ce test protege ce contrat.
 */
class SanteControleurTest {

    private ServiceSante service;
    private MockMvc mockMvc;

    @BeforeEach
    void preparer() {
        service = mock(ServiceSante.class);
        mockMvc = MockMvcBuilders.standaloneSetup(new SanteControleur(service)).build();
    }

    @Test
    void repond_200_sur_les_deux_chemins_quand_tout_va_bien() throws Exception {
        when(service.etatCourant()).thenReturn(sante(EtatSante.OK));

        for (String chemin : new String[] {"/sante", "/api/v1/sante"}) {
            mockMvc.perform(get(chemin))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.service").value("planif-coeur"))
                    .andExpect(jsonPath("$.etat").value("OK"))
                    .andExpect(jsonPath("$.dependances.postgresql").value("OK"));
        }
    }

    @Test
    void repond_503_quand_une_dependance_est_morte() throws Exception {
        when(service.etatCourant()).thenReturn(sante(EtatSante.MORT));

        mockMvc.perform(get("/sante"))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.etat").value("MORT"));
    }

    private ReponseSante sante(EtatSante etat) {
        return new ReponseSante("planif-coeur", "0.1.0", etat,
                Map.of("postgresql", etat), OffsetDateTime.parse("2026-09-15T18:00:00Z"));
    }
}
