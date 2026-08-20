-- =============================================================================
-- 002 : vues
--
-- Tout ce qu'un client doit afficher est calculé ici. Aucune logique métier ne
-- doit vivre dans l'API ni dans une future application : si un client devait
-- calculer lui-même qu'une tâche est en retard, c'est que la base aurait dû le
-- dire (R24).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Santé des sources                                                      (R30)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_source_sante AS
SELECT
    s.id_source,
    s.code,
    s.libelle,
    s.mode_collecte,
    s.frequence_heures,
    s.derniere_collecte,
    s.active,
    CASE
        -- Une source manuelle ne périme jamais : c'est le mode dégradé.
        WHEN s.mode_collecte = 'manuelle' OR NOT s.active THEN 'ok'
        WHEN s.derniere_collecte IS NULL                   THEN 'en_panne'
        WHEN now() - s.derniere_collecte
             > make_interval(hours => s.frequence_heures * 2) THEN 'en_panne'
        ELSE 'ok'
    END AS etat_calcule,
    now() - s.derniere_collecte AS anciennete
FROM source s;

COMMENT ON VIEW v_source_sante IS
    'Le moteur ne doit jamais planifier sur des données périmées sans le
     signaler : un planning silencieusement faux est pire que pas de planning.';


-- -----------------------------------------------------------------------------
-- Occurrences, enrichies de tout ce que le client ne doit pas recalculer
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_occurrence AS
SELECT
    o.id_occurrence,
    o.id_tache,
    t.code            AS tache_code,
    t.libelle         AS tache_libelle,
    t.categorie,
    t.priorite,
    t.duree_minutes,
    o.id_utilisateur,
    u.pseudo          AS assigne_a,
    o.fenetre,
    lower(o.fenetre)  AS echeance_min,
    upper(o.fenetre)  AS echeance_max,
    o.creneau,
    lower(o.creneau)  AS debut,
    upper(o.creneau)  AS fin,
    o.statut,
    o.origine,
    o.epinglee,
    o.rappel_journee,
    o.utilise_machine,
    o.nb_relances,
    o.motif,
    o.date_faite,

    -- R24, R26 : c'est la base qui dit qu'une tâche est en retard.
    --
    -- Deux façons de l'être : une échéance dépassée, ou au moins un report
    -- d'office. Le report repousse la fenêtre au lendemain, donc sans le
    -- compteur de relances une tâche repoussée chaque soir paraîtrait
    -- éternellement à l'heure.
    (o.statut IN ('a_placer', 'planifiee', 'notifiee')
     AND (upper(o.fenetre) < now() OR o.nb_relances > 0)) AS en_retard,

    CASE
        WHEN o.statut IN ('a_placer', 'planifiee', 'notifiee')
        THEN GREATEST(
                 o.nb_relances,
                 CASE WHEN upper(o.fenetre) < now()
                      THEN EXTRACT(DAY FROM now() - upper(o.fenetre))::INTEGER
                      ELSE 0 END)
        ELSE 0
    END                                                   AS jours_de_retard,

    -- R25 : les transitions encore possibles, pour que le client sache quels
    -- boutons afficher sans connaître la machine à états.
    CASE o.statut
        WHEN 'a_placer'  THEN ARRAY['faite', 'reportee', 'abandonnee']
        WHEN 'planifiee' THEN ARRAY['notifiee', 'faite', 'reportee', 'abandonnee']
        WHEN 'notifiee'  THEN ARRAY['faite', 'reportee', 'abandonnee']
        ELSE ARRAY[]::VARCHAR[]
    END                                                   AS actions_possibles
FROM occurrence o
JOIN tache t          ON t.id_tache = o.id_tache
LEFT JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur;


CREATE OR REPLACE VIEW v_taches_en_retard AS
SELECT * FROM v_occurrence WHERE en_retard ORDER BY priorite, echeance_max;


-- -----------------------------------------------------------------------------
-- Planning consolidé : c'est cette vue que lit l'export iCalendar        (R29)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_planning AS
SELECT
    'occupation'                       AS nature,
    o.id_occupation                    AS id,
    o.id_utilisateur,
    o.type                             AS categorie,
    o.libelle,
    o.periode,
    lower(o.periode)                   AS debut,
    upper(o.periode)                   AS fin,
    FALSE                              AS journee_entiere,
    NULL::VARCHAR                      AS statut,
    o.lieu,
    o.details                          AS motif,
    0                                  AS nb_relances
FROM occupation o

UNION ALL

SELECT
    'tache'                            AS nature,
    o.id_occurrence                    AS id,
    o.id_utilisateur,
    t.categorie,
    t.libelle,
    o.creneau                          AS periode,
    lower(o.creneau)                   AS debut,
    upper(o.creneau)                   AS fin,
    o.rappel_journee                   AS journee_entiere,
    o.statut,
    NULL::VARCHAR                      AS lieu,
    o.motif,
    o.nb_relances
FROM occurrence o
JOIN tache t ON t.id_tache = o.id_tache
WHERE o.creneau IS NOT NULL
  AND o.statut IN ('planifiee', 'notifiee');

COMMENT ON VIEW v_planning IS
    'Occupations et tâches placées dans une seule vue. Le drapeau
     journee_entiere décide si l''export produit un VEVENT horaire ou un
     VEVENT journée entière (R29).';


-- -----------------------------------------------------------------------------
-- Conflits en attente d'arbitrage                                   (R45, R46)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_conflit AS
SELECT
    c.id_conflit,
    c.statut,
    c.choix,
    c.date_detection,
    s.code                        AS source,

    -- Ce qui est déjà au planning.
    o.id_occupation,
    o.libelle                     AS libelle_existante,
    lower(o.periode)              AS debut_existante,
    upper(o.periode)              AS fin_existante,
    o.lieu                        AS lieu_existante,

    -- Ce que la source voudrait mettre à la place.
    c.libelle                     AS libelle_nouvelle,
    lower(c.periode)              AS debut_nouvelle,
    upper(c.periode)              AS fin_nouvelle,
    c.lieu                        AS lieu_nouvelle,
    c.details                     AS details_nouvelle,

    -- R46 : au-delà de deux semaines, on ne dérange pas. L'emploi du temps a
    -- toutes les chances d'être corrigé d'ici là.
    (lower(c.periode) <= now() + INTERVAL '14 days') AS a_arbitrer,
    EXTRACT(DAY FROM lower(c.periode) - now())::INTEGER AS dans_combien_de_jours
FROM conflit c
JOIN occupation o ON o.id_occupation = c.id_occupation
JOIN source s     ON s.id_source = c.id_source;

COMMENT ON VIEW v_conflit IS
    'Les deux versions côte à côte, pour que le bot puisse poser la question
     sans que le client ait à recalculer quoi que ce soit.';


-- -----------------------------------------------------------------------------
-- Stock réellement utilisable                                            (R36)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stock AS
SELECT
    a.id_article,
    a.code,
    a.libelle,
    a.quantite_totale,
    a.quantite_propre,
    a.seuil_securite,
    a.jours_par_unite,
    a.heures_sechage,
    a.disponible_le,

    -- Le linge en séchage existe mais n'est pas portable.
    CASE
        WHEN a.disponible_le IS NULL OR a.disponible_le <= now() THEN a.quantite_propre
        ELSE 0
    END                                                   AS quantite_utilisable,

    (a.disponible_le IS NOT NULL AND a.disponible_le > now()) AS en_sechage,

    CASE
        WHEN a.disponible_le IS NOT NULL AND a.disponible_le > now() THEN 0
        ELSE a.quantite_propre * a.jours_par_unite
    END                                                   AS jours_de_travail_couverts
FROM article_travail a;


-- -----------------------------------------------------------------------------
-- Journées de travail à venir : matière première de la projection de stock
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_journees_travail AS
SELECT DISTINCT
    o.id_utilisateur,
    (lower(o.periode) AT TIME ZONE 'Europe/Paris')::DATE AS jour,
    min(lower(o.periode))                                AS debut_premier_shift
FROM occupation o
WHERE o.type = 'travail'
  AND upper(o.periode) > now()
GROUP BY o.id_utilisateur, (lower(o.periode) AT TIME ZONE 'Europe/Paris')::DATE
ORDER BY jour;
