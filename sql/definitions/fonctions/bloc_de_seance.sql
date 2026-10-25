-- -----------------------------------------------------------------------------
-- Le bloc d'une séance                                 (SPT-4, SPT-10, SPT-34)
--
-- Marge, trajet, séance, trajet, marge. La séance porte sa propre durée ;
-- faute de durée propre, celle du lieu s'applique, puis celle de la tâche
-- (SPT-9). Sans lieu, une séance libre par exemple, le bloc est la séance
-- seule.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bloc_de_seance(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_duree       INTEGER DEFAULT NULL
) RETURNS TSTZRANGE LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_lieu IS NULL AND p_duree IS NULL THEN NULL
        WHEN p_lieu IS NULL
            THEN tstzrange(p_debut, p_debut + make_interval(mins => p_duree), '[)')
        ELSE (SELECT tstzrange(p_debut - x.trajet - x.marge,
                               p_debut + x.duree + x.trajet + x.marge, '[)')
                FROM (SELECT make_interval(mins => trajet_minutes(
                                 p_utilisateur, jour_de(p_debut), l.id_lieu)) AS trajet,
                             make_interval(mins => l.marge_minutes) AS marge,
                             make_interval(mins => COALESCE(
                                 p_duree, l.duree_minutes,
                                 (SELECT t.duree_minutes FROM tache t
                                   WHERE t.id_type_tache IS NULL))) AS duree
                        FROM lieu_sport l
                       WHERE l.id_lieu = p_lieu) x)
    END;
$$;

COMMENT ON FUNCTION bloc_de_seance(INTEGER, INTEGER, TIMESTAMPTZ, INTEGER) IS
    'SPT-34 : le bloc d''une séance, trajet et battement du lieu compris (SPT-4,
     SPT-10). Sans durée propre, celle du lieu (SPT-9).';
