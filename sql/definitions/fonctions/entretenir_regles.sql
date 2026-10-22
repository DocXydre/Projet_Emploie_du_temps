-- -----------------------------------------------------------------------------
-- Les règles à durée de vie, au report de minuit                       (CND-14)
--
-- Une règle dont la période est finie s'éteint, et ses rappels avec elle. Sept
-- jours avant, celui qui l'a posée en est prévenu. Une règle qui revient chaque
-- année ne s'éteint pas : elle se repose d'elle-même l'année suivante.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION entretenir_regles()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    -- Annexe 3 : prévenir une semaine avant la fin.
    PREAVIS CONSTANT INTEGER := 7;
    v_aujourdhui DATE := jour_de(now());
    v_eteintes   INTEGER;
BEGIN
    WITH eteintes AS (
        UPDATE regle_tache SET etat = 'expiree'
         WHERE etat IN ('active', 'suspendue')
           AND NOT chaque_annee
           AND validite IS NOT NULL
           AND upper(validite) <= v_aujourdhui
        RETURNING id_regle_tache
    )
    UPDATE rappel_hal SET etat = 'annule'
     WHERE etat = 'attente' AND id_regle_tache IN (SELECT id_regle_tache FROM eteintes);

    SELECT count(*) INTO v_eteintes FROM regle_tache
     WHERE etat = 'expiree' AND upper(validite) = v_aujourdhui;

    INSERT INTO notification (id_utilisateur, type, contenu)
    SELECT r.posee_par, 'regle',
           format('La règle de « %s » s''arrête le %s : %s',
                  t.libelle, to_char(upper(r.validite) - 1, 'DD/MM'), r.traduction)
      FROM regle_tache r
      JOIN tache t ON t.id_tache = r.id_tache
     WHERE r.etat = 'active'
       AND NOT r.chaque_annee
       AND r.validite IS NOT NULL
       AND upper(r.validite) - 1 = v_aujourdhui + PREAVIS;

    RETURN v_eteintes;
END $$;

COMMENT ON FUNCTION entretenir_regles() IS
    'CND-14 : éteint les règles dont la période est finie et prévient sept jours avant. Rend le nombre éteintes ce jour.';
