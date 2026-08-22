-- rejouable : ce fichier ne contient que des CREATE OR REPLACE, des IF NOT
--             EXISTS et des INSERT idempotents.
-- =============================================================================
-- 011 — Calendriers personnels                                       (R83–R85)
-- =============================================================================
-- Jusqu'ici, les emplois du temps venaient de flux qu'on subit : l'université
-- publie, McDonald's publie, on collecte. Lorette n'a rien de tel, et Thomas a
-- des choses qui ne figurent dans aucun de ces deux flux.
--
-- La solution est celle qui demande le moins : chacun tient son calendrier
-- dans l'application qu'il utilise déjà, le publie, et donne le lien. Le
-- collecteur iCalendar existe et ne change pas — seul le profil de lecture
-- diffère, puisqu'il n'y a rien à nettoyer dans ce qu'une personne a écrit
-- elle-même.
--
-- Ces occupations sont de type « autre » et non « cours » : elles ne sont donc
-- pas soumises à la contrainte d'exclusion, et deux événements peuvent se
-- chevaucher. C'est délibéré — un calendrier personnel contient souvent un
-- rendez-vous posé sur une plage plus large, et refuser la collecte pour ça
-- serait absurde (R84).
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
     Donner l''URL les active (R83).';


-- -----------------------------------------------------------------------------
-- Rattachement des calendriers à leur propriétaire                        (R85)
--
-- L'ordre compte. `appliquer_assignations` attribue à Thomas toute source
-- encore orpheline — ce qui lui donnerait le calendrier de Lorette. Cette
-- fonction-ci doit donc passer avant, et c'est ce que fait l'amorçage.
--
-- Le rattachement se lit dans le code de la source : PERSO_LORETTE appartient
-- à lorette. Une convention plutôt qu'une table de correspondance, parce
-- qu'une table de deux lignes qu'il faut tenir à jour est une table de trop.
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
