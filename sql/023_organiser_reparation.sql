-- rejouable : ce fichier ne contient qu'un CREATE OR REPLACE.
-- =============================================================================
-- 023 : « /organiser » ne répondait rien                            (SPT-13)
--
-- `creneaux_sport_semaine` déclare une colonne de sortie nommée `code`. À
-- l'intérieur, « WHERE code = 'SPORT' » ne désigne donc plus la colonne de la
-- table mais la variable de sortie, et PostgreSQL refuse de trancher :
--
--     column reference "code" is ambiguous
--
-- La fonction levait à chaque appel. Le bot n'attrapait rien et n'envoyait rien,
-- d'où une commande qui paraissait morte. La proposition du lundi passait par
-- le même chemin et n'a donc jamais fonctionné non plus.
--
-- Le correctif tient à un alias de table. Il est écrit ici plutôt que dans le
-- 016, que la base a déjà appliqué.
-- =============================================================================

CREATE OR REPLACE FUNCTION creneaux_sport_semaine(
    p_utilisateur INTEGER,
    p_lundi       DATE DEFAULT NULL
) RETURNS TABLE (
    jour    DATE,
    id_lieu INTEGER,
    code    VARCHAR,
    libelle VARCHAR,
    rang    SMALLINT,
    creneau TSTZRANGE
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lundi DATE := COALESCE(p_lundi, lundi_de(jour_de(now())));
    v_tache INTEGER;
    d       DATE;
BEGIN
    -- L'alias est obligatoire : sans lui, « code » désigne la colonne de sortie
    -- déclarée plus haut, et non celle de la table.
    SELECT t.id_tache INTO v_tache
      FROM tache t WHERE t.code = 'SPORT' AND t.active;

    IF v_tache IS NULL THEN
        RETURN;
    END IF;

    d := GREATEST(v_lundi, jour_de(now()));
    WHILE d < v_lundi + 7 LOOP
        RETURN QUERY
        SELECT d, c.id_lieu, c.code, c.libelle, c.rang, c.creneau
          FROM creneaux_sport_du_jour(p_utilisateur, v_tache, d) c;
        d := d + 1;
    END LOOP;
END $$;
