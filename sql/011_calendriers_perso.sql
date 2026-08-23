-- rejouable : ce fichier ne contient que des CREATE OR REPLACE, des IF NOT
--             EXISTS et des INSERT idempotents.
-- =============================================================================
-- 011 : calendriers personnels                              (COL-14 à COL-16)
--
-- Chacun tient son calendrier dans son application, le publie, et donne le
-- lien. Le collecteur iCalendar ne change pas, seul le profil de lecture
-- diffère : il n'y a rien à nettoyer dans ce qu'une personne a écrit.
--
-- Ces occupations sont de type « autre », donc hors de la contrainte
-- d'exclusion : deux événements personnels peuvent se chevaucher (COL-15).
-- =============================================================================

INSERT INTO source (code, libelle, mode_collecte, frequence_heures, url,
                    configuration, active)
VALUES
    ('PERSO_THOMAS', 'Calendrier personnel de Thomas', 'ics', 6, NULL,
     '{
        "profil": "perso",
        "type_occupation": "autre",
        "horizon_jours": 150,
        "historique_jours": 7
      }'::JSONB,
     FALSE),

    ('PERSO_LORETTE', 'Calendrier personnel de Lorette', 'ics', 6, NULL,
     '{
        "profil": "perso",
        "type_occupation": "autre",
        "horizon_jours": 150,
        "historique_jours": 7
      }'::JSONB,
     FALSE)
ON CONFLICT (code) DO NOTHING;

COMMENT ON COLUMN source.active IS
    'Les calendriers personnels naissent inactifs : sans URL, une collecte
     échouerait toutes les heures et ferait passer la source pour en panne.
     Donner l''URL les active (COL-14).';


-- -----------------------------------------------------------------------------
-- Rattachement des calendriers à leur propriétaire                        (COL-16)
--
-- L'ordre compte : `appliquer_assignations` donne à l'administrateur toute
-- source orpheline, donc cette fonction doit passer avant.
--
-- Le propriétaire se lit dans le code : PERSO_LORETTE appartient à lorette.
-- Une convention suffit, une table de correspondance de deux lignes non.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assigner_calendriers_perso() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER;
BEGIN
    UPDATE source s
       SET id_utilisateur = u.id_utilisateur
      FROM utilisateur u
     WHERE s.code = 'PERSO_' || upper(u.pseudo)
       AND s.id_utilisateur IS DISTINCT FROM u.id_utilisateur;

    GET DIAGNOSTICS v_touchees = ROW_COUNT;
    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION assigner_calendriers_perso() IS
    'Rattache PERSO_<PSEUDO> à son propriétaire. À exécuter avant
     appliquer_assignations(), qui donnerait sinon tout à l''administrateur.';

-- Application immédiate, sans effet si les comptes n'existent pas encore.
SELECT assigner_calendriers_perso();
