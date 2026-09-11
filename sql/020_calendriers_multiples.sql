-- rejouable : ce fichier ne contient que des CREATE OR REPLACE et des INSERT
--             idempotents.
-- =============================================================================
-- 020 : plusieurs calendriers pour une même personne               (COL-14, COL-16)
--
-- Lorette n'en tient pas un mais deux : ses cours d'un côté, ses gardes
-- d'enfants de l'autre. Ce sont deux calendriers distincts dans son téléphone,
-- publiés séparément, et rien ne gagne à les fusionner à la main.
--
-- La convention de nommage s'élargit donc d'un cran : PERSO_<PSEUDO> reste le
-- calendrier principal, PERSO_<PSEUDO>_<QUOI> en désigne un autre. Le
-- rattachement continue de se lire dans le code, sans table de correspondance.
-- =============================================================================

CREATE OR REPLACE FUNCTION assigner_calendriers_perso() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER;
BEGIN
    -- Une expression régulière et non un LIKE : dans un motif LIKE, le tiret
    -- bas est un joker, « PERSO_LORETTE_% » accepterait donc PERSO_LORETTEX.
    UPDATE source s
       SET id_utilisateur = u.id_utilisateur
      FROM utilisateur u
     WHERE s.code ~ ('^PERSO_' || upper(u.pseudo) || '(_|$)')
       AND s.id_utilisateur IS DISTINCT FROM u.id_utilisateur;

    GET DIAGNOSTICS v_touchees = ROW_COUNT;
    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION assigner_calendriers_perso() IS
    'Rattache PERSO_<PSEUDO> et PERSO_<PSEUDO>_<QUOI> à leur propriétaire. À
     exécuter avant appliquer_assignations(), qui donnerait sinon toute source
     orpheline à l''administrateur.';


-- -----------------------------------------------------------------------------
-- Le second calendrier de Lorette
--
-- Les gardes d'enfants occupent l'agenda comme le reste. Type « autre » et non
-- « travail » : la contrainte d'exclusion ne vise que les cours et les shifts,
-- et un créneau de garde publié en doublon ne doit pas faire échouer une
-- collecte entière.
-- -----------------------------------------------------------------------------
INSERT INTO source (code, libelle, mode_collecte, frequence_heures, url,
                    configuration, active)
VALUES
    ('PERSO_LORETTE_BABYSITTING', 'Gardes d''enfants de Lorette', 'ics', 6, NULL,
     '{
        "profil": "perso",
        "type_occupation": "autre",
        "horizon_jours": 150,
        "historique_jours": 7
      }'::JSONB,
     FALSE)
ON CONFLICT (code) DO NOTHING;

SELECT assigner_calendriers_perso();
