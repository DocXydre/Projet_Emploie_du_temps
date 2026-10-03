-- -----------------------------------------------------------------------------
-- Rouvrir la semaine à la répartition                                  (PLA-13)
--
-- Ce qui est épinglé, annoncé, déjà commencé ou nominatif ne bouge pas. Le
-- reste repasse « à placer » et sera redistribué au prochain placement, qui
-- suit immédiatement.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reequilibrer(p_jours INTEGER DEFAULT 7)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_liberees INTEGER;
BEGIN
    UPDATE occurrence o
       SET id_utilisateur = NULL,
           creneau        = NULL,
           statut         = 'a_placer',
           motif          = NULL
      FROM tache t
     WHERE t.id_tache = o.id_tache
       AND o.statut = 'planifiee'
       AND NOT o.epinglee
       -- Une séance de sport est personnelle : elle ne se redistribue pas.
       AND o.origine <> 'quota'
       -- TAC-18, ABS-8 : une tâche de départ ou de retour revient à celui qui
       -- part le dernier ou rentre le premier, pas au roulement.
       AND o.origine NOT IN ('depart', 'retour')
       AND t.categorie <> 'sport'
       -- ABS-2 : le pliage du linge reste à Lorette, quoi qu'il arrive.
       AND t.id_utilisateur_defaut IS NULL
       -- TAC-9 : une tâche à deux n'a personne à qui la reprendre.
       AND NOT t.requiert_les_deux
       AND o.creneau IS NOT NULL
       AND lower(o.creneau) > now()
       AND lower(o.creneau) < now() + make_interval(days => p_jours)
       -- Une tâche déjà annoncée reste où elle est : on ne retire pas de la
       -- liste de quelqu'un ce qu'il a lu ce matin.
       AND NOT EXISTS (SELECT 1 FROM notification n
                        WHERE n.id_occurrence = o.id_occurrence
                          AND n.statut IN ('a_envoyer', 'envoyee'));

    GET DIAGNOSTICS v_liberees = ROW_COUNT;
    RETURN v_liberees;
END $$;

COMMENT ON FUNCTION reequilibrer IS
    'Libère l''assigné des tâches à venir non annoncées, pour que le placement
     suivant les redistribue avec les charges à jour (PLA-13).';
