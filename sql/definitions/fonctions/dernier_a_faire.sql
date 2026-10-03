-- -----------------------------------------------------------------------------
-- Qui l'a faite en dernier                                             (PLA-12)
--
-- La dernière occurrence attribuée, faite ou seulement prévue. Prévue compte
-- aussi : pendant un placement, les occurrences d'une même tâche se suivent, et
-- c'est précisément entre elles qu'on veut alterner.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dernier_a_faire(p_tache INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT o.id_utilisateur
      FROM occurrence o
     WHERE o.id_tache = p_tache
       AND o.id_utilisateur IS NOT NULL
       AND o.statut IN ('faite', 'planifiee', 'notifiee')
     ORDER BY COALESCE(o.date_faite, lower(o.creneau), upper(o.fenetre)) DESC,
              o.id_occurrence DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION dernier_a_faire IS
    'La personne de la dernière occurrence de cette tâche, faite ou prévue.
     C''est elle que le tour suivant évite (PLA-12).';
