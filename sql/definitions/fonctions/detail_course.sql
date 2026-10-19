-- -----------------------------------------------------------------------------
-- Le détail d'une course faite, par sa séance prévue                 (3.22, 3.23)
--
-- La séance de la montre qui compte (pas un doublon), lue par
-- `detail_activite`. Vide si la séance n'a pas de séance de la montre, ou
-- n'est pas à ce compte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION detail_course(p_utilisateur INTEGER, p_occurrence INTEGER)
RETURNS JSONB LANGUAGE sql AS $$
    SELECT detail_activite(p_utilisateur, (
        SELECT ac.id_activite
          FROM activite_sante ac JOIN occurrence o ON o.id_occurrence = ac.id_occurrence
         WHERE ac.id_occurrence = p_occurrence AND o.id_utilisateur = p_utilisateur
           AND ac.doublon_de IS NULL
         ORDER BY ac.id_activite LIMIT 1))
$$;

COMMENT ON FUNCTION detail_course(INTEGER, INTEGER) IS
    '3.22, 3.23 : le détail d''une course faite, par sa séance prévue. Vide sans
     séance de la montre.';
