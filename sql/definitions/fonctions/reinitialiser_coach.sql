-- -----------------------------------------------------------------------------
-- Repartir de zéro avec le coach                                   (DEM-5)
--
-- Efface tout ce que le coach sait et a fait pour un compte : profil,
-- questionnaire, limitations, lieux, objectifs, plans, séances du coach et
-- séances libres avec leurs séries et bilans, ajustements, pause, mesures,
-- mémoire, échanges. Les données de la montre partent aussi, sauf si
-- on demande à les garder.
--
-- Restent : les appels au modèle (le suivi du coût), le compte, sa clé, son lien Telegram, le réglage coach_actif, et
-- tout le reste du planning (cours, travail, ménage, séances posées à la main).
-- Au message suivant, le bot repart sur le démarrage (DEM-1).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reinitialiser_coach(p_utilisateur INTEGER,
                                               p_garder_sante BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_seances INTEGER;
    v_objectifs INTEGER;
    v_echanges INTEGER;
    v_sante INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM utilisateur WHERE id_utilisateur = p_utilisateur) THEN
        PERFORM refus_coach('introuvable', 'Compte inconnu');
    END IF;

    DELETE FROM notification
     WHERE id_utilisateur = p_utilisateur AND (type = 'coach' OR id_echange IS NOT NULL);
    DELETE FROM echange WHERE id_utilisateur = p_utilisateur;
    GET DIAGNOSTICS v_echanges = ROW_COUNT;
    -- Les appels au modèle restent : c'est le suivi du coût (COA-21). Ils ne
    -- pointent plus vers aucun échange.
    DELETE FROM trace_coach WHERE id_utilisateur = p_utilisateur;

    IF NOT p_garder_sante THEN
        DELETE FROM activite_sante WHERE id_utilisateur = p_utilisateur;
        GET DIAGNOSTICS v_sante = ROW_COUNT;
        DELETE FROM sante_jour WHERE id_utilisateur = p_utilisateur;
        DELETE FROM echantillon_sante WHERE id_utilisateur = p_utilisateur;
        DELETE FROM sommeil_phase WHERE id_utilisateur = p_utilisateur;
    END IF;
    DELETE FROM mesure WHERE id_utilisateur = p_utilisateur;
    DELETE FROM fenetre_mesure WHERE id_utilisateur = p_utilisateur;

    -- Les séances du coach et les séances libres, avec leurs exercices, séries,
    -- bilans et ajustements (en cascade). Une séance posée à la main, sans
    -- contenu, est du planning ordinaire : elle reste.
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND (o.origine = 'coach'
            OR EXISTS (SELECT 1 FROM seance s WHERE s.id_occurrence = o.id_occurrence));
    GET DIAGNOSTICS v_seances = ROW_COUNT;

    DELETE FROM plan WHERE id_utilisateur = p_utilisateur;
    DELETE FROM objectif WHERE id_utilisateur = p_utilisateur;
    GET DIAGNOSTICS v_objectifs = ROW_COUNT;
    DELETE FROM pause WHERE id_utilisateur = p_utilisateur;
    DELETE FROM limitation WHERE id_utilisateur = p_utilisateur;
    DELETE FROM discipline_lieu WHERE id_utilisateur = p_utilisateur;
    DELETE FROM depistage WHERE id_utilisateur = p_utilisateur;
    DELETE FROM profil WHERE id_utilisateur = p_utilisateur;
    DELETE FROM note_coach WHERE id_utilisateur = p_utilisateur;
    DELETE FROM memoire_coach WHERE id_utilisateur = p_utilisateur;
    DELETE FROM demarrage_coach WHERE id_utilisateur = p_utilisateur;

    RETURN jsonb_build_object('seances', v_seances, 'objectifs', v_objectifs,
                              'echanges', v_echanges, 'activites_montre', v_sante,
                              'sante_gardee', p_garder_sante);
END $$;

COMMENT ON FUNCTION reinitialiser_coach(INTEGER, BOOLEAN) IS
    'DEM-5 : efface tout ce que le coach sait et a fait pour un compte, pour
     repartir de zéro. Le compte, le planning ordinaire et, au choix, les
     données de la montre restent.';
