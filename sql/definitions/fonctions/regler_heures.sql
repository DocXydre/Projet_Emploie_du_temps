-- -----------------------------------------------------------------------------
-- Régler ses heures                                                    (NOT-15)
--
-- Une heure changée vaut dès le lendemain : si la nouvelle heure est déjà
-- passée aujourd'hui, le rendez-vous du jour est compté comme servi. Sans
-- quoi avancer son bilan de 9h à 7h, à 8h, en enverrait un second.
--
-- L'ordonnanceur passe toutes les cinq minutes : les heures vont de cinq en
-- cinq. Il n'y a pas d'heures de silence : une notification part quand elle est
-- due, de jour comme de nuit. Le récap reste le soir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION regler_heures(p_utilisateur  INTEGER,
                                         p_bilan        TIME DEFAULT NULL,
                                         p_relance      TIME DEFAULT NULL,
                                         p_recap        TIME DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_avant utilisateur%ROWTYPE;
    v_apres utilisateur%ROWTYPE;
    v_heure TIME := (now() AT TIME ZONE 'Europe/Paris')::TIME;
    v_jour  DATE := jour_de(now());
    v_h     TIME;
BEGIN
    SELECT * INTO v_avant FROM utilisateur WHERE id_utilisateur = p_utilisateur FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte inconnu' USING ERRCODE = 'no_data_found';
    END IF;

    FOREACH v_h IN ARRAY ARRAY[p_bilan, p_relance, p_recap] LOOP
        IF v_h IS NOT NULL AND (extract(minute FROM v_h)::INTEGER % 5 <> 0
                                OR extract(second FROM v_h) <> 0) THEN
            RAISE EXCEPTION 'Les heures vont de cinq en cinq minutes : % ne tombe pas juste',
                  to_char(v_h, 'HH24hMI') USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    UPDATE utilisateur
       SET heure_bilan   = COALESCE(p_bilan, heure_bilan),
           heure_relance = COALESCE(p_relance, heure_relance),
           heure_recap   = COALESCE(p_recap, heure_recap)
     WHERE id_utilisateur = p_utilisateur
    RETURNING * INTO v_apres;

    -- PLN-9 : le récap clôt les séances du jour. Après minuit, il clôrait le
    -- lendemain avant qu'il ait commencé.
    IF v_apres.heure_recap < TIME '18:00' THEN
        RAISE EXCEPTION 'Le récap se fait le soir, à partir de 18h : il clôt les séances du jour'
              USING ERRCODE = 'check_violation';
    END IF;

    -- Dès le lendemain : la nouvelle heure déjà passée compte comme servie.
    INSERT INTO passage (id_utilisateur, moment, jour)
    SELECT p_utilisateur, c.moment, v_jour
      FROM (VALUES ('bilan',   v_avant.heure_bilan,   v_apres.heure_bilan),
                   ('relance', v_avant.heure_relance, v_apres.heure_relance),
                   ('recap',   v_avant.heure_recap,   v_apres.heure_recap)) AS c (moment, avant, apres)
     WHERE c.avant <> c.apres AND c.apres <= v_heure
    ON CONFLICT DO NOTHING;
END $$;

COMMENT ON FUNCTION regler_heures(INTEGER, TIME, TIME, TIME) IS
    'NOT-15 : règle les heures d''un compte. Une heure changée vaut dès le lendemain.';
