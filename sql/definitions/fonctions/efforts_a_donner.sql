-- -----------------------------------------------------------------------------
-- Les courses qui attendent leur note d'effort                         (MON-11)
--
-- Une course ou une séance de cardio qui compte (pas un doublon), rattachée à
-- une séance, qui ne vient ni de la montre ni d'une saisie à la main, sans
-- bilan, faite il y a moins de trois jours. Passé ce délai, la carte se retire
-- et la séance reste sans charge (SAI-13).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION efforts_a_donner(p_utilisateur INTEGER)
RETURNS TABLE (id_occurrence INTEGER, discipline VARCHAR, debut TIMESTAMPTZ,
               duree_secondes INTEGER, distance_m INTEGER, source TEXT)
LANGUAGE sql STABLE AS $$
    SELECT a.id_occurrence, a.discipline, lower(a.periode), a.duree_secondes, a.distance_m,
           a.details ->> 'source'
      FROM activite_sante a
      JOIN seance se ON se.id_occurrence = a.id_occurrence
     WHERE a.id_utilisateur = p_utilisateur
       AND a.doublon_de IS NULL
       AND a.discipline IN ('course', 'cardio')
       AND rang_activite(a.details) = 1
       AND lower(a.periode) > now() - INTERVAL '3 days'
       AND NOT EXISTS (SELECT 1 FROM bilan_seance b WHERE b.id_occurrence = a.id_occurrence)
     ORDER BY lower(a.periode) DESC
$$;

COMMENT ON FUNCTION efforts_a_donner(INTEGER) IS
    'MON-11 : les courses et le cardio reçus d''une autre appli que la montre, de
     moins de trois jours, qui attendent leur note d''effort.';
