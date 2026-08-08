package fr.thomasmathis.planif.taches;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import fr.thomasmathis.planif.commun.ExceptionMetier;
import fr.thomasmathis.planif.journal.ServiceJournal;
import fr.thomasmathis.planif.securite.UtilisateurCourant;
import fr.thomasmathis.planif.utilisateurs.Role;

/**
 * Scenarios concrets du cycle de vie d'une occurrence.
 *
 * <p>Ces tests protegent trois regles qui, si elles cassent, rendent le systeme
 * inutilisable au quotidien : la recurrence qui repart de la date reelle, la
 * dependance qui ne cree pas de doublon, et la permission de validation.</p>
 */
class ServiceOccurrenceTacheTest {

    /** Jeudi 17 septembre 2026, 20h00 UTC. */
    private static final Instant MAINTENANT = Instant.parse("2026-09-17T20:00:00Z");
    private static final Clock HORLOGE = Clock.fixed(MAINTENANT, ZoneOffset.UTC);
    private static final OffsetDateTime T = OffsetDateTime.ofInstant(MAINTENANT, ZoneOffset.UTC);

    private static final UtilisateurCourant THOMAS = new UtilisateurCourant(1L, "thomas", Role.ADMINISTRATEUR);
    private static final UtilisateurCourant LORETTE = new UtilisateurCourant(2L, "lorette", Role.STANDARD);

    private DepotOccurrenceTache depot;
    private DepotDefinitionTache depotDefinitions;
    private DepotDependanceTache depotDependances;
    private ServiceJournal journal;
    private ServiceOccurrenceTache service;

    @BeforeEach
    void preparer() {
        depot = mock(DepotOccurrenceTache.class);
        depotDefinitions = mock(DepotDefinitionTache.class);
        depotDependances = mock(DepotDependanceTache.class);
        journal = mock(ServiceJournal.class);
        service = new ServiceOccurrenceTache(depot, depotDefinitions, depotDependances, journal, HORLOGE);

        when(depot.save(any(OccurrenceTache.class))).thenAnswer(appel -> appel.getArgument(0));
        when(depotDependances.findByDefinitionSourceId(anyLong())).thenReturn(List.of());
    }

    // ------------------------------------------------------------------
    // Recurrence depuis la date de validation reelle
    // ------------------------------------------------------------------

    @Test
    void la_prochaine_occurrence_part_de_la_date_reelle_et_non_de_l_echeance_theorique() {
        // Aspirateur tous les 2 a 3 jours, du 14 au 15 septembre. Fait en retard, le 17 au soir.
        DefinitionTache aspirateur = definition(10L, "ASPIRATEUR", 2, 3, true);
        OccurrenceTache enRetard = occurrence(100L, aspirateur.getId(),
                T.minusDays(3), T.minusDays(2));

        when(depot.findById(100L)).thenReturn(Optional.of(enRetard));
        when(depotDefinitions.findById(10L)).thenReturn(Optional.of(aspirateur));

        var resultat = service.valider(THOMAS, 100L, null);

        assertThat(resultat.validee().getEtat()).isEqualTo(EtatOccurrence.VALIDEE);
        assertThat(resultat.validee().getValideeLe()).isEqualTo(T);

        OccurrenceTache suivante = resultat.suivante().orElseThrow();
        assertThat(suivante.getEcheanceMin()).isEqualTo(T.plusDays(2));
        assertThat(suivante.getEcheanceMax()).isEqualTo(T.plusDays(3));
        assertThat(suivante.getOrigine()).isEqualTo(OrigineOccurrence.AUTOMATIQUE);
        assertThat(suivante.getOccurrenceParenteId()).isEqualTo(100L);
    }

    @Test
    void la_validation_retroactive_utilise_la_date_declaree() {
        DefinitionTache aspirateur = definition(10L, "ASPIRATEUR", 2, 3, true);
        OccurrenceTache o = occurrence(100L, 10L, T.minusDays(2), T.minusDays(1));
        when(depot.findById(100L)).thenReturn(Optional.of(o));
        when(depotDefinitions.findById(10L)).thenReturn(Optional.of(aspirateur));

        OffsetDateTime hierSoir = T.minusDays(1);
        var resultat = service.valider(THOMAS, 100L, hierSoir);

        assertThat(resultat.validee().getValideeLe()).isEqualTo(hierSoir);
        assertThat(resultat.suivante().orElseThrow().getEcheanceMin()).isEqualTo(hierSoir.plusDays(2));
    }

    @Test
    void valider_dans_le_futur_est_refuse() {
        DefinitionTache aspirateur = definition(10L, "ASPIRATEUR", 2, 3, true);
        OccurrenceTache o = occurrence(100L, 10L, T, T.plusDays(1));
        when(depot.findById(100L)).thenReturn(Optional.of(o));
        when(depotDefinitions.findById(10L)).thenReturn(Optional.of(aspirateur));

        assertThatThrownBy(() -> service.valider(THOMAS, 100L, T.plusHours(1)))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("futur");
    }

    @Test
    void une_definition_desactivee_ne_regenere_pas_d_occurrence() {
        DefinitionTache obsolete = definition(10L, "ANCIENNE", 2, 3, false);
        OccurrenceTache o = occurrence(100L, 10L, T.minusDays(1), T);
        when(depot.findById(100L)).thenReturn(Optional.of(o));
        when(depotDefinitions.findById(10L)).thenReturn(Optional.of(obsolete));

        assertThat(service.valider(THOMAS, 100L, null).suivante()).isEmpty();
    }

    // ------------------------------------------------------------------
    // Dependances
    // ------------------------------------------------------------------

    @Test
    void la_poussiere_validee_declenche_l_aspirateur_dans_les_24_heures() {
        DefinitionTache poussiere = definition(20L, "POUSSIERE", 7, 8, true);
        DefinitionTache aspirateur = definition(10L, "ASPIRATEUR", 2, 3, true);
        OccurrenceTache o = occurrence(200L, 20L, T.minusDays(1), T.plusDays(1));

        when(depot.findById(200L)).thenReturn(Optional.of(o));
        when(depotDefinitions.findById(20L)).thenReturn(Optional.of(poussiere));
        when(depotDefinitions.findById(10L)).thenReturn(Optional.of(aspirateur));
        when(depotDependances.findByDefinitionSourceId(20L))
                .thenReturn(List.of(new DependanceTache(20L, 10L, 24)));
        when(depot.ouvertesDansFenetre(eq(10L), anyList(), any(), any())).thenReturn(List.of());

        var resultat = service.valider(THOMAS, 200L, null);

        assertThat(resultat.declenchees()).hasSize(1);
        OccurrenceTache declenchee = resultat.declenchees().get(0);
        assertThat(declenchee.getDefinitionId()).isEqualTo(10L);
        assertThat(declenchee.getOrigine()).isEqualTo(OrigineOccurrence.DEPENDANCE);
        // Ordre impose : jamais avant la tache source.
        assertThat(declenchee.getEcheanceMin()).isEqualTo(T);
        assertThat(declenchee.getEcheanceMax()).isEqualTo(T.plusHours(24));
        assertThat(declenchee.getMotif()).contains("POUSSIERE");
    }

    @Test
    void une_occurrence_d_aspirateur_deja_ouverte_est_repositionnee_et_non_dupliquee() {
        DefinitionTache poussiere = definition(20L, "POUSSIERE", 7, 8, true);
        OccurrenceTache source = occurrence(200L, 20L, T.minusDays(1), T.plusDays(1));

        // Aspirateur deja prevu, avec une fenetre qui commence avant la poussiere.
        OccurrenceTache existante = occurrence(300L, 10L, T.minusHours(6), T.plusHours(10));

        when(depot.findById(200L)).thenReturn(Optional.of(source));
        when(depotDefinitions.findById(20L)).thenReturn(Optional.of(poussiere));
        when(depotDependances.findByDefinitionSourceId(20L))
                .thenReturn(List.of(new DependanceTache(20L, 10L, 24)));
        when(depot.ouvertesDansFenetre(eq(10L), anyList(), any(), any())).thenReturn(List.of(existante));

        var resultat = service.valider(THOMAS, 200L, null);

        assertThat(resultat.declenchees()).hasSize(1);
        assertThat(resultat.declenchees().get(0).getId()).isEqualTo(300L);
        // Repositionnee apres la source, en gardant la contrainte la plus serree.
        assertThat(existante.getEcheanceMin()).isEqualTo(T);
        assertThat(existante.getEcheanceMax()).isEqualTo(T.plusHours(10));
        assertThat(existante.getOrigine()).isEqualTo(OrigineOccurrence.AUTOMATIQUE);
        verify(depotDefinitions, never()).findById(10L);
    }

    // ------------------------------------------------------------------
    // Permissions (cf. 3.3)
    // ------------------------------------------------------------------

    @Test
    void un_utilisateur_standard_ne_valide_pas_la_tache_d_un_autre() {
        OccurrenceTache o = occurrence(100L, 10L, T.minusDays(1), T);
        o.setAssigneA(1L); // assignee a Thomas
        when(depot.findById(100L)).thenReturn(Optional.of(o));

        assertThatThrownBy(() -> service.valider(LORETTE, 100L, null))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("assignee a un autre utilisateur");
    }

    @Test
    void l_administrateur_peut_depanner_et_le_depannage_est_trace() {
        DefinitionTache pliage = definition(30L, "PLIER_LINGE", 1, 2, true);
        OccurrenceTache o = occurrence(100L, 30L, T.minusDays(1), T);
        o.setAssigneA(2L); // assignee a Lorette
        when(depot.findById(100L)).thenReturn(Optional.of(o));
        when(depotDefinitions.findById(30L)).thenReturn(Optional.of(pliage));

        service.valider(THOMAS, 100L, null);

        verify(journal).tracer(eq("thomas"), eq("OCCURRENCE_VALIDEE_EN_DEPANNAGE"),
                eq("occurrence_tache"), eq(100L), any(), any());
    }

    // ------------------------------------------------------------------
    // Report et refus
    // ------------------------------------------------------------------

    @Test
    void le_report_solde_l_occurrence_et_en_cree_une_remplacante() {
        OccurrenceTache o = occurrence(100L, 10L, T.minusDays(1), T);
        when(depot.findById(100L)).thenReturn(Optional.of(o));

        OccurrenceTache remplacante = service.reporter(THOMAS, 100L, T.plusDays(2), "pas le temps");

        assertThat(o.getEtat()).isEqualTo(EtatOccurrence.REPORTEE);
        assertThat(remplacante.getEcheanceMax()).isEqualTo(T.plusDays(2));
        assertThat(remplacante.getOccurrenceParenteId()).isEqualTo(100L);
        assertThat(remplacante.getEtat()).isEqualTo(EtatOccurrence.PLANIFIEE);
        verify(depot, times(2)).save(any(OccurrenceTache.class));
    }

    @Test
    void reporter_dans_le_passe_est_refuse() {
        OccurrenceTache o = occurrence(100L, 10L, T.minusDays(2), T.minusDays(1));
        when(depot.findById(100L)).thenReturn(Optional.of(o));

        assertThatThrownBy(() -> service.reporter(THOMAS, 100L, T.minusHours(1), null))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("futur");
    }

    @Test
    void le_refus_recree_la_tache_desassignee_au_lieu_de_la_faire_disparaitre() {
        OccurrenceTache o = occurrence(100L, 30L, T.minusDays(1), T.plusDays(1));
        o.setAssigneA(2L);
        when(depot.findById(100L)).thenReturn(Optional.of(o));

        OccurrenceTache reprise = service.refuser(LORETTE, 100L, "trop de travail");

        assertThat(o.getEtat()).isEqualTo(EtatOccurrence.REFUSEE);
        assertThat(reprise.getAssigneA()).isNull();
        assertThat(reprise.getEcheanceMax()).isEqualTo(o.getEcheanceMax());
        assertThat(reprise.getMotif()).contains("reassigner");
    }

    // ------------------------------------------------------------------
    // Gel
    // ------------------------------------------------------------------

    @Test
    void la_litiere_n_est_pas_gelable_meme_en_statut_malade() {
        DefinitionTache litiere = definition(40L, "LITIERE_PARTIEL", 2, 2, true);
        litiere.setGelable(false);
        OccurrenceTache o = occurrence(100L, 40L, T, T.plusDays(1));

        when(depot.findById(100L)).thenReturn(Optional.of(o));
        when(depotDefinitions.findById(40L)).thenReturn(Optional.of(litiere));

        assertThatThrownBy(() -> service.geler("systeme", 100L, "statut MALADE"))
                .isInstanceOf(ExceptionMetier.class)
                .hasMessageContaining("n'est pas gelable");
        assertThat(o.getEtat()).isEqualTo(EtatOccurrence.PLANIFIEE);
    }

    @Test
    void notifier_epingle_le_creneau() {
        OccurrenceTache o = occurrence(100L, 10L, T, T.plusDays(1));
        when(depot.findById(100L)).thenReturn(Optional.of(o));

        OccurrenceTache notifiee = service.marquerNotifiee(100L);

        assertThat(notifiee.getEtat()).isEqualTo(EtatOccurrence.NOTIFIEE);
        assertThat(notifiee.isEpinglee()).isTrue();
    }

    // ------------------------------------------------------------------
    // Fabriques
    // ------------------------------------------------------------------

    private DefinitionTache definition(Long id, String code, int min, int max, boolean active) {
        DefinitionTache d = new DefinitionTache(code, code, CategorieTache.MENAGE, (short) 4, 30, min, max);
        d.setActive(active);
        ReflectionTestUtils.setField(d, "id", id);
        return d;
    }

    private OccurrenceTache occurrence(Long id, Long definitionId,
                                       OffsetDateTime echeanceMin, OffsetDateTime echeanceMax) {
        OccurrenceTache o = new OccurrenceTache(
                definitionId, echeanceMin, echeanceMax, OrigineOccurrence.AUTOMATIQUE);
        ReflectionTestUtils.setField(o, "id", id);
        return o;
    }
}
