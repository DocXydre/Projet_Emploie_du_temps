-- Chapitre 8.2 du dossier : le score de forme du jour. Le ressenti du matin
-- n'est pas recueilli dans cette version : les quatre composantes restantes
-- sont ramenées à 100 % (sommeil 40, variabilité 30, fréquence de repos 15,
-- charge 15). Une composante absente rend son poids aux autres, et la vue dit
-- laquelle manque. Les références personnelles demandent vingt jours de
-- données sur soixante : avant, seul le sommeil compte.
CREATE VIEW v_score_forme AS
WITH composantes AS (
    SELECT u.id_utilisateur,
           (SELECT round(avg(LEAST(100.0, 100.0 * s.sommeil_minutes / u.besoin_sommeil_minutes)))
              FROM (SELECT sj.sommeil_minutes FROM sante_jour sj
                     WHERE sj.id_utilisateur = u.id_utilisateur
                       AND sj.sommeil_minutes IS NOT NULL
                       AND sj.jour > jour_de(now()) - 3
                     ORDER BY sj.jour DESC LIMIT 2) s)                       AS sommeil,
           (SELECT CASE WHEN r.n >= 20 AND r.ecart > 0 THEN
                       round(LEAST(100, GREATEST(0, 50 + 25 * (ln(d.vfc_ms) - r.moyenne) / r.ecart)))
                   END
              FROM (SELECT count(*) AS n, avg(ln(sj.vfc_ms)) AS moyenne,
                           stddev_samp(ln(sj.vfc_ms)) AS ecart
                      FROM sante_jour sj
                     WHERE sj.id_utilisateur = u.id_utilisateur AND sj.vfc_ms IS NOT NULL
                       AND sj.jour > jour_de(now()) - 60) r,
                   LATERAL (SELECT sj.vfc_ms FROM sante_jour sj
                             WHERE sj.id_utilisateur = u.id_utilisateur
                               AND sj.vfc_ms IS NOT NULL
                               AND sj.jour > jour_de(now()) - 2
                             ORDER BY sj.jour DESC LIMIT 1) d)               AS variabilite,
           (SELECT CASE WHEN r.n >= 20 AND r.ecart > 0 THEN
                       round(LEAST(100, GREATEST(0, 50 - 25 * (d.fc_repos - r.moyenne) / r.ecart)))
                   END
              FROM (SELECT count(*) AS n, avg(sj.fc_repos) AS moyenne,
                           stddev_samp(sj.fc_repos) AS ecart
                      FROM sante_jour sj
                     WHERE sj.id_utilisateur = u.id_utilisateur AND sj.fc_repos IS NOT NULL
                       AND sj.jour > jour_de(now()) - 60) r,
                   LATERAL (SELECT sj.fc_repos FROM sante_jour sj
                             WHERE sj.id_utilisateur = u.id_utilisateur
                               AND sj.fc_repos IS NOT NULL
                               AND sj.jour > jour_de(now()) - 2
                             ORDER BY sj.jour DESC LIMIT 1) d)               AS frequence_repos,
           (SELECT CASE WHEN c.rapport IS NULL THEN NULL
                        WHEN c.rapport > 1.5 THEN 30
                        WHEN c.rapport > 1.3 THEN 60
                        ELSE 100 END
              FROM v_charge_entrainement c
             WHERE c.id_utilisateur = u.id_utilisateur)                      AS charge
      FROM utilisateur u
     WHERE u.coach_actif
),
score AS (
    SELECT c.*,
           (COALESCE(c.sommeil * 40, 0) + COALESCE(c.variabilite * 30, 0)
            + COALESCE(c.frequence_repos * 15, 0) + COALESCE(c.charge * 15, 0))
           / NULLIF((CASE WHEN c.sommeil IS NULL THEN 0 ELSE 40 END)
                    + (CASE WHEN c.variabilite IS NULL THEN 0 ELSE 30 END)
                    + (CASE WHEN c.frequence_repos IS NULL THEN 0 ELSE 15 END)
                    + (CASE WHEN c.charge IS NULL THEN 0 ELSE 15 END), 0) AS valeur
      FROM composantes c
)
SELECT s.id_utilisateur,
       round(s.valeur)::INTEGER AS score,
       CASE WHEN s.valeur IS NULL THEN NULL
            WHEN s.valeur >= 70 THEN 'vert'
            WHEN s.valeur >= 45 THEN 'orange'
            ELSE 'rouge' END    AS etat,
       s.sommeil::INTEGER         AS sommeil,
       s.variabilite::INTEGER     AS variabilite,
       s.frequence_repos::INTEGER AS frequence_repos,
       s.charge::INTEGER          AS charge,
       array_remove(ARRAY[CASE WHEN s.sommeil IS NULL THEN 'sommeil' END,
                          CASE WHEN s.variabilite IS NULL THEN 'variabilite' END,
                          CASE WHEN s.frequence_repos IS NULL THEN 'frequence_repos' END,
                          CASE WHEN s.charge IS NULL THEN 'charge' END], NULL) AS manquantes
  FROM score s;

COMMENT ON VIEW v_score_forme IS
    'Chapitre 8.2 : le score de forme du jour et ses composantes, avec celles
     qui manquent. Sans aucune donnée, le score est vide, pas nul (SAN-5).';
