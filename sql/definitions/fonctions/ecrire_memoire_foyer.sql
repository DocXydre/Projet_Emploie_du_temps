-- -----------------------------------------------------------------------------
-- Écrire la mémoire du foyer                                            (HDF-4)
--
-- Comme la mémoire de HAL (MEM-2) : une version de plus à un étage, refusée si
-- elle dépasse sa limite. HAL n'écrit que la globale et la semaine en cours ;
-- un membre corrige n'importe quel étage, et sa correction est signée de lui.
-- Une version identique à la précédente n'est pas réécrite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecrire_memoire_foyer(p_foyer     INTEGER,
                                                p_niveau    TEXT,
                                                p_texte     TEXT,
                                                p_auteur    TEXT,
                                                p_id_auteur INTEGER DEFAULT NULL,
                                                p_periode   DATE    DEFAULT NULL,
                                                p_modele    TEXT    DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_texte   TEXT := btrim(COALESCE(p_texte, ''));
    v_limite  INTEGER := limite_memoire(p_niveau);
    v_periode DATE;
    v_avant   memoire_foyer%ROWTYPE;
    v_id      BIGINT;
BEGIN
    IF p_foyer IS NULL OR NOT EXISTS (SELECT 1 FROM foyer
                                       WHERE id_foyer = p_foyer AND ferme_le IS NULL) THEN
        PERFORM refus_coach('introuvable', 'Ce compte ne fait partie d''aucun foyer');
    END IF;
    IF p_niveau NOT IN ('globale', 'mois', 'semaine') THEN
        PERFORM refus_coach('requete_invalide',
            'Les étages de la mémoire du foyer sont : globale, mois, semaine');
    END IF;
    IF p_auteur = 'hal' AND p_niveau NOT IN ('semaine', 'globale') THEN
        PERFORM refus_coach('non_autorise',
            'Tu n''écris que la mémoire de la semaine et la mémoire globale du foyer');
    END IF;
    IF char_length(v_texte) > v_limite THEN
        PERFORM refus_coach('memoire_trop_longue', format(
            'La mémoire %s du foyer tient en %s caractères, ce texte en fait %s : résume '
            'davantage, en gardant ce qui est important.',
            p_niveau, v_limite, char_length(v_texte)));
    END IF;

    v_periode := CASE p_niveau
        WHEN 'globale' THEN NULL
        WHEN 'semaine' THEN lundi_de(COALESCE(p_periode, jour_de(now())))
        ELSE date_trunc('month', COALESCE(p_periode, jour_de(now())))::DATE
    END;
    IF p_auteur = 'hal' AND p_niveau = 'semaine' AND v_periode <> lundi_de(jour_de(now())) THEN
        PERFORM refus_coach('non_autorise', 'Tu n''écris que la mémoire de la semaine en cours');
    END IF;

    SELECT * INTO v_avant FROM memoire_foyer m
     WHERE m.id_foyer = p_foyer AND m.niveau = p_niveau
       AND m.periode IS NOT DISTINCT FROM v_periode
     ORDER BY m.id_memoire DESC LIMIT 1;
    IF FOUND AND v_avant.texte = v_texte THEN
        RETURN v_avant.id_memoire;
    END IF;

    INSERT INTO memoire_foyer (id_foyer, niveau, periode, texte, auteur, id_auteur,
                               couvre_jusqu_au, modele)
    VALUES (p_foyer, p_niveau, v_periode, v_texte, p_auteur,
            CASE WHEN p_auteur = 'utilisateur' THEN p_id_auteur END,
            v_avant.couvre_jusqu_au, p_modele)
    RETURNING id_memoire INTO v_id;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION ecrire_memoire_foyer(INTEGER, TEXT, TEXT, TEXT, INTEGER, DATE, TEXT) IS
    'HDF-4 : ajoute une version à un étage de la mémoire du foyer. Refuse un texte trop long, et à HAL les étages qu''il n''écrit pas.';
