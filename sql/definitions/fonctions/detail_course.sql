-- -----------------------------------------------------------------------------
-- Le détail d'une course faite, pour l'appli            (3.22, 3.23, SAN-11 à 14)
--
-- Tout se lit dans les séries brutes de la séance de la montre qui compte
-- (pas un doublon) :
--   - les étapes, avec ce qui était prévu, leur allure et leur FC. Une étape
--     plus rapide de 10 % que la moyenne de la séance est une fraction ; avant
--     la première, l'échauffement ; après la dernière, le retour au calme ;
--     entre deux, une récupération. Un libellé reçu de la montre l'emporte ;
--   - les kilomètres, leur temps et leur FC ;
--   - la courbe de l'allure et de la FC, par quarts de minute ;
--   - le temps passé dans chaque zone cardiaque, rapporté à la FC maximale
--     connue (moins de 60 %, 70, 80, 90 %, au-delà) ;
--   - la dynamique de course, sur toute la séance et sur les fractions ;
--   - la FC de récupération, mesurée par la montre dans la demi-heure qui suit ;
--   - le tracé, allégé à 400 points au plus, chaque point avec son étape.
-- Vide si la séance n'a pas de séance de la montre, ou n'est pas à ce compte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION detail_course(p_utilisateur INTEGER, p_occurrence INTEGER)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    a         RECORD;
    v_debut   TIMESTAMPTZ;
    v_fin     TIMESTAMPTZ;
    v_vitesse DOUBLE PRECISION;
    v_fc_max  INTEGER := fc_max_connue(p_utilisateur);
BEGIN
    SELECT ac.* INTO a
      FROM activite_sante ac JOIN occurrence o ON o.id_occurrence = ac.id_occurrence
     WHERE ac.id_occurrence = p_occurrence AND o.id_utilisateur = p_utilisateur
       AND ac.doublon_de IS NULL
     ORDER BY ac.id_activite LIMIT 1;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    v_debut := lower(a.periode);
    v_fin := upper(a.periode);
    SELECT avg(s.valeur) INTO v_vitesse
      FROM activite_serie s WHERE s.id_activite = a.id_activite AND s.grandeur = 'vitesse';

    IF to_regclass('pg_temp.etape_course') IS NOT NULL THEN
        DROP TABLE etape_course;
    END IF;
    CREATE TEMP TABLE etape_course ON COMMIT DROP AS
    SELECT g.rang, g.libelle, g.prevu, g.distance_m, lower(g.periode) AS de, upper(g.periode) AS a,
           m.fc, m.vitesse, m.puissance, m.cadence, m.foulee, m.contact_sol, m.oscillation,
           COALESCE(m.vitesse > 1.1 * v_vitesse, FALSE) AS rapide
      FROM activite_segment g
      LEFT JOIN LATERAL (
          SELECT avg(s.valeur) FILTER (WHERE s.grandeur = 'fc')          AS fc,
                 avg(s.valeur) FILTER (WHERE s.grandeur = 'vitesse')     AS vitesse,
                 avg(s.valeur) FILTER (WHERE s.grandeur = 'puissance')   AS puissance,
                 avg(s.valeur) FILTER (WHERE s.grandeur = 'cadence')     AS cadence,
                 avg(s.valeur) FILTER (WHERE s.grandeur = 'foulee')      AS foulee,
                 avg(s.valeur) FILTER (WHERE s.grandeur = 'contact_sol') AS contact_sol,
                 avg(s.valeur) FILTER (WHERE s.grandeur = 'oscillation') AS oscillation
            FROM activite_serie s
           WHERE s.id_activite = a.id_activite
             AND s.debut >= lower(g.periode) AND s.debut < upper(g.periode)) m ON TRUE
     WHERE g.id_activite = a.id_activite AND g.sorte = 'etape';

    RETURN jsonb_build_object(
        'type', a.type,
        'debut', v_debut,
        'duree_secondes', a.duree_secondes,
        'distance_m', a.distance_m,
        'denivele_m', a.denivele_m,
        'energie_kcal', a.energie_kcal,
        'fc_moyenne', a.fc_moyenne,
        'fc_max', a.fc_max,
        'allure_s_km', a.allure_s_km,
        'cadence', a.cadence,
        'fc_max_connue', v_fc_max,

        'etapes', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'rang', e.rang,
                       'nom', COALESCE(e.libelle, CASE
                           WHEN e.rapide THEN 'Fraction ' || e.numero
                           WHEN e.rang < e.premiere THEN 'Échauffement'
                           WHEN e.rang > e.derniere THEN 'Retour au calme'
                           WHEN e.premiere IS NULL THEN 'Étape ' || e.rang
                           ELSE 'Récupération' END),
                       'rapide', e.rapide,
                       'debut_s', EXTRACT(EPOCH FROM e.de - v_debut)::INTEGER,
                       'duree_s', EXTRACT(EPOCH FROM e.a - e.de)::INTEGER,
                       'distance_m', round(e.distance_m),
                       'allure_s_km', CASE WHEN e.vitesse > 0 THEN round(1000 / e.vitesse) END,
                       'fc', round(e.fc),
                       'prevu', e.prevu) ORDER BY e.rang)
              FROM (SELECT x.*,
                           count(*) FILTER (WHERE x.rapide) OVER (ORDER BY x.rang) AS numero,
                           min(x.rang) FILTER (WHERE x.rapide) OVER () AS premiere,
                           max(x.rang) FILTER (WHERE x.rapide) OVER () AS derniere
                      FROM etape_course x) e), '[]'),

        'kilometres', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'rang', g.rang,
                       'duree_s', EXTRACT(EPOCH FROM upper(g.periode) - lower(g.periode))::INTEGER,
                       'distance_m', round(g.distance_m),
                       'fc', (SELECT round(avg(s.valeur)) FROM activite_serie s
                               WHERE s.id_activite = a.id_activite AND s.grandeur = 'fc'
                                 AND s.debut >= lower(g.periode) AND s.debut < upper(g.periode)))
                   ORDER BY g.rang)
              FROM activite_segment g
             WHERE g.id_activite = a.id_activite AND g.sorte = 'kilometre'), '[]'),

        'pauses', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'debut_s', EXTRACT(EPOCH FROM lower(g.periode) - v_debut)::INTEGER,
                       'duree_s', EXTRACT(EPOCH FROM upper(g.periode) - lower(g.periode))::INTEGER)
                   ORDER BY g.rang)
              FROM activite_segment g
             WHERE g.id_activite = a.id_activite AND g.sorte = 'pause'), '[]'),

        'courbe', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('t', c.t, 'fc', c.fc, 'allure_s_km', c.allure)
                             ORDER BY c.t)
              FROM (SELECT (floor(EXTRACT(EPOCH FROM s.debut - v_debut) / 15) * 15)::INTEGER AS t,
                           round(avg(s.valeur) FILTER (WHERE s.grandeur = 'fc')) AS fc,
                           round(1000 / NULLIF(avg(s.valeur) FILTER (WHERE s.grandeur = 'vitesse'), 0))
                               AS allure
                      FROM activite_serie s
                     WHERE s.id_activite = a.id_activite AND s.grandeur IN ('fc', 'vitesse')
                     GROUP BY 1) c), '[]'),

        'zones', (
            SELECT jsonb_agg(COALESCE(z.secondes, 0) ORDER BY n)
              FROM generate_series(1, 5) n
              LEFT JOIN (
                  SELECT CASE WHEN f.valeur < 0.6 * v_fc_max THEN 1
                              WHEN f.valeur < 0.7 * v_fc_max THEN 2
                              WHEN f.valeur < 0.8 * v_fc_max THEN 3
                              WHEN f.valeur < 0.9 * v_fc_max THEN 4 ELSE 5 END AS zone,
                         round(sum(f.duree))::INTEGER AS secondes
                    FROM (SELECT s.valeur,
                                 LEAST(30, EXTRACT(EPOCH FROM COALESCE(
                                     lead(s.debut) OVER (ORDER BY s.debut), v_fin) - s.debut)) AS duree
                            FROM activite_serie s
                           WHERE s.id_activite = a.id_activite AND s.grandeur = 'fc') f
                   WHERE v_fc_max IS NOT NULL
                   GROUP BY 1) z ON z.zone = n
             WHERE v_fc_max IS NOT NULL),

        'dynamique', (
            SELECT jsonb_object_agg(d.grandeur, jsonb_build_object(
                       'moyenne', round(d.moyenne::NUMERIC, 2),
                       'fractions', round(d.fractions::NUMERIC, 2)))
              FROM (SELECT s.grandeur, avg(s.valeur) AS moyenne,
                           avg(s.valeur) FILTER (WHERE EXISTS (
                               SELECT 1 FROM etape_course e
                                WHERE e.rapide AND s.debut >= e.de AND s.debut < e.a)) AS fractions
                      FROM activite_serie s
                     WHERE s.id_activite = a.id_activite
                       AND s.grandeur IN ('puissance', 'cadence', 'foulee', 'contact_sol', 'oscillation')
                     GROUP BY s.grandeur) d),

        'fc_recuperation', (
            SELECT round(e.valeur) FROM v_echantillon_sante e
             WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'fc_recuperation'
               AND lower(e.periode) BETWEEN v_fin - INTERVAL '5 minutes' AND v_fin + INTERVAL '30 minutes'
             ORDER BY lower(e.periode) LIMIT 1),

        'trace', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'lat', p.latitude, 'lon', p.longitude, 'alt', p.altitude_m,
                       't', EXTRACT(EPOCH FROM p.instant - v_debut)::INTEGER,
                       'etape', (SELECT e.rang FROM etape_course e
                                  WHERE p.instant >= e.de AND p.instant < e.a LIMIT 1),
                       'rapide', COALESCE((SELECT e.rapide FROM etape_course e
                                            WHERE p.instant >= e.de AND p.instant < e.a LIMIT 1), FALSE))
                   ORDER BY p.instant)
              FROM (SELECT t.*, row_number() OVER (ORDER BY t.instant) AS n, count(*) OVER () AS total
                      FROM activite_trace t WHERE t.id_activite = a.id_activite) p
             WHERE p.n = 1 OR p.n = p.total OR p.n % GREATEST(1, ceil(p.total / 400.0)::INTEGER) = 0),
            '[]'));
END $$;

COMMENT ON FUNCTION detail_course(INTEGER, INTEGER) IS
    '3.22, 3.23 : le détail d''une course faite, lu dans les séries brutes de
     sa séance de la montre : étapes nommées, kilomètres, courbe, zones,
     dynamique, FC de récupération, tracé allégé. Vide sans séance de la montre.';
