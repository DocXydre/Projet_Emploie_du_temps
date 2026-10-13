-- -----------------------------------------------------------------------------
-- La relance du soir d'un compte, à son heure              (NOT-15, SPT-25)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION relance_du_soir_de(p_utilisateur INTEGER)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    o        RECORD;
    v_creees INTEGER := 0;
    v_jour   DATE := jour_de(now());
BEGIN
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur,
               -- Pour une séance, le sport dit mieux que « Séance de sport ».
               COALESCE(l.libelle, t.libelle) AS libelle
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
          LEFT JOIN lieu_sport l ON l.id_lieu = oc.id_lieu
         WHERE oc.statut = 'notifiee'
           -- SPT-25 : une réservation qu'on n'a pas choisie ne se valide pas.
           AND oc.origine <> 'quota'
           AND oc.creneau IS NOT NULL
           AND jour_de(lower(oc.creneau)) = v_jour
           AND oc.id_utilisateur IS NOT NULL
           -- NOT-15 : un compte à son heure, ou tous quand on l'appelle sans.
           AND (p_utilisateur IS NULL OR oc.id_utilisateur = p_utilisateur)
         ORDER BY t.priorite
    LOOP
        -- Une seule relance par tâche et par soir.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM notification
             WHERE id_occurrence = o.id_occurrence
               AND type = 'rappel'
               AND jour_de(date_creation) = v_jour
        );

        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        VALUES (o.id_utilisateur, o.id_occurrence, 'rappel',
                o.libelle || ' : c''est fait ?');

        v_creees := v_creees + 1;
    END LOOP;

    RETURN v_creees;
END $function$;

COMMENT ON FUNCTION relance_du_soir_de(INTEGER) IS
    'NOT-15, SPT-25 : la relance du soir d''un compte, ou de tous avec NULL.';
