-- -----------------------------------------------------------------------------
-- D'où l'on part un jour donné                                         (ADR-9)
--
-- Le lieu connu de l'absence qui couvre toute la journée ; sinon l'école un
-- jour de cours ; sinon le foyer. Vide si aucun n'a d'adresse : le trajet
-- reprend alors les minutes saisies du lieu de sport.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieu_ou_l_on_sera(p_utilisateur INTEGER, p_jour DATE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT a.id_lieu_connu FROM absence a
          WHERE a.id_utilisateur = p_utilisateur AND a.id_lieu_connu IS NOT NULL
            AND a.periode @> tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)')
          LIMIT 1),
        (SELECT l.id_lieu_connu FROM lieu_connu l
          WHERE l.id_utilisateur = p_utilisateur AND l.nature = 'etudes'
            AND EXISTS (SELECT 1 FROM occupation o
                         WHERE o.id_utilisateur = p_utilisateur AND o.type = 'cours'
                           AND o.periode && tstzrange(debut_jour(p_jour),
                                                      debut_jour(p_jour + 1), '[)'))
          ORDER BY l.id_lieu_connu LIMIT 1),
        lieu_du_foyer(p_utilisateur));
$$;

COMMENT ON FUNCTION lieu_ou_l_on_sera(INTEGER, DATE) IS
    'ADR-9 : le lieu de l''absence qui couvre la journée, l''école un jour de cours, sinon le foyer.';
