CREATE OR REPLACE FUNCTION minimum_sport(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT u.minimum_sport FROM utilisateur u
          WHERE u.id_utilisateur = p_utilisateur AND u.actif),
        (SELECT t.quota_hebdomadaire FROM tache t WHERE t.code = 'SPORT' AND t.active),
        3);
$$;

COMMENT ON FUNCTION minimum_sport IS
    'Le minimum hebdomadaire de ce compte : le sien, sinon celui de la tâche,
     sinon trois (SPT-28).';
