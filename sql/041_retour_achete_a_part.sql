-- rejouable : ce fichier ne contient qu'un CREATE OR REPLACE.
-- =============================================================================
-- 041 : le retour acheté à part                                       (BIL-15)
--
-- La SNCF n'envoie plus qu'un trajet par courriel. Un aller-retour arrive donc
-- en deux fois, et le premier courriel ne sait pas quand on rentre : l'absence
-- qu'il ouvre court jusqu'à la prochaine obligation connue, faute de mieux.
--
-- Le second courriel, lui, le sait. Il ne suffit pas de fermer l'absence à
-- l'instant du retour, comme le faisait « /retour » : la fin devinée peut
-- tomber avant ce retour, et il faut alors l'allonger, pas la couper. C'est ce
-- raccord que fait cette fonction, dans les deux sens.
--
-- Et si le retour arrive le jour du départ, l'absence n'avait pas lieu d'être :
-- on dort chez soi (TRJ-10). Elle disparaît, les trains restent affichés.
-- =============================================================================

CREATE OR REPLACE FUNCTION raccorder_retour(p_retour BIGINT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_retour  trajet;
    v_absence absence;
BEGIN
    SELECT * INTO v_retour FROM trajet
     WHERE id_trajet = p_retour AND sens = 'retour';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Retour % introuvable', p_retour
            USING ERRCODE = 'no_data_found';
    END IF;

    -- TRJ-11 : le train se voit au planning, qu'il y ait absence ou non.
    PERFORM poser_trajet_au_planning(p_retour);
    UPDATE trajet SET statut = 'retenue' WHERE id_trajet = p_retour;

    -- L'absence à raccorder est la dernière commencée avant ce retour. Les deux
    -- bornes de temps évitent de rattraper un voyage d'il y a trois semaines :
    -- un retour orphelin ne doit rien déplacer.
    SELECT * INTO v_absence
      FROM absence
     WHERE id_utilisateur = v_retour.id_utilisateur
       AND lower(periode) <= lower(v_retour.periode)
       AND lower(periode) >= lower(v_retour.periode) - INTERVAL '14 days'
       AND upper(periode) >  lower(v_retour.periode) - INTERVAL '2 days'
     ORDER BY lower(periode) DESC
     LIMIT 1;

    IF NOT FOUND THEN
        -- Le billet de retour d'un voyage qu'on n'a jamais enregistré. Rien à
        -- raccorder, et rien d'anormal.
        RETURN NULL;
    END IF;

    -- TRJ-10 : parti et rentré le même jour, la journée est occupée par les
    -- trains mais les tâches du soir restent dues.
    IF jour_de(upper(v_retour.periode)) = jour_de(lower(v_absence.periode)) THEN
        DELETE FROM absence WHERE id_absence = v_absence.id_absence;
        RETURN NULL;
    END IF;

    UPDATE absence
       SET periode = tstzrange(lower(periode), upper(v_retour.periode), '[)'),
           commentaire = COALESCE(commentaire || ' — ', '') || 'retour du '
                      || to_char(upper(v_retour.periode) AT TIME ZONE 'Europe/Paris',
                                 'DD/MM HH24"h"MI')
     WHERE id_absence = v_absence.id_absence;

    UPDATE trajet t
       SET id_absence = v_absence.id_absence,
           id_trajet_aller = (SELECT a.id_trajet FROM trajet a
                               WHERE a.id_absence = v_absence.id_absence
                                 AND a.sens = 'aller'
                               ORDER BY lower(a.periode) LIMIT 1)
     WHERE t.id_trajet = p_retour;

    RETURN v_absence.id_absence;
END $$;

COMMENT ON FUNCTION raccorder_retour IS
    'Ajuste l''absence ouverte par l''aller sur l''heure du retour, dans les
     deux sens, et l''efface si le retour tombe le jour du départ (BIL-15).';
