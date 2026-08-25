-- =============================================================================
-- 006 : assignations par défaut
--
-- Qui fait quoi, et à qui appartiennent les emplois du temps collectés. Les
-- comptes n'existent pas forcément au moment des migrations, donc on passe par
-- une fonction, rejouée à chaque démarrage.
-- =============================================================================

CREATE OR REPLACE FUNCTION appliquer_assignations() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER := 0;
    v_lot      INTEGER;
BEGIN
    -- Le pliage du linge revient à Lorette.
    UPDATE tache
       SET id_utilisateur_defaut = u.id_utilisateur
      FROM utilisateur u
     WHERE u.pseudo = 'lorette'
       AND tache.code = 'PLIER_LINGE'
       AND tache.id_utilisateur_defaut IS DISTINCT FROM u.id_utilisateur;
    GET DIAGNOSTICS v_lot = ROW_COUNT;
    v_touchees := v_touchees + v_lot;

    -- Tout le reste reste sans assigné : c'est le placement qui décide, selon
    -- qui est présent et qui en a déjà le plus. Figer l'assignation ici
    -- bloquerait la réattribution pendant les absences (ABS-2, ABS-3).

    -- Les emplois du temps collectés sont ceux de Thomas.
    UPDATE source
       SET id_utilisateur = u.id_utilisateur
      FROM utilisateur u
     WHERE u.pseudo = 'thomas'
       AND source.id_utilisateur IS NULL;
    GET DIAGNOSTICS v_lot = ROW_COUNT;
    v_touchees := v_touchees + v_lot;

    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION appliquer_assignations() IS
    'Idempotente : ne touche que ce qui n''est pas déjà assigné. Rejouée à
     chaque démarrage de l''API, elle rattrape les comptes créés après coup.';

-- Application immédiate, sans effet si aucun compte n'existe encore.
SELECT appliquer_assignations();
