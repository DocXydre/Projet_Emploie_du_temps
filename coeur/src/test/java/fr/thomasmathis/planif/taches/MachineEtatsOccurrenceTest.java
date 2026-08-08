package fr.thomasmathis.planif.taches;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.OffsetDateTime;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import fr.thomasmathis.planif.commun.ExceptionMetier;

class MachineEtatsOccurrenceTest {

    private static final OffsetDateTime T0 = OffsetDateTime.parse("2026-09-15T08:00:00Z");

    private OccurrenceTache occurrence() {
        return new OccurrenceTache(1L, T0, T0.plusDays(2), OrigineOccurrence.AUTOMATIQUE);
    }

    @Test
    void une_occurrence_nait_planifiee() {
        assertThat(occurrence().getEtat()).isEqualTo(EtatOccurrence.PLANIFIEE);
    }

    @Test
    void la_validation_retroactive_est_possible_sans_notification_prealable() {
        OccurrenceTache o = occurrence();
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.VALIDEE);
        assertThat(o.getEtat()).isEqualTo(EtatOccurrence.VALIDEE);
    }

    @Test
    void le_degel_ramene_a_planifiee_et_jamais_directement_a_notifiee() {
        OccurrenceTache o = occurrence();
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.GELEE);

        assertThat(MachineEtatsOccurrence.transitionAutorisee(EtatOccurrence.GELEE, EtatOccurrence.NOTIFIEE))
                .isFalse();

        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.PLANIFIEE);
        assertThat(o.getEtat()).isEqualTo(EtatOccurrence.PLANIFIEE);
    }

    @ParameterizedTest
    @EnumSource(value = EtatOccurrence.class, names = {"VALIDEE", "REPORTEE", "REFUSEE", "ANNULEE"})
    void les_etats_terminaux_n_admettent_aucune_sortie(EtatOccurrence terminal) {
        assertThat(terminal.estTerminal()).isTrue();
        assertThat(MachineEtatsOccurrence.transitionsPossibles(terminal)).isEmpty();
    }

    @Test
    void une_occurrence_validee_ne_peut_pas_etre_revalidee_ni_reouverte() {
        OccurrenceTache o = occurrence();
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.VALIDEE);

        assertThatThrownBy(() -> MachineEtatsOccurrence.appliquer(o, EtatOccurrence.PLANIFIEE))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("interdite");
    }

    @Test
    void une_occurrence_non_planifiable_reste_recuperable() {
        OccurrenceTache o = occurrence();
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.NON_PLANIFIABLE);

        assertThat(MachineEtatsOccurrence.transitionsPossibles(EtatOccurrence.NON_PLANIFIABLE))
                .contains(EtatOccurrence.PLANIFIEE, EtatOccurrence.VALIDEE);
    }

    @Test
    void renotifier_est_sans_effet_et_sans_erreur() {
        OccurrenceTache o = occurrence();
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.NOTIFIEE);
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.NOTIFIEE);
        assertThat(o.getEtat()).isEqualTo(EtatOccurrence.NOTIFIEE);
    }

    @Test
    void revalider_une_occurrence_deja_validee_est_refuse() {
        // Sinon une double validation ecraserait la date reelle et decalerait
        // toute la recurrence qui en decoule.
        OccurrenceTache o = occurrence();
        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.VALIDEE);

        assertThatThrownBy(() -> MachineEtatsOccurrence.appliquer(o, EtatOccurrence.VALIDEE))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("interdite");
    }

    @Test
    void une_occurrence_ouverte_dont_l_echeance_est_passee_est_en_retard() {
        OccurrenceTache o = occurrence();
        assertThat(o.estEnRetard(T0.plusDays(3))).isTrue();
        assertThat(o.estEnRetard(T0.plusHours(1))).isFalse();

        MachineEtatsOccurrence.appliquer(o, EtatOccurrence.VALIDEE);
        assertThat(o.estEnRetard(T0.plusDays(3))).isFalse();
    }
}
