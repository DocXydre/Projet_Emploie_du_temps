-- -----------------------------------------------------------------------------
-- La forme sur la durée                                         (3.25, SAN-15)
--
-- Sur les derniers jours (tout l'historique si rien n'est donné) : la VO2max
-- jour par jour, la FC de récupération après chaque course, le poids jour par
-- jour (la balance par Santé et les pesées saisies, la saisie l'emportant le
-- même jour), et les moyennes du quotidien. Les tendances comparent la
-- première et la dernière valeur de la période. Mesures lues montre d'abord.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION forme_sante(p_utilisateur INTEGER, p_jours INTEGER DEFAULT 90)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_depuis TIMESTAMPTZ := CASE WHEN p_jours IS NULL THEN '-infinity'::TIMESTAMPTZ
                                 ELSE debut_jour(jour_de(now()) - p_jours) END;
BEGIN
    RETURN jsonb_build_object(
        'vo2max', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('jour', v.jour, 'valeur', v.valeur) ORDER BY v.jour)
              FROM (SELECT jour_de(lower(e.periode)) AS jour, round(max(e.valeur)::NUMERIC, 1) AS valeur
                      FROM v_echantillon_sante e
                     WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'vo2max'
                       AND lower(e.periode) >= v_depuis
                     GROUP BY 1) v), '[]'),
        'fc_recuperation', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('quand', lower(e.periode), 'valeur', round(e.valeur))
                             ORDER BY lower(e.periode))
              FROM v_echantillon_sante e
             WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'fc_recuperation'
               AND lower(e.periode) >= v_depuis), '[]'),
        'poids', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('jour', p.jour, 'valeur', p.valeur, 'source', p.source)
                             ORDER BY p.jour)
              FROM (SELECT DISTINCT ON (x.jour) x.*
                      FROM (SELECT m.date_mesure AS jour, m.valeur::DOUBLE PRECISION AS valeur,
                                   'saisie' AS source, 0 AS ordre
                              FROM mesure m
                             WHERE m.id_utilisateur = p_utilisateur AND m.type_mesure = 'poids'
                               AND m.date_mesure >= jour_de(v_depuis)
                            UNION ALL
                            SELECT jour_de(lower(e.periode)), e.valeur, e.source, 1
                              FROM v_echantillon_sante e
                             WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'poids'
                               AND lower(e.periode) >= v_depuis) x
                     ORDER BY x.jour, x.ordre) p), '[]'),
        'moyennes', jsonb_build_object(
            'energie_jour', (
                SELECT round(avg(j.total)) FROM (
                    SELECT jour_de(lower(e.periode)), sum(e.valeur) AS total
                      FROM v_echantillon_sante e
                     WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'energie'
                       AND lower(e.periode) >= v_depuis
                     GROUP BY 1) j),
            'fc_repos', (SELECT round(avg(s.fc_repos)) FROM sante_jour s
                          WHERE s.id_utilisateur = p_utilisateur AND s.jour >= jour_de(v_depuis)),
            'spo2', (SELECT round(avg(e.valeur)::NUMERIC, 1) FROM v_echantillon_sante e
                      WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'spo2'
                        AND lower(e.periode) >= v_depuis),
            'spo2_plus_bas', (SELECT round(min(e.valeur)::NUMERIC, 1) FROM v_echantillon_sante e
                               WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'spo2'
                                 AND lower(e.periode) >= v_depuis),
            'respiration', (SELECT round(avg(e.valeur)::NUMERIC, 1) FROM v_echantillon_sante e
                             WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'respiration'
                               AND lower(e.periode) >= v_depuis)),
        'tendances', jsonb_build_object(
            -- La dernière semaine face à la première qui a des données.
            'fc_repos', (
                SELECT round(avg(s.fc_repos) FILTER (WHERE s.jour > jour_de(now()) - 7)
                             - avg(s.fc_repos) FILTER (WHERE s.jour < d.premier + 7))
                  FROM sante_jour s,
                       (SELECT min(x.jour) AS premier FROM sante_jour x
                         WHERE x.id_utilisateur = p_utilisateur AND x.fc_repos IS NOT NULL
                           AND x.jour >= jour_de(v_depuis)) d
                 WHERE s.id_utilisateur = p_utilisateur AND s.jour >= jour_de(v_depuis)
                   AND d.premier < jour_de(now()) - 13)));
END $$;

COMMENT ON FUNCTION forme_sante(INTEGER, INTEGER) IS
    '3.25 : la forme sur la durée, VO2max, FC de récupération, poids (balance et
     saisies), moyennes du quotidien. Tout l''historique si p_jours est vide.';
