-- -----------------------------------------------------------------------------
-- Une nuit en détail                                       (3.24, SAN-15, SAN-16)
--
-- La nuit d'un jour est celle qui finit ce jour-là : une phase qui finit
-- après 18 h compte pour le lendemain, comme le total de `sante_jour`. Les
-- phases de la montre passent d'abord ; sans montre, celles de l'iPhone.
-- Rend les phases, l'heure du coucher et du lever, les minutes de chaque
-- phase et leur moyenne sur les 30 nuits d'avant, la FC de la nuit par
-- dizaine de minutes et son plus bas, et ce que la montre a mesuré pendant la
-- nuit (respiration, SpO2, température du poignet, VFC), face à l'habitude.
-- Vide si la nuit n'a pas de phases.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nuit_sante(p_utilisateur INTEGER, p_jour DATE)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_montre  BOOLEAN;
    v_coucher TIMESTAMPTZ;
    v_lever   TIMESTAMPTZ;
BEGIN
    SELECT bool_or(s.de_la_montre) INTO v_montre
      FROM sommeil_phase s
     WHERE s.id_utilisateur = p_utilisateur AND s.phase <> 'au_lit'
       AND jour_de(upper(s.periode) - INTERVAL '18 hours') + 1 = p_jour;
    IF v_montre IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT min(lower(s.periode)), max(upper(s.periode)) INTO v_coucher, v_lever
      FROM sommeil_phase s
     WHERE s.id_utilisateur = p_utilisateur AND s.phase <> 'au_lit'
       AND s.de_la_montre = v_montre
       AND jour_de(upper(s.periode) - INTERVAL '18 hours') + 1 = p_jour;

    RETURN jsonb_build_object(
        'jour', p_jour,
        'coucher', v_coucher,
        'lever', v_lever,
        'de_la_montre', v_montre,
        'phases', (
            SELECT jsonb_agg(jsonb_build_object('phase', s.phase, 'debut', lower(s.periode),
                                                'fin', upper(s.periode)) ORDER BY lower(s.periode))
              FROM sommeil_phase s
             WHERE s.id_utilisateur = p_utilisateur AND s.phase <> 'au_lit'
               AND s.de_la_montre = v_montre
               AND jour_de(upper(s.periode) - INTERVAL '18 hours') + 1 = p_jour),
        'minutes', (
            SELECT jsonb_object_agg(x.phase, x.minutes)
              FROM (SELECT s.phase,
                           round(sum(EXTRACT(EPOCH FROM upper(s.periode) - lower(s.periode))) / 60)
                               AS minutes
                      FROM sommeil_phase s
                     WHERE s.id_utilisateur = p_utilisateur AND s.phase <> 'au_lit'
                       AND s.de_la_montre = v_montre
                       AND jour_de(upper(s.periode) - INTERVAL '18 hours') + 1 = p_jour
                     GROUP BY s.phase) x),
        'habitude', (
            SELECT jsonb_object_agg(h.phase, h.minutes)
              FROM (SELECT n.phase, round(avg(n.minutes)) AS minutes
                      FROM (SELECT jour_de(upper(s.periode) - INTERVAL '18 hours') + 1 AS nuit, s.phase,
                                   sum(EXTRACT(EPOCH FROM upper(s.periode) - lower(s.periode))) / 60
                                       AS minutes
                              FROM sommeil_phase s
                             WHERE s.id_utilisateur = p_utilisateur AND s.de_la_montre
                               AND s.phase IN ('eveille', 'leger', 'profond', 'paradoxal')
                               AND jour_de(upper(s.periode) - INTERVAL '18 hours') + 1
                                   BETWEEN p_jour - 30 AND p_jour - 1
                             GROUP BY 1, 2) n
                     GROUP BY n.phase) h),
        'frequence', (
            SELECT jsonb_agg(jsonb_build_object('minute', f.minute, 'bpm', f.bpm) ORDER BY f.minute)
              FROM (SELECT (floor(EXTRACT(EPOCH FROM lower(e.periode) - v_coucher) / 600) * 10)::INTEGER
                               AS minute,
                           round(avg(e.valeur)) AS bpm
                      FROM v_echantillon_sante e
                     WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'fc'
                       AND lower(e.periode) BETWEEN v_coucher AND v_lever
                     GROUP BY 1) f),
        'fc_plus_basse', (
            SELECT jsonb_build_object('bpm', round(e.valeur), 'quand', lower(e.periode))
              FROM v_echantillon_sante e
             WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = 'fc'
               AND lower(e.periode) BETWEEN v_coucher AND v_lever
             ORDER BY e.valeur, lower(e.periode) LIMIT 1),
        'mesures', (
            SELECT jsonb_object_agg(g.grandeur, jsonb_build_object(
                       'valeur', (SELECT round(avg(e.valeur)::NUMERIC, 1) FROM v_echantillon_sante e
                                   WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = g.grandeur
                                     AND lower(e.periode) BETWEEN v_coucher - INTERVAL '1 hour'
                                                              AND v_lever + INTERVAL '1 hour'),
                       'plus_bas', (SELECT round(min(e.valeur)::NUMERIC, 1) FROM v_echantillon_sante e
                                     WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = g.grandeur
                                       AND lower(e.periode) BETWEEN v_coucher - INTERVAL '1 hour'
                                                                AND v_lever + INTERVAL '1 hour'),
                       'habitude', (SELECT round(avg(e.valeur)::NUMERIC, 1) FROM v_echantillon_sante e
                                     WHERE e.id_utilisateur = p_utilisateur AND e.grandeur = g.grandeur
                                       AND lower(e.periode) BETWEEN v_coucher - INTERVAL '30 days'
                                                                AND v_coucher - INTERVAL '1 hour')))
              FROM unnest(ARRAY['respiration', 'spo2', 'temperature_poignet', 'vfc']) AS g(grandeur)));
END $$;

COMMENT ON FUNCTION nuit_sante(INTEGER, DATE) IS
    '3.24 : une nuit en détail, celle qui finit le jour donné. Phases de la
     montre d''abord, minutes de chaque phase face aux 30 nuits d''avant, FC de
     la nuit, respiration, SpO2, température du poignet et VFC. Vide sans phases.';
