-- -----------------------------------------------------------------------------
-- Les contenus                                                          (NOT-6)
--
-- Six familles, et pas une par catégorie de tâche : le but est de cocher des
-- cases sur un téléphone, pas de reconstituer le modèle de données. « Tâches »
-- regroupe donc le ménage, le linge, la vaisselle, le chat et l'administratif,
-- tandis que le sport sort du lot parce qu'il se planifie à part.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contenu_de(p_nature TEXT, p_categorie TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_nature = 'proposition'                          THEN 'weekends'
        WHEN p_nature = 'occupation' AND p_categorie = 'cours'   THEN 'cours'
        WHEN p_nature = 'occupation' AND p_categorie = 'travail' THEN 'travail'
        WHEN p_nature = 'occupation'                             THEN 'perso'
        WHEN p_categorie = 'sport'                               THEN 'sport'
        ELSE 'taches'
    END;
$$;

COMMENT ON FUNCTION contenu_de IS
    'Range une ligne de planning dans l''une des six familles cochables :
     cours, travail, perso, taches, sport, weekends (NOT-6).';
