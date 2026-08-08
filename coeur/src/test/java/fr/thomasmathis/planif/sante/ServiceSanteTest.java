package fr.thomasmathis.planif.sante;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.core.JdbcTemplate;

class ServiceSanteTest {

    private final Clock horlogeFigee =
            Clock.fixed(Instant.parse("2026-09-15T18:00:00Z"), ZoneOffset.UTC);

    @Test
    void base_joignable_donne_un_etat_ok() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject("SELECT 1", Integer.class)).thenReturn(1);

        ReponseSante reponse = new ServiceSante(jdbc, horlogeFigee, "0.1.0").etatCourant();

        assertThat(reponse.etat()).isEqualTo(EtatSante.OK);
        assertThat(reponse.dependances()).containsEntry("postgresql", EtatSante.OK);
        assertThat(reponse.service()).isEqualTo("planif-coeur");
        assertThat(reponse.version()).isEqualTo("0.1.0");
        assertThat(reponse.horodatage().toInstant()).isEqualTo(Instant.parse("2026-09-15T18:00:00Z"));
    }

    @Test
    void base_injoignable_donne_un_etat_mort_sans_lever_d_exception() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject("SELECT 1", Integer.class))
                .thenThrow(new DataAccessResourceFailureException("connexion refusee"));

        ReponseSante reponse = new ServiceSante(jdbc, horlogeFigee, "0.1.0").etatCourant();

        assertThat(reponse.etat()).isEqualTo(EtatSante.MORT);
        assertThat(reponse.dependances()).containsEntry("postgresql", EtatSante.MORT);
    }
}
