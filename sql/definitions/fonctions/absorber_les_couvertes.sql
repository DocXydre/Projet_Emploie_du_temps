-- -----------------------------------------------------------------------------
-- Le vidage vaut ramassage, dès le planning                            (TAC-19)
--
-- TAC-10 disait déjà que vider la litière solde le ramassage, mais seulement au
-- moment où l'on coche le vidage. Le planning, lui, affichait les deux le même
-- jour, et un ramassage oublié restait en retard à côté du vidage qui le rend
-- inutile.
--
-- Une occurrence couverte disparaît donc dans deux cas : elle tombe le même
-- jour que la tâche qui la couvre, ou elle est restée en arrière alors que
-- celle-ci est due. Un ramassage en retard ne s'efface pas devant un vidage
-- prévu dans trois jours : d'ici là il reste à faire.
--
-- Appelée deux fois par placement. Avant la boucle, quand le jour de la tâche
-- qui couvre est déjà certain : le ramassage part avant d'avoir été attribué,
-- et le tour de chacun n'est pas faussé. Après la boucle, pour ce que seul le
-- placement pouvait dire.
--
-- Une occurrence jamais annoncée s'efface sans trace, comme une prévision. Une
-- occurrence déjà annoncée est close, avec son motif, et le rappel qui
-- attendait encore part avec elle.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION absorber_les_couvertes() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    c          RECORD;
    v_retirees INTEGER := 0;
BEGIN
    FOR c IN
        SELECT DISTINCT ON (couverte.id_occurrence)
               couverte.id_occurrence, tf.libelle AS par,
               (couverte.statut = 'notifiee'
                OR EXISTS (SELECT 1 FROM notification n
                            WHERE n.id_occurrence = couverte.id_occurrence)) AS annoncee
          FROM remplacement r
          JOIN tache tf ON tf.id_tache = r.id_tache_faite AND tf.active
          JOIN occurrence faite
            ON faite.id_tache = r.id_tache_faite
           AND faite.statut IN ('a_placer', 'planifiee', 'notifiee')
          JOIN occurrence couverte
            ON couverte.id_tache = r.id_tache_couverte
           AND couverte.statut IN ('a_placer', 'planifiee', 'notifiee')
           AND NOT couverte.epinglee
               -- Le jour de la tâche qui couvre : celui de son créneau, ou
               -- celui de sa fenêtre quand elle ne dure qu'une journée.
         CROSS JOIN LATERAL (
               SELECT jour_de(COALESCE(
                          lower(faite.creneau),
                          CASE WHEN upper(faite.fenetre) - lower(faite.fenetre)
                                    <= INTERVAL '25 hours'
                               THEN lower(faite.fenetre) END)) AS jour) le
         WHERE le.jour IS NOT NULL
           AND (   -- Le même jour.
                   (couverte.creneau IS NOT NULL
                    AND jour_de(lower(couverte.creneau)) = le.jour)
                OR (couverte.creneau IS NULL
                    AND couverte.fenetre @> debut_jour(le.jour))
                   -- Ou restée en arrière d'une tâche qui est due.
                OR (le.jour <= jour_de(now())
                    AND upper(couverte.fenetre) <= debut_jour(le.jour + 1)))
         ORDER BY couverte.id_occurrence
    LOOP
        IF c.annoncee THEN
            DELETE FROM notification
             WHERE id_occurrence = c.id_occurrence AND statut = 'a_envoyer';
            UPDATE occurrence
               SET statut  = 'abandonnee',
                   creneau = NULL,
                   motif   = format('Couverte par « %s »', c.par)
             WHERE id_occurrence = c.id_occurrence;
        ELSE
            DELETE FROM occurrence WHERE id_occurrence = c.id_occurrence;
        END IF;
        v_retirees := v_retirees + 1;
    END LOOP;

    RETURN v_retirees;
END $$;

COMMENT ON FUNCTION absorber_les_couvertes() IS
    'TAC-19 : retire du planning une occurrence que couvre une autre tâche
     prévue le même jour, ou déjà due. Appelée à la fin de chaque placement.';
