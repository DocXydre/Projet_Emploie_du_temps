-- -----------------------------------------------------------------------------
-- Répondre                                                     (SPT-31, SPT-32)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION repondre_invitation(p_invitation  INTEGER,
                                               p_utilisateur INTEGER,
                                               p_vient       BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    i            RECORD;
    v_occurrence INTEGER;
BEGIN
    SELECT inv.*, o.id_lieu, o.debut_seance
      INTO i
      FROM invitation_sport inv
      JOIN occurrence o ON o.id_occurrence = inv.id_occurrence
     WHERE inv.id_invitation = p_invitation
       AND inv.id_invite = p_utilisateur
     FOR UPDATE OF inv;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation introuvable' USING ERRCODE = 'no_data_found';
    END IF;

    IF i.statut <> 'attente' THEN
        RAISE EXCEPTION 'Tu as déjà répondu à cette invitation'
              USING ERRCODE = 'check_violation';
    END IF;

    IF NOT p_vient THEN
        UPDATE invitation_sport
           SET statut = 'refusee', date_reponse = now()
         WHERE id_invitation = p_invitation;
        RETURN NULL;
    END IF;

    -- Accepter, c'est choisir cette séance pour soi : elle passe par les mêmes
    -- règles que n'importe quel choix, et peut donc être refusée si l'emploi
    -- du temps a changé depuis l'invitation.
    v_occurrence := choisir_seance_sport(p_utilisateur, i.id_lieu, i.debut_seance,
                                         NULL, 'a_deux');

    UPDATE invitation_sport
       SET statut = 'acceptee', date_reponse = now(),
           id_occurrence_reponse = v_occurrence
     WHERE id_invitation = p_invitation;

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION repondre_invitation IS
    'Accepter crée sa propre séance au même endroit et à la même heure ;
     refuser ne touche à rien. Dans les deux cas la séance de celui qui a
     invité reste (SPT-31, SPT-32).';
