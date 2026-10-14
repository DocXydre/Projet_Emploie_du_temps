-- -----------------------------------------------------------------------------
-- Inviter                                                              (SPT-31)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION inviter_a_la_seance(p_occurrence INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o          RECORD;
    v_lieu     TEXT;
    v_qui      TEXT;
    p          INTEGER;
    v_invitation INTEGER;
    v_n        INTEGER := 0;
BEGIN
    SELECT oc.id_occurrence, oc.id_utilisateur, oc.id_lieu, oc.debut_seance
      INTO o
      FROM occurrence oc
      JOIN tache t ON t.id_tache = oc.id_tache
     WHERE oc.id_occurrence = p_occurrence
       AND t.code = 'SPORT'
       AND oc.origine <> 'quota'
       AND oc.statut IN ('planifiee', 'notifiee');
    IF NOT FOUND OR o.debut_seance IS NULL THEN
        RETURN 0;
    END IF;

    SELECT libelle INTO v_lieu FROM lieu_sport WHERE id_lieu = o.id_lieu;
    SELECT nom INTO v_qui FROM utilisateur WHERE id_utilisateur = o.id_utilisateur;

    FOR p IN SELECT s FROM partenaires_sport(o.id_utilisateur) s LOOP
        -- On n'invite que qui peut venir : une invitation à un créneau de
        -- cours se referme sur un refus qui n'apprend rien à personne.
        CONTINUE WHEN obstacle_seance(p, o.id_lieu, o.debut_seance, NULL, TRUE) IS NOT NULL;

        INSERT INTO invitation_sport (id_occurrence, id_invite)
        VALUES (p_occurrence, p)
        ON CONFLICT (id_occurrence, id_invite) DO NOTHING
        RETURNING id_invitation INTO v_invitation;

        CONTINUE WHEN v_invitation IS NULL;   -- déjà invitée

        INSERT INTO notification (id_utilisateur, type, contenu, id_invitation)
        VALUES (p, 'sport',
                format('%s fait %s le %s. Tu viens ?',
                       v_qui, lower(v_lieu),
                       to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                               'DD/MM à HH24hMI')),
                v_invitation);
        v_n := v_n + 1;
    END LOOP;

    RETURN v_n;
END $$;

COMMENT ON FUNCTION inviter_a_la_seance IS
    'Invite les autres comptes libres sur ce créneau, et leur envoie la
     question. N''engage personne (SPT-31).';
