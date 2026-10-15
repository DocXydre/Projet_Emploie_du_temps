-- -----------------------------------------------------------------------------
-- Relier deux tâches                                            (TAC-27, TAC-28)
--
-- Trois sortes de liens, dans les trois tables qui les portaient déjà :
--
--   « ensuite »     enchainement     faire celle-ci fait naître l'autre, entre
--                                    deux délais en heures (TAC-7, EXE-2)
--   « meme_jour »   accompagnement   l'autre vient le même jour, avant ou après,
--                                    pour la même personne (TAC-15)
--   « vaut_aussi »  remplacement     la faire solde l'autre (TAC-10, TAC-19)
--
-- Rend le numéro du lien dans sa table. Les refus disent pourquoi : un lien qui
-- boucle ferait naître les deux tâches l'une de l'autre sans fin, et deux
-- tâches qui se valent l'une l'autre se solderaient mutuellement.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lier_taches(p_sorte            TEXT,
                                       p_tache            INTEGER,
                                       p_autre            INTEGER,
                                       p_delai_min_heures INTEGER DEFAULT 0,
                                       p_delai_max_heures INTEGER DEFAULT 24,
                                       p_place            TEXT    DEFAULT 'avant',
                                       p_mention          TEXT    DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_de   tache%ROWTYPE;
    v_vers tache%ROWTYPE;
    v_id   INTEGER;
BEGIN
    IF p_sorte NOT IN ('ensuite', 'meme_jour', 'vaut_aussi') THEN
        RAISE EXCEPTION 'Un lien est « ensuite », « meme_jour » ou « vaut_aussi »'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_tache = p_autre THEN
        RAISE EXCEPTION 'Une tâche ne se relie pas à elle-même'
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_de   FROM tache WHERE id_tache = p_tache;
    SELECT * INTO v_vers FROM tache WHERE id_tache = p_autre;
    IF v_de.id_tache IS NULL OR v_vers.id_tache IS NULL THEN
        RAISE EXCEPTION 'Une des deux tâches n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT v_de.active OR NOT v_vers.active THEN
        RAISE EXCEPTION '« % » est arrêtée : on ne la relie plus',
                        CASE WHEN v_de.active THEN v_vers.libelle ELSE v_de.libelle END
              USING ERRCODE = 'check_violation';
    END IF;
    IF v_de.categorie = 'sport' OR v_vers.categorie = 'sport' THEN
        RAISE EXCEPTION 'Une séance de sport ne se relie pas à une tâche : HAL s''en occupe'
              USING ERRCODE = 'check_violation';
    END IF;

    IF p_sorte = 'ensuite' THEN
        IF p_delai_min_heures IS NULL OR p_delai_max_heures IS NULL
           OR p_delai_min_heures < 0 OR p_delai_max_heures <= p_delai_min_heures
           OR p_delai_max_heures > 24 * 14 THEN
            RAISE EXCEPTION 'Le délai va de 0 heure à deux semaines, la fin après le début'
                  USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM enchainement
                    WHERE id_tache_source = p_tache AND id_tache_suivante = p_autre) THEN
            RAISE EXCEPTION '« % » vient déjà après « % »', v_vers.libelle, v_de.libelle
                  USING ERRCODE = 'unique_violation';
        END IF;
        -- TAC-28 : l'autre ne doit pas, de lien en lien, faire naître celle-ci.
        IF EXISTS (
            WITH RECURSIVE suite(id) AS (
                SELECT p_autre
                UNION
                SELECT e.id_tache_suivante FROM enchainement e JOIN suite s ON e.id_tache_source = s.id
            )
            SELECT 1 FROM suite WHERE id = p_tache) THEN
            RAISE EXCEPTION 'Ce lien ferait une boucle : « % » fait déjà naître « % »',
                            v_vers.libelle, v_de.libelle
                  USING ERRCODE = 'check_violation';
        END IF;
        INSERT INTO enchainement (id_tache_source, id_tache_suivante, delai_min_heures, delai_max_heures)
        VALUES (p_tache, p_autre, p_delai_min_heures, p_delai_max_heures)
        RETURNING id_enchainement INTO v_id;

    ELSIF p_sorte = 'meme_jour' THEN
        IF COALESCE(p_place, '') NOT IN ('avant', 'apres') THEN
            RAISE EXCEPTION 'L''autre vient avant ou après' USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM accompagnement WHERE id_tache = p_tache AND id_tache_jointe = p_autre) THEN
            RAISE EXCEPTION '« % » vient déjà le même jour que « % »', v_vers.libelle, v_de.libelle
                  USING ERRCODE = 'unique_violation';
        END IF;
        INSERT INTO accompagnement (id_tache, id_tache_jointe, place, mention)
        VALUES (p_tache, p_autre, p_place,
                -- Ce qu'on lit à côté de l'autre : « avant « Récurer » ».
                COALESCE(NULLIF(btrim(p_mention), ''),
                         left(format('%s « %s »', CASE p_place WHEN 'avant' THEN 'avant' ELSE 'après' END,
                                     v_de.libelle), 60)))
        RETURNING id_accompagnement INTO v_id;

    ELSE
        IF EXISTS (SELECT 1 FROM remplacement WHERE id_tache_faite = p_tache AND id_tache_couverte = p_autre) THEN
            RAISE EXCEPTION '« % » vaut déjà « % »', v_de.libelle, v_vers.libelle
                  USING ERRCODE = 'unique_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM remplacement WHERE id_tache_faite = p_autre AND id_tache_couverte = p_tache) THEN
            RAISE EXCEPTION '« % » vaut déjà « % » : les deux se solderaient l''une l''autre',
                            v_vers.libelle, v_de.libelle
                  USING ERRCODE = 'check_violation';
        END IF;
        INSERT INTO remplacement (id_tache_faite, id_tache_couverte)
        VALUES (p_tache, p_autre)
        RETURNING id_remplacement INTO v_id;
    END IF;

    RETURN v_id;
END $$;

COMMENT ON FUNCTION lier_taches(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, TEXT, TEXT) IS
    'TAC-27, TAC-28 : pose un lien « ensuite », « meme_jour » ou « vaut_aussi »
     entre deux tâches actives, et rend son numéro. Refuse boucles et doublons.';
