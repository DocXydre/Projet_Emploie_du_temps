-- -----------------------------------------------------------------------------
-- Revérifier                                                            (WKD-9)
--
-- Seuls les cours et le travail retiennent sur place, comme pour le repérage
-- (TRJ-1). Une proposition déjà commencée n'est pas touchée : à ce stade, soit
-- on est parti et une absence l'a soldée, soit on est resté et elle s'éteint
-- d'elle-même.
--
-- WKD-10 : si la proposition avait déjà été annoncée, ce qu'on a dit est devenu
-- faux. On le corrige, une fois, en nommant ce qui a changé. Sans annonce
-- préalable il n'y a rien à corriger, et le calendrier suffit.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reverifier_propositions(p_duree_heures INTEGER DEFAULT 48)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    p          proposition;
    v_libre    TSTZMULTIRANGE;
    v_reste    TSTZRANGE;
    v_obstacle RECORD;
    v_cause    TEXT;
    v_lieu     TEXT;
    v_touchees INTEGER := 0;
BEGIN
    FOR p IN
        SELECT * FROM proposition
         WHERE statut = 'proposee' AND lower(periode) > now()
         ORDER BY lower(periode)
    LOOP
        SELECT tstzmultirange(p.periode)
               - COALESCE(range_agg(o.periode), '{}'::TSTZMULTIRANGE)
          INTO v_libre
          FROM occupation o
         WHERE o.id_utilisateur = p.id_utilisateur
           AND o.type IN ('cours', 'travail')
           AND o.periode && p.periode;

        -- Le plus long morceau encore libre. À durée égale, le premier.
        SELECT r INTO v_reste
          FROM unnest(v_libre) r
         ORDER BY upper(r) - lower(r) DESC, lower(r)
         LIMIT 1;

        CONTINUE WHEN v_reste = p.periode;

        -- Ce qui est venu se mettre en travers, pour pouvoir le dire.
        SELECT o.libelle, lower(o.periode) AS debut INTO v_obstacle
          FROM occupation o
         WHERE o.id_utilisateur = p.id_utilisateur
           AND o.type IN ('cours', 'travail')
           AND o.periode && p.periode
         ORDER BY lower(o.periode)
         LIMIT 1;

        v_cause := format('« %s » tombe le %s',
                          v_obstacle.libelle,
                          to_char(v_obstacle.debut AT TIME ZONE 'Europe/Paris',
                                  'DD/MM à HH24hMI'));
        v_lieu  := COALESCE(' à ' || p.lieu, '');

        -- Un message pas encore parti parlerait de dates qui n'existent plus.
        DELETE FROM notification
         WHERE id_proposition = p.id_proposition AND statut = 'a_envoyer';

        IF v_reste IS NULL
           OR upper(v_reste) - lower(v_reste) < make_interval(hours => p_duree_heures) THEN
            -- Plus de quoi partir : la proposition n'a plus d'objet.
            UPDATE proposition SET statut = 'perimee'
             WHERE id_proposition = p.id_proposition;

            IF p.annoncee_le IS NOT NULL THEN
                INSERT INTO notification (id_utilisateur, type, contenu)
                VALUES (p.id_utilisateur, 'alerte',
                        format('Le week-end libre%s du %s ne tient plus : %s.',
                               v_lieu,
                               to_char(lower(p.periode) AT TIME ZONE 'Europe/Paris', 'DD/MM'),
                               v_cause));
            END IF;
        ELSE
            UPDATE proposition SET periode = v_reste
             WHERE id_proposition = p.id_proposition;

            IF p.annoncee_le IS NOT NULL THEN
                INSERT INTO notification (id_utilisateur, type, contenu, id_proposition)
                VALUES (p.id_utilisateur, 'alerte',
                        format('Le week-end libre%s a changé : %s.' || E'\n'
                               || 'Il va maintenant du %s au %s.',
                               v_lieu, v_cause,
                               to_char(lower(v_reste) AT TIME ZONE 'Europe/Paris',
                                       'DD/MM à HH24hMI'),
                               to_char(upper(v_reste) AT TIME ZONE 'Europe/Paris',
                                       'DD/MM à HH24hMI')),
                        p.id_proposition);
            END IF;
        END IF;

        v_touchees := v_touchees + 1;
    END LOOP;

    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION reverifier_propositions IS
    'Rétrécit chaque proposition à venir au plus long morceau encore libre, ou
     la périme s''il ne reste plus de quoi partir. Ne l''allonge jamais (WKD-9).
     Corrige une annonce déjà faite, une seule fois (WKD-10).';
