-- Les briques d'une règle, remplacées en entier (CND-1).
CREATE OR REPLACE FUNCTION ecrire_briques(p_regle INTEGER, p_briques JSONB)
RETURNS VOID LANGUAGE sql AS $$
    DELETE FROM brique_regle WHERE id_regle_tache = p_regle;
    INSERT INTO brique_regle (id_regle_tache, nature, pour_qui, id_utilisateur, parametres)
    SELECT p_regle, e ->> 'nature', e ->> 'pour_qui', (e ->> 'id_utilisateur')::INTEGER,
           COALESCE(e -> 'parametres', '{}'::JSONB)
      FROM jsonb_array_elements(COALESCE(p_briques, '[]'::JSONB)) e;
$$;
