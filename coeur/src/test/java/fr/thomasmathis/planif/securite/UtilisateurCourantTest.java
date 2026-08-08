package fr.thomasmathis.planif.securite;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.utilisateurs.Role;

/** Matrice de permissions de la section 3.3. */
class UtilisateurCourantTest {

    private static final UtilisateurCourant THOMAS = new UtilisateurCourant(1L, "thomas", Role.ADMINISTRATEUR);
    private static final UtilisateurCourant LORETTE = new UtilisateurCourant(2L, "lorette", Role.STANDARD);

    @Test
    void chacun_agit_sur_ses_propres_taches() {
        assertThatCode(() -> LORETTE.verifierDroitSur(2L)).doesNotThrowAnyException();
        assertThatCode(() -> THOMAS.verifierDroitSur(1L)).doesNotThrowAnyException();
    }

    @Test
    void une_tache_non_assignee_est_ouverte_a_tous() {
        assertThatCode(() -> LORETTE.verifierDroitSur(null)).doesNotThrowAnyException();
    }

    @Test
    void l_administrateur_peut_agir_pour_autrui() {
        assertThatCode(() -> THOMAS.verifierDroitSur(2L)).doesNotThrowAnyException();
        assertThat(THOMAS.agitPourAutrui(2L)).isTrue();
        assertThat(THOMAS.agitPourAutrui(1L)).isFalse();
    }

    @Test
    void un_utilisateur_standard_ne_peut_pas_agir_pour_autrui() {
        assertThatThrownBy(() -> LORETTE.verifierDroitSur(1L))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("assignee a un autre utilisateur");
    }

    @Test
    void les_autorites_spring_derivent_du_role() {
        assertThat(THOMAS.autorites()).extracting(Object::toString).containsExactly("ROLE_ADMINISTRATEUR");
        assertThat(LORETTE.autorites()).extracting(Object::toString).containsExactly("ROLE_STANDARD");
    }
}
