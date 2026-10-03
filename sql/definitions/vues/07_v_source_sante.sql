-- ----------------------------------------------------------------------------
-- Santé des sources                                                      (COL-9)
-- -----------------------------------------------------------------------------
CREATE VIEW v_source_sante AS
SELECT
    s.id_source,
    s.code,
    s.libelle,
    s.mode_collecte,
    s.frequence_heures,
    s.derniere_collecte,
    s.active,
    CASE
        -- Une source manuelle ne périme jamais : c'est le mode dégradé.
        WHEN s.mode_collecte = 'manuelle' OR NOT s.active THEN 'ok'
        WHEN s.derniere_collecte IS NULL                   THEN 'en_panne'
        WHEN now() - s.derniere_collecte
             > make_interval(hours => s.frequence_heures * 2) THEN 'en_panne'
        ELSE 'ok'
    END AS etat_calcule,
    now() - s.derniere_collecte AS anciennete
FROM source s;

COMMENT ON VIEW v_source_sante IS
    'Le moteur ne doit jamais planifier sur des données périmées sans le
     signaler : un planning silencieusement faux est pire que pas de planning.';
