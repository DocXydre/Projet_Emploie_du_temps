-- -----------------------------------------------------------------------------
-- Noter un fait qui n'est pas une ligne de table                        (JRN-7)
--
-- Un déploiement, un redémarrage, une relève de la boîte qui n'a rien trouvé :
-- rien ne change en base, et c'est pourtant ce qu'on cherche quand on demande
-- pourquoi il ne s'est rien passé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION noter_evenement(p_objet     TEXT,
                                           p_libelle   TEXT,
                                           p_detail    TEXT    DEFAULT NULL,
                                           p_technique BOOLEAN DEFAULT FALSE)
RETURNS BIGINT LANGUAGE sql AS $$
    INSERT INTO evenement (operation, acteur, origine, objet, libelle, detail, technique)
    VALUES (COALESCE(NULLIF(current_setting('planif.operation', TRUE), ''),
                     'tx' || txid_current()),
            COALESCE(NULLIF(current_setting('planif.acteur', TRUE), ''), 'direct'),
            NULLIF(current_setting('planif.origine', TRUE), ''),
            p_objet, p_libelle, p_detail, p_technique)
    RETURNING id_evenement
$$;

COMMENT ON FUNCTION noter_evenement(TEXT, TEXT, TEXT, BOOLEAN) IS
    'JRN-7 : inscrit au journal un fait sans ligne de table. L''auteur et
     l''opération viennent du contexte de la session.';
