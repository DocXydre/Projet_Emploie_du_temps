-- -----------------------------------------------------------------------------
-- Écrit une version d'un étage de la mémoire du coach        (MEM-2 à MEM-6)
--
-- Une écriture ajoute une version, elle n'écrase rien. Un texte identique à la
-- version en vigueur n'en ajoute pas.
--
-- Le coach n'écrit que la semaine en cours et la mémoire globale (MEM-4) : le
-- mois et ses archives se font par résumé, au roulement. L'utilisateur peut
-- corriger n'importe quel étage.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecrire_memoire(
    p_utilisateur INTEGER,
    p_niveau      TEXT,
    p_texte       TEXT,
    p_auteur      TEXT,
    p_periode     DATE    DEFAULT NULL,
    p_couvre      DATE    DEFAULT NULL,
    p_modele      TEXT    DEFAULT NULL,
    p_entree      INTEGER DEFAULT NULL,
    p_sortie      INTEGER DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_periode DATE;
    v_texte   TEXT := btrim(COALESCE(p_texte, ''));
    v_limite  INTEGER := limite_memoire(p_niveau);
    v_avant   memoire_coach%ROWTYPE;
    v_id      BIGINT;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF v_limite IS NULL THEN
        PERFORM refus_coach('requete_invalide',
            'Les étages de la mémoire sont : globale, archive_mois, mois, semaine');
    END IF;
    IF p_auteur = 'coach' AND p_niveau NOT IN ('semaine', 'globale') THEN
        PERFORM refus_coach('non_autorise',
            'Tu n''écris que la mémoire de la semaine et la mémoire globale. Le mois '
            'et les trois mois se font par résumé, chaque semaine et chaque mois.');
    END IF;
    IF char_length(v_texte) > v_limite THEN
        PERFORM refus_coach('memoire_trop_longue', format(
            'La mémoire %s tient en %s caractères, ce texte en fait %s : résume '
            'davantage, en gardant ce qui est important.',
            p_niveau, v_limite, char_length(v_texte)));
    END IF;

    v_periode := CASE p_niveau
        WHEN 'globale' THEN NULL
        WHEN 'semaine' THEN lundi_de(COALESCE(p_periode, jour_de(now())))
        ELSE date_trunc('month', COALESCE(p_periode, jour_de(now())))::DATE
    END;
    IF p_auteur = 'coach' AND p_niveau = 'semaine'
       AND v_periode <> lundi_de(jour_de(now())) THEN
        PERFORM refus_coach('non_autorise',
            'Tu n''écris que la mémoire de la semaine en cours');
    END IF;

    SELECT * INTO v_avant FROM memoire_coach m
     WHERE m.id_utilisateur = p_utilisateur AND m.niveau = p_niveau
       AND m.periode IS NOT DISTINCT FROM v_periode
     ORDER BY m.id_memoire DESC LIMIT 1;

    IF FOUND AND v_avant.texte = v_texte
       AND v_avant.couvre_jusqu_au IS NOT DISTINCT FROM COALESCE(p_couvre,
                                                                 v_avant.couvre_jusqu_au) THEN
        RETURN v_avant.id_memoire;
    END IF;

    INSERT INTO memoire_coach (id_utilisateur, niveau, periode, texte, auteur,
                               couvre_jusqu_au, modele, tokens_entree, tokens_sortie)
    VALUES (p_utilisateur, p_niveau, v_periode, v_texte, p_auteur,
            COALESCE(p_couvre, v_avant.couvre_jusqu_au), p_modele, p_entree, p_sortie)
    RETURNING id_memoire INTO v_id;

    IF p_auteur = 'coach' THEN
        PERFORM tracer_coach(p_utilisateur, 'memoire', v_id,
                             jsonb_build_object('niveau', p_niveau));
    END IF;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION ecrire_memoire(INTEGER, TEXT, TEXT, TEXT, DATE, DATE, TEXT, INTEGER,
                                   INTEGER) IS
    'MEM-2 à MEM-6 : ajoute une version à un étage de la mémoire du coach. Refuse
     un texte trop long, et refuse au coach les étages qui se font par résumé.';
