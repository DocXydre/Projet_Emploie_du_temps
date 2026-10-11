CREATE OR REPLACE FUNCTION limite_memoire(p_niveau TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_niveau
               WHEN 'globale'      THEN 4000
               WHEN 'archive_mois' THEN 1500
               WHEN 'mois'         THEN 3000
               WHEN 'semaine'      THEN 3000
           END;
$$;

COMMENT ON FUNCTION limite_memoire(TEXT) IS
    'MEM-3 : la longueur maximale, en caractères, de chaque étage de la mémoire.
     Plus on remonte loin, moins il y a de détail : c''est la limite qui oblige
     à résumer.';
