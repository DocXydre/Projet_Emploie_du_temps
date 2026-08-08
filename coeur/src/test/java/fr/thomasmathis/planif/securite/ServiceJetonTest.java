package fr.thomasmathis.planif.securite;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.utilisateurs.Role;
import fr.thomasmathis.planif.utilisateurs.Utilisateur;

class ServiceJetonTest {

    private static final String SECRET = "secret-de-test-suffisamment-long-pour-hmac-sha256";
    private static final Instant T0 = Instant.parse("2026-09-17T20:00:00Z");

    private ServiceJeton service(Clock horloge) {
        return new ServiceJeton(horloge, SECRET, 30, 30);
    }

    private Utilisateur thomas() {
        Utilisateur u = new Utilisateur("Thomas", "thomas", "peu-importe", Role.ADMINISTRATEUR);
        ReflectionTestUtils.setField(u, "id", 1L);
        return u;
    }

    @Test
    void un_jeton_d_acces_porte_l_identite_et_le_role() {
        ServiceJeton service = service(Clock.fixed(T0, ZoneOffset.UTC));

        var lu = service.lire(service.emettreAcces(thomas()), ServiceJeton.USAGE_ACCES);

        assertThat(lu.utilisateurId()).isEqualTo(1L);
        assertThat(lu.identifiant()).isEqualTo("thomas");
        assertThat(lu.role()).isEqualTo(Role.ADMINISTRATEUR);
    }

    @Test
    void un_jeton_de_rafraichissement_ne_vaut_pas_jeton_d_acces() {
        ServiceJeton service = service(Clock.fixed(T0, ZoneOffset.UTC));
        String rafraichissement = service.emettreRafraichissement(thomas());

        assertThatThrownBy(() -> service.lire(rafraichissement, ServiceJeton.USAGE_ACCES))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("ne peut pas etre utilise ici");
    }

    @Test
    void un_jeton_expire_est_refuse() {
        String jeton = service(Clock.fixed(T0, ZoneOffset.UTC)).emettreAcces(thomas());

        ServiceJeton plusTard = service(Clock.fixed(T0.plus(Duration.ofHours(2)), ZoneOffset.UTC));

        assertThatThrownBy(() -> plusTard.lire(jeton, ServiceJeton.USAGE_ACCES))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("expire");
    }

    @Test
    void un_jeton_signe_avec_une_autre_cle_est_refuse() {
        String jeton = service(Clock.fixed(T0, ZoneOffset.UTC)).emettreAcces(thomas());

        ServiceJeton autre = new ServiceJeton(Clock.fixed(T0, ZoneOffset.UTC),
                "une-tout-autre-cle-de-signature-de-longueur-suffisante", 30, 30);

        assertThatThrownBy(() -> autre.lire(jeton, ServiceJeton.USAGE_ACCES))
                .isInstanceOf(ExceptionMetier.class);
    }

    @Test
    void un_secret_trop_court_empeche_le_demarrage() {
        assertThatThrownBy(() -> new ServiceJeton(Clock.fixed(T0, ZoneOffset.UTC), "trop-court", 30, 30))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("32 caracteres");
    }
}
