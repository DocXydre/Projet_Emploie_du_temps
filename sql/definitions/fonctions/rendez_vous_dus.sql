-- -----------------------------------------------------------------------------
-- Les rendez-vous de chacun qui sont dus maintenant                    (NOT-15)
--
-- Le bilan, la relance et le récap, à l'heure que chaque compte a réglée.
-- L'ordonnanceur passe toutes les cinq minutes : un rendez-vous est dû de son
-- heure jusqu'à trois heures après, s'il n'a pas encore été servi ce jour-là.
-- Après un redémarrage, un bilan manqué de peu part encore ; celui de la
-- veille, non. Le récap de 23h vaut jusqu'à 2h : on regarde aussi hier.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rendez_vous_dus(p_instant TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (id_utilisateur INTEGER, moment TEXT, jour DATE)
LANGUAGE sql STABLE AS $$
    SELECT u.id_utilisateur, m.moment, j.jour
      FROM utilisateur u
     CROSS JOIN LATERAL (VALUES ('bilan', u.heure_bilan),
                                ('relance', u.heure_relance),
                                ('recap', u.heure_recap)) AS m (moment, heure)
     CROSS JOIN LATERAL (VALUES (jour_de(p_instant)), (jour_de(p_instant) - 1)) AS j (jour)
     WHERE u.actif
       AND ((j.jour + m.heure) AT TIME ZONE 'Europe/Paris') <= p_instant
       AND ((j.jour + m.heure) AT TIME ZONE 'Europe/Paris') + INTERVAL '3 hours' > p_instant
       AND NOT EXISTS (SELECT 1 FROM passage p
                        WHERE p.id_utilisateur = u.id_utilisateur
                          AND p.moment = m.moment AND p.jour = j.jour)
     ORDER BY u.id_utilisateur, m.moment
$$;

COMMENT ON FUNCTION rendez_vous_dus(TIMESTAMPTZ) IS
    'NOT-15 : le bilan, la relance et le récap dus à cet instant, compte par compte.';
