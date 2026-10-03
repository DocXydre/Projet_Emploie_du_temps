-- -----------------------------------------------------------------------------
-- Retenir un trajet                                        (TRJ-9 à TRJ-11)
--
-- Ce qui change : l'absence n'est déclarée que si le voyage passe une nuit
-- dehors. Un aller-retour dans la journée laisse la journée occupée par les
-- trains, sans geler les tâches du soir.
--
-- La fonction rend l'identifiant de l'absence, ou NULL quand il n'y en a pas
-- besoin. L'appelant n'a donc plus à supposer qu'une absence existe.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retenir_trajet(
    p_aller  BIGINT,
    p_retour BIGINT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_aller       trajet;
    v_retour      trajet;
    v_fin         TIMESTAMPTZ;
    v_absence     INTEGER;
    v_commentaire TEXT;
    v_meme_jour   BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_aller FROM trajet WHERE id_trajet = p_aller AND sens = 'aller';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Aller % introuvable', p_aller
            USING ERRCODE = 'no_data_found';
    END IF;

    IF p_retour IS NOT NULL THEN
        SELECT * INTO v_retour FROM trajet WHERE id_trajet = p_retour AND sens = 'retour';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Retour % introuvable', p_retour
                USING ERRCODE = 'no_data_found';
        END IF;

        IF lower(v_retour.periode) < upper(v_aller.periode) THEN
            RAISE EXCEPTION 'Le retour part avant l''arrivée de l''aller'
                USING ERRCODE = 'check_violation';
        END IF;

        v_fin := upper(v_retour.periode);
        v_meme_jour := jour_de(upper(v_retour.periode)) = jour_de(lower(v_aller.periode));
        v_commentaire := 'Aller ' || to_char(lower(v_aller.periode) AT TIME ZONE 'Europe/Paris',
                                             'DD/MM HH24"h"MI')
                      || ', retour ' || to_char(upper(v_retour.periode) AT TIME ZONE 'Europe/Paris',
                                                'DD/MM HH24"h"MI');
    ELSE
        -- TRJ-7 : sans retour choisi, l'absence court jusqu'à ce qui nous rappelle.
        SELECT f.fin INTO v_fin
          FROM fenetres_de_depart(v_aller.id_utilisateur,
                                  lower(v_aller.periode) - INTERVAL '1 hour',
                                  lower(v_aller.periode) + INTERVAL '30 days',
                                  1) f
         ORDER BY f.debut
         LIMIT 1;

        v_fin := COALESCE(v_fin, upper(v_aller.periode) + INTERVAL '2 days');
        v_commentaire := 'Aller ' || to_char(lower(v_aller.periode) AT TIME ZONE 'Europe/Paris',
                                             'DD/MM HH24"h"MI') || ', retour à fixer';
    END IF;

    -- TRJ-11 : les trains s'affichent, qu'il y ait absence ou non.
    PERFORM poser_trajet_au_planning(p_aller);
    IF p_retour IS NOT NULL THEN
        PERFORM poser_trajet_au_planning(p_retour);
    END IF;

    -- TRJ-10 : parti et revenu le même jour, on dort chez soi. Les tâches du
    -- soir restent dues, seuls les trains occupent la journée.
    IF v_meme_jour THEN
        UPDATE trajet SET statut = 'retenue' WHERE id_trajet IN (p_aller, p_retour);
        RETURN NULL;
    END IF;

    INSERT INTO absence (id_utilisateur, periode, lieu, origine, commentaire)
    VALUES (v_aller.id_utilisateur,
            tstzrange(lower(v_aller.periode), v_fin, '[)'),
            v_aller.destination, 'trajet', v_commentaire)
    RETURNING id_absence INTO v_absence;

    UPDATE trajet
       SET statut = 'retenue', id_absence = v_absence
     WHERE id_trajet IN (p_aller, p_retour);

    -- TRJ-6 : les autres horaires proposés passent en « écartée ». On les
    -- garde en base pour pouvoir relire ce qui avait été proposé.
    UPDATE trajet
       SET statut = 'ecartee'
     WHERE statut = 'proposee'
       AND id_utilisateur = v_aller.id_utilisateur
       AND (id_trajet_aller = p_aller
            OR (sens = 'aller'
                AND lower(periode) BETWEEN lower(v_aller.periode) - INTERVAL '2 days'
                                       AND lower(v_aller.periode) + INTERVAL '2 days'));

    RETURN v_absence;
END $$;

COMMENT ON FUNCTION retenir_trajet IS
    'Transforme des horaires choisis en trains affichés, et en absence si le
     voyage passe une nuit dehors (TRJ-5, TRJ-10, TRJ-11). Rend NULL pour un
     aller-retour dans la journée.';
