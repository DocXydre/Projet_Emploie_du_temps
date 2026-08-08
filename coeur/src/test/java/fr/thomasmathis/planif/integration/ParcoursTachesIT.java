package fr.thomasmathis.planif.integration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.OffsetDateTime;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * Parcours complet contre une vraie base PostgreSQL.
 *
 * <p>Ce test couvre ce qu'aucun test unitaire ne peut voir :</p>
 * <ul>
 *   <li>les migrations Flyway s'appliquent et le mapping JPA les valide
 *       ({@code ddl-auto: validate} echouerait au demarrage sinon) ;</li>
 *   <li>les requetes a filtres optionnels fonctionnent sur PostgreSQL, qui
 *       refuse les parametres nuls non types ;</li>
 *   <li>la chaine complete authentification, permission, transition d'etat,
 *       recurrence, dependance et journal.</li>
 * </ul>
 *
 * <p>Prerequis : {@code mvn -Pintegration verify} avec une base joignable
 * (variables {@code DB_HOTE}, {@code DB_PORT}).</p>
 */
@SpringBootTest(properties = {
        "planif.securite.secret-jwt=secret-de-test-integration-suffisamment-long",
        "planif.comptes.admin.mot-de-passe=mdp-thomas",
        "planif.comptes.standard.mot-de-passe=mdp-lorette",
        "planif.erreurs.exposer-detail=true"
})
@AutoConfigureMockMvc
class ParcoursTachesIT {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper json;

    private String jeton(String identifiant, String motDePasse) throws Exception {
        MvcResult resultat = mockMvc.perform(post("/api/v1/auth/connexion")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"identifiant":"%s","motDePasse":"%s"}""".formatted(identifiant, motDePasse)))
                .andExpect(status().isOk())
                .andReturn();
        return lire(resultat).get("jetonAcces").asText();
    }

    private JsonNode lire(MvcResult resultat) throws Exception {
        return json.readTree(resultat.getResponse().getContentAsString());
    }

    private long definitionId(String jeton, String code) throws Exception {
        JsonNode definitions = lire(mockMvc.perform(get("/api/v1/taches/definitions")
                .header("Authorization", "Bearer " + jeton)).andReturn());

        for (JsonNode definition : definitions) {
            if (code.equals(definition.get("code").asText())) {
                return definition.get("id").asLong();
            }
        }
        throw new AssertionError("Definition absente des donnees de reference : " + code);
    }

    private long creerOccurrence(String jeton, long definitionId, Long assigneA,
                                 OffsetDateTime min, OffsetDateTime max) throws Exception {
        String corps = """
                {"definitionId":%d,%s"echeanceMin":"%s","echeanceMax":"%s"}"""
                .formatted(definitionId,
                        assigneA != null ? "\"assigneA\":" + assigneA + "," : "",
                        min, max);

        MvcResult resultat = mockMvc.perform(post("/api/v1/taches/occurrences")
                        .header("Authorization", "Bearer " + jeton)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(corps))
                .andExpect(status().isCreated())
                .andReturn();
        return lire(resultat).get("id").asLong();
    }

    // ------------------------------------------------------------------

    @Test
    void la_sonde_de_sante_voit_la_base() throws Exception {
        mockMvc.perform(get("/sante"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.etat").value("OK"))
                .andExpect(jsonPath("$.dependances.postgresql").value("OK"));
    }

    @Test
    void les_donnees_de_reference_sont_chargees_avec_leurs_dependances() throws Exception {
        String thomas = jeton("thomas", "mdp-thomas");
        long poussiere = definitionId(thomas, "POUSSIERE");
        long aspirateur = definitionId(thomas, "ASPIRATEUR");

        JsonNode detail = lire(mockMvc.perform(get("/api/v1/taches/definitions/" + poussiere)
                .header("Authorization", "Bearer " + thomas)).andReturn());

        assertThat(detail.get("declenche")).hasSize(1);
        assertThat(detail.get("declenche").get(0).get("definitionCibleId").asLong()).isEqualTo(aspirateur);
        assertThat(detail.get("declenche").get(0).get("delaiMaxHeures").asInt()).isEqualTo(24);

        // La litiere reste due meme en statut MALADE.
        JsonNode litiere = lire(mockMvc.perform(
                get("/api/v1/taches/definitions/" + definitionId(thomas, "LITIERE_PARTIEL"))
                        .header("Authorization", "Bearer " + thomas)).andReturn());
        assertThat(litiere.get("gelable").asBoolean()).isFalse();
    }

    @Test
    void un_endpoint_protege_refuse_les_appels_sans_jeton() throws Exception {
        mockMvc.perform(get("/api/v1/taches/definitions"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value("NON_AUTHENTIFIE"))
                .andExpect(jsonPath("$.correlation").isNotEmpty());
    }

    @Test
    void un_mot_de_passe_errone_est_refuse() throws Exception {
        mockMvc.perform(post("/api/v1/auth/connexion")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"identifiant":"thomas","motDePasse":"faux"}"""))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value("IDENTIFIANTS_INVALIDES"));
    }

    @Test
    void parcours_complet_validation_recurrence_dependance_et_journal() throws Exception {
        String thomas = jeton("thomas", "mdp-thomas");
        String lorette = jeton("lorette", "mdp-lorette");

        long poussiere = definitionId(thomas, "POUSSIERE");
        OffsetDateTime maintenant = OffsetDateTime.now();

        // Une occurrence deja en retard, assignee a Thomas (utilisateur 1).
        long occurrence = creerOccurrence(thomas, poussiere, 1L,
                maintenant.minusDays(3), maintenant.minusDays(1));

        mockMvc.perform(get("/api/v1/taches/occurrences/" + occurrence)
                        .header("Authorization", "Bearer " + thomas))
                .andExpect(jsonPath("$.enRetard").value(true))
                .andExpect(jsonPath("$.etat").value("PLANIFIEE"))
                .andExpect(jsonPath("$.actionsPossibles").isArray());

        // Lorette ne peut pas valider une tache assignee a Thomas.
        mockMvc.perform(post("/api/v1/taches/occurrences/" + occurrence + "/valider")
                        .header("Authorization", "Bearer " + lorette))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("ACTION_NON_AUTORISEE"));

        // Thomas valide : recurrence depuis la date reelle, et dependance declenchee.
        JsonNode validation = lire(mockMvc.perform(
                post("/api/v1/taches/occurrences/" + occurrence + "/valider")
                        .header("Authorization", "Bearer " + thomas)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{}"))
                .andExpect(status().isOk())
                .andReturn());

        assertThat(validation.get("validee").get("etat").asText()).isEqualTo("VALIDEE");

        OffsetDateTime valideeLe = OffsetDateTime.parse(validation.get("validee").get("valideeLe").asText());
        OffsetDateTime suivanteMin = OffsetDateTime.parse(validation.get("suivante").get("echeanceMin").asText());
        OffsetDateTime suivanteMax = OffsetDateTime.parse(validation.get("suivante").get("echeanceMax").asText());

        // POUSSIERE : tous les 7 a 8 jours, comptes depuis la validation reelle
        // et non depuis l'echeance theorique, deja depassee de deux jours.
        assertThat(suivanteMin).isEqualTo(valideeLe.plusDays(7));
        assertThat(suivanteMax).isEqualTo(valideeLe.plusDays(8));

        assertThat(validation.get("declenchees")).hasSize(1);
        JsonNode aspirateur = validation.get("declenchees").get(0);
        assertThat(aspirateur.get("definitionCode").asText()).isEqualTo("ASPIRATEUR");
        assertThat(aspirateur.get("origine").asText()).isEqualTo("DEPENDANCE");
        // Ordre impose : jamais avant sa source, et au plus tard 24 h apres.
        assertThat(OffsetDateTime.parse(aspirateur.get("echeanceMin").asText())).isEqualTo(valideeLe);
        assertThat(OffsetDateTime.parse(aspirateur.get("echeanceMax").asText()))
                .isEqualTo(valideeLe.plusHours(24));

        // Revalider ecraserait la date reelle : c'est refuse.
        mockMvc.perform(post("/api/v1/taches/occurrences/" + occurrence + "/valider")
                        .header("Authorization", "Bearer " + thomas)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{}"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value("TRANSITION_INTERDITE"));

        // Le journal a garde la trace de la validation.
        mockMvc.perform(get("/api/v1/journal")
                        .param("entite", "occurrence_tache")
                        .param("entiteId", String.valueOf(occurrence))
                        .header("Authorization", "Bearer " + thomas))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.type == 'OCCURRENCE_VALIDEE')]").isNotEmpty());

        // Le journal est reserve a l'administrateur.
        mockMvc.perform(get("/api/v1/journal").header("Authorization", "Bearer " + lorette))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("ACTION_NON_AUTORISEE"));
    }

    @Test
    void une_dependance_ne_cree_jamais_de_doublon() throws Exception {
        String thomas = jeton("thomas", "mdp-thomas");
        long recurage = definitionId(thomas, "RECURAGE");
        long aspirateur = definitionId(thomas, "ASPIRATEUR");
        OffsetDateTime maintenant = OffsetDateTime.now();

        long avant = compterOuvertes(thomas, aspirateur);

        long premier = creerOccurrence(thomas, recurage, null,
                maintenant.minusDays(2), maintenant.minusDays(1));
        valider(thomas, premier);

        // Une occurrence d'aspirateur au plus a ete ajoutee : s'il en existait
        // deja une dans la fenetre, elle a ete reutilisee.
        long apresPremier = compterOuvertes(thomas, aspirateur);
        assertThat(apresPremier).isBetween(avant, avant + 1);

        // Deuxieme recurage dans la foulee : l'aspirateur deja prevu est
        // repositionne, pas duplique.
        long second = creerOccurrence(thomas, recurage, null,
                maintenant.minusDays(1), maintenant);
        JsonNode resultat = valider(thomas, second);

        assertThat(resultat.get("declenchees")).hasSize(1);
        assertThat(resultat.get("declenchees").get(0).get("motif").asText())
                .contains("Repositionnee");
        assertThat(compterOuvertes(thomas, aspirateur)).isEqualTo(apresPremier);
    }

    @Test
    void les_occupations_se_lisent_avec_ou_sans_filtre_utilisateur() throws Exception {
        String thomas = jeton("thomas", "mdp-thomas");
        OffsetDateTime debut = OffsetDateTime.now().plusDays(1).withNano(0);

        mockMvc.perform(post("/api/v1/occupations")
                        .header("Authorization", "Bearer " + thomas)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"utilisateurId":1,"type":"SHIFT","debut":"%s","fin":"%s",
                                 "libelle":"Shift McDonald's","lieu":"Nancy"}"""
                                .formatted(debut, debut.plusHours(6))))
                .andExpect(status().isCreated());

        String periode = "?debut=%s&fin=%s".formatted(debut.minusDays(1), debut.plusDays(1));

        // Sans filtre : c'est ce cas qui echouait sur PostgreSQL avec un
        // parametre nul non type.
        mockMvc.perform(get("/api/v1/occupations" + periode)
                        .header("Authorization", "Bearer " + thomas))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.type == 'SHIFT')]").isNotEmpty());

        mockMvc.perform(get("/api/v1/occupations" + periode + "&utilisateur=1")
                        .header("Authorization", "Bearer " + thomas))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].libelle").value("Shift McDonald's"));
    }

    @Test
    void un_statut_declare_expose_ses_effets_par_categorie() throws Exception {
        String thomas = jeton("thomas", "mdp-thomas");

        MvcResult declaration = mockMvc.perform(post("/api/v1/statuts")
                        .header("Authorization", "Bearer " + thomas)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"type":"MALADE","commentaire":"angine"}"""))
                .andExpect(status().isCreated())
                .andReturn();

        mockMvc.perform(get("/api/v1/statuts/courant").header("Authorization", "Bearer " + thomas))
                .andExpect(jsonPath("$.type").value("MALADE"))
                .andExpect(jsonPath("$.effetsParCategorie.SPORT").value("GELER"))
                .andExpect(jsonPath("$.effetsParCategorie.MENAGE").value("REPORTER"))
                // La litiere reste due meme malade.
                .andExpect(jsonPath("$.effetsParCategorie.ANIMAL").value("MAINTENIR"));

        long statut = lire(declaration).get("id").asLong();
        mockMvc.perform(post("/api/v1/statuts/" + statut + "/terminer")
                        .header("Authorization", "Bearer " + thomas))
                .andExpect(jsonPath("$.ouvert").value(false));

        mockMvc.perform(get("/api/v1/statuts/courant").header("Authorization", "Bearer " + thomas))
                .andExpect(jsonPath("$.type").value("ACTIF"));
    }

    @Test
    void la_sante_des_sources_est_calculee_et_persistee() throws Exception {
        String thomas = jeton("thomas", "mdp-thomas");

        mockMvc.perform(get("/api/v1/sources/sante").header("Authorization", "Bearer " + thomas))
                .andExpect(status().isOk())
                // La saisie manuelle ne perime jamais : c'est le mode degrade.
                .andExpect(jsonPath("$[?(@.code == 'SAISIE_MANUELLE')].etatSante").value("OK"))
                .andExpect(jsonPath("$[?(@.code == 'IDMC_ICS')]").isNotEmpty());
    }

    // ------------------------------------------------------------------

    private JsonNode valider(String jeton, long occurrenceId) throws Exception {
        return lire(mockMvc.perform(post("/api/v1/taches/occurrences/" + occurrenceId + "/valider")
                        .header("Authorization", "Bearer " + jeton)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{}"))
                .andExpect(status().isOk())
                .andReturn());
    }

    private long compterOuvertes(String jeton, long definitionId) throws Exception {
        JsonNode occurrences = lire(mockMvc.perform(get("/api/v1/taches/occurrences")
                .param("etat", "PLANIFIEE", "NOTIFIEE")
                .header("Authorization", "Bearer " + jeton)).andReturn());

        long total = 0;
        for (JsonNode occurrence : occurrences) {
            if (occurrence.get("definitionId").asLong() == definitionId) {
                total++;
            }
        }
        return total;
    }
}
