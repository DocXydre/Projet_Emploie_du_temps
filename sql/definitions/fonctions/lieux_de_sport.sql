-- -----------------------------------------------------------------------------
-- Les lieux de chaque discipline, pour un compte          (LIE-1, ADR-17, ADR-18)
--
-- Déduits des adresses : chaque lieu de sport du compte, commun au foyer ou à
-- lui, vaut pour la musculation, le cardio et la course ; la course dehors,
-- sans adresse, vaut pour la course, en premier. Les autres se rangent du plus
-- proche du foyer au plus loin : c'est le lieu qu'on prend quand HAL n'en donne
-- pas. Ce qu'on préfère faire où, c'est la description qui le dit, et HAL qui
-- la lit.
--
-- Tant que le compte n'a aucun lieu de sport avec adresse, ses lieux d'avant,
-- choisis par discipline, restent valables (ADR-18). Sans lieux d'avant,
-- l'adresse du foyer suffit pour courir dehors. Sans aucune adresse, rien : le
-- démarrage demande les adresses (DEM-7).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieux_de_sport(p_utilisateur INTEGER)
RETURNS TABLE (discipline VARCHAR, id_lieu INTEGER, rang INTEGER)
LANGUAGE sql STABLE AS $$
    WITH adresses AS (
        SELECT s.id_lieu,
               COALESCE(distance_m(f.latitude, f.longitude, l.latitude, l.longitude), 0) AS d
          FROM lieu_sport s
          JOIN lieux_du_compte(p_utilisateur) l ON l.id_lieu_connu = s.id_lieu_connu
          LEFT JOIN lieu_connu f ON f.id_lieu_connu = lieu_du_foyer(p_utilisateur)
    ),
    deduits AS (
        SELECT x.discipline, a.id_lieu, a.d
          FROM adresses a
         CROSS JOIN (VALUES ('musculation'), ('cardio'), ('course')) AS x (discipline)
        UNION ALL
        SELECT 'course', s.id_lieu, -1
          FROM lieu_sport s
         WHERE s.dehors AND s.id_lieu_connu IS NULL
    )
    SELECT x.discipline::VARCHAR, x.id_lieu,
           row_number() OVER (PARTITION BY x.discipline ORDER BY x.d, x.id_lieu)::INTEGER
      FROM deduits x
     WHERE EXISTS (SELECT 1 FROM adresses)
        OR (lieu_du_foyer(p_utilisateur) IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM discipline_lieu d
                             WHERE d.id_utilisateur = p_utilisateur))
    UNION ALL
    SELECT dl.discipline, dl.id_lieu, dl.rang::INTEGER
      FROM discipline_lieu dl
     WHERE dl.id_utilisateur = p_utilisateur
       AND NOT EXISTS (SELECT 1 FROM adresses);
$$;

COMMENT ON FUNCTION lieux_de_sport(INTEGER) IS
    'LIE-1, ADR-17, ADR-18 : les lieux de chaque discipline, déduits des adresses ; ceux choisis avant, pour un compte sans lieu de sport avec adresse.';
