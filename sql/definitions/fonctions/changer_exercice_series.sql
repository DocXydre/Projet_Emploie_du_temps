-- -----------------------------------------------------------------------------
-- Les séries suivent l'exercice qu'on change en cours de séance       (SAI-22)
--
-- On s'est trompé d'exercice, ou on change de machine après quelques séries :
-- les séries déjà faites, désignées par la clé que l'appareil leur a donnée,
-- passent à l'exercice choisi. Elles gardent leur ligne prévue, comme un
-- remplacement (SAI-3), et se numérotent à la suite de celles que l'exercice
-- choisi a déjà. Les règles de la saisie s'appliquent comme à une série neuve :
-- un exercice interdit par une limitation, ou qui ne se note pas de la même
-- façon, est refusé (SEC-1, SAI-1), et une série figée ne bouge pas (SAI-8).
-- Rend le nombre de séries déplacées.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION changer_exercice_series(p_utilisateur INTEGER, p_occurrence INTEGER,
                                                   p_cles UUID[], p_exercice INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_deplacees INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM occurrence o
                    WHERE o.id_occurrence = p_occurrence
                      AND o.id_utilisateur = p_utilisateur) THEN
        RAISE EXCEPTION 'Séance introuvable' USING ERRCODE = 'no_data_found';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM exercice e WHERE e.id_exercice = p_exercice) THEN
        PERFORM refus_coach('introuvable', 'Exercice inconnu');
    END IF;

    WITH deja AS (
        SELECT COALESCE(max(ss.numero), 0) AS dernier
          FROM serie_saisie ss
         WHERE ss.id_occurrence = p_occurrence AND ss.id_exercice = p_exercice
           AND NOT (ss.cle_client = ANY (p_cles))
    ), rangees AS (
        SELECT ss.id_serie, row_number() OVER (ORDER BY ss.saisie_le, ss.numero) AS rang
          FROM serie_saisie ss
         WHERE ss.id_occurrence = p_occurrence AND ss.cle_client = ANY (p_cles)
           AND ss.id_exercice <> p_exercice
    )
    UPDATE serie_saisie ss
       SET id_exercice = p_exercice, numero = deja.dernier + rangees.rang
      FROM rangees, deja
     WHERE ss.id_serie = rangees.id_serie;
    GET DIAGNOSTICS v_deplacees = ROW_COUNT;
    RETURN v_deplacees;
END $$;

COMMENT ON FUNCTION changer_exercice_series(INTEGER, INTEGER, UUID[], INTEGER) IS
    'SAI-22 : les séries déjà faites d''un exercice changé en cours de séance
     passent à l''exercice choisi, numérotées à la suite. Les règles de la saisie
     s''appliquent. Rend le nombre de séries déplacées.';
