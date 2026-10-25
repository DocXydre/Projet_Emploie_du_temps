CREATE OR REPLACE FUNCTION appliquer_assignations() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER := 0;
    v_lot      INTEGER;
BEGIN
    -- Aucune tâche n'est donnée à quelqu'un ici : « pour qui » se règle dans
    -- l'appli (TAC-29). Le pliage du linge revenait d'office à Lorette à chaque
    -- démarrage, par-dessus ce qu'on avait choisi.

    -- Les emplois du temps collectés sont ceux de Thomas.
    UPDATE source
       SET id_utilisateur = u.id_utilisateur
      FROM utilisateur u
     WHERE u.pseudo = 'thomas'
       AND source.id_utilisateur IS NULL;
    GET DIAGNOSTICS v_lot = ROW_COUNT;
    v_touchees := v_touchees + v_lot;

    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION appliquer_assignations() IS
    'Idempotente : ne touche que ce qui n''est pas déjà assigné. Rejouée à
     chaque démarrage de l''API, elle rattrape les comptes créés après coup.';
