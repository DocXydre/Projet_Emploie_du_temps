CREATE OR REPLACE FUNCTION supprimer_calendrier(p_proprietaire INTEGER,
                                                p_calendrier   INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_parti BOOLEAN;
BEGIN
    DELETE FROM calendrier
     WHERE id_calendrier = p_calendrier
       AND id_proprietaire = p_proprietaire
    RETURNING TRUE INTO v_parti;

    RETURN COALESCE(v_parti, FALSE);
END $$;

COMMENT ON FUNCTION supprimer_calendrier IS
    'Supprime un calendrier, et seulement si on en est le propriétaire. Son
     adresse cesse aussitôt de répondre, les autres continuent (NOT-7).';
