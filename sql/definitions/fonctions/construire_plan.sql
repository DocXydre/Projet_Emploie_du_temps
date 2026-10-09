-- -----------------------------------------------------------------------------
-- Le coach crée le plan : sa trame et le rôle de ses quatre semaines
--                                  (opération C3 : PLN-1, PLN-2, OBJ-8, PRO-4 à 6)
--
-- Refuse sans profil, sans dépistage valide, sans objectif principal actif,
-- sans aucun lieu, ou pendant une pause. Le plan précédent est clos, et ses
-- séances encore proposées disparaissent : le nouveau plan les remplace. Les
-- séances validées ne sont pas touchées (PLN-7).
--
-- Rend l'identifiant du plan et les disciplines sans lieu, pour que le coach
-- les nomme au lieu de les écarter en silence (LIE-6).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION construire_plan(
    p_utilisateur INTEGER,
    p_lundi       DATE,
    p_trame       TEXT,
    p_roles       TEXT[],
    p_intentions  TEXT[] DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    d           RECORD;
    v_objectif  INTEGER;
    v_plan      INTEGER;
    v_sans_lieu TEXT[];
    v_jour      DATE := jour_de(now());
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF en_pause(p_utilisateur) THEN
        PERFORM refus_coach('coach_en_pause',
                            'Le coach est en pause : aucun plan ne se construit');
    END IF;

    -- PRO-4 : le profil et le dépistage d'abord.
    IF NOT EXISTS (SELECT 1 FROM profil p WHERE p.id_utilisateur = p_utilisateur) THEN
        PERFORM refus_coach('profil_incomplet', 'Le profil n''est pas rempli');
    END IF;

    SELECT dp.positif, dp.avis_medical_le, dp.date_reponse INTO d
      FROM depistage dp
     WHERE dp.id_utilisateur = p_utilisateur
     ORDER BY dp.date_reponse DESC, dp.id_depistage DESC
     LIMIT 1;
    IF NOT FOUND THEN
        PERFORM refus_coach('depistage_requis',
                            'Le questionnaire de dépistage n''a pas été rempli');
    END IF;
    -- PRO-6 : il se refait au bout de douze mois.
    IF d.date_reponse < v_jour - INTERVAL '12 months' THEN
        PERFORM refus_coach('depistage_requis',
            'Le dépistage a plus de douze mois : il est à refaire avant un nouveau plan');
    END IF;
    -- PRO-5 : une seule réponse positive bloque, jusqu'à l'avis médical.
    IF d.positif AND d.avis_medical_le IS NULL THEN
        PERFORM refus_coach('avis_medical_requis',
            'Le dépistage demande un avis médical avant de commencer');
    END IF;

    -- OBJ-8 : pas de plan sans objectif principal actif.
    SELECT o.id_objectif INTO v_objectif
      FROM objectif o
     WHERE o.id_utilisateur = p_utilisateur AND o.principal AND o.statut = 'actif';
    IF v_objectif IS NULL THEN
        PERFORM refus_coach('objectif_requis',
                            'Aucun objectif principal actif : il en faut un pour bâtir un plan');
    END IF;

    IF p_lundi IS NULL OR EXTRACT(ISODOW FROM p_lundi) <> 1
       OR p_lundi NOT IN (lundi_de(v_jour), lundi_de(v_jour) + 7) THEN
        PERFORM refus_coach('requete_invalide',
            format('Un plan commence le lundi de cette semaine (%s) ou le suivant (%s)',
                   lundi_de(v_jour), lundi_de(v_jour) + 7));
    END IF;
    IF COALESCE(cardinality(p_roles), 0) <> 4 THEN
        PERFORM refus_coach('requete_invalide',
                            'Un plan donne un rôle à chacune de ses quatre semaines');
    END IF;
    IF btrim(COALESCE(p_trame, '')) = '' THEN
        PERFORM refus_coach('requete_invalide', 'La trame du plan est vide');
    END IF;

    -- LIE-6 : les disciplines sans lieu sont rendues, pas écartées en silence.
    SELECT COALESCE(array_agg(x.discipline ORDER BY x.discipline), '{}') INTO v_sans_lieu
      FROM unnest(ARRAY['musculation', 'course', 'cardio']) AS x(discipline)
     WHERE NOT EXISTS (SELECT 1 FROM discipline_lieu dl
                        WHERE dl.id_utilisateur = p_utilisateur
                          AND dl.discipline = x.discipline);
    IF cardinality(v_sans_lieu) = 3 THEN
        PERFORM refus_coach('lieu_non_permis',
            'Aucune discipline n''a de lieu : il faut en choisir au moins un');
    END IF;

    -- Le plan précédent est clos. Ses séances proposées à venir s'effacent.
    DELETE FROM occurrence o
     USING seance se, plan p
     WHERE se.id_occurrence = o.id_occurrence
       AND p.id_plan = se.id_plan
       AND p.id_utilisateur = p_utilisateur AND p.statut = 'en_cours'
       AND se.auteur = 'coach' AND se.etat = 'proposee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.debut_seance > now();
    UPDATE plan p SET statut = 'clos'
     WHERE p.id_utilisateur = p_utilisateur AND p.statut = 'en_cours';

    INSERT INTO plan (id_utilisateur, id_objectif, periode, trame)
    VALUES (p_utilisateur, v_objectif, daterange(p_lundi, p_lundi + 28, '[)'), p_trame)
    RETURNING id_plan INTO v_plan;

    INSERT INTO plan_semaine (id_plan, lundi, role, intention)
    SELECT v_plan, p_lundi + 7 * (i - 1), p_roles[i], p_intentions[i]
      FROM generate_series(1, 4) i;

    PERFORM tracer_coach(p_utilisateur, 'plan', v_plan);
    RETURN jsonb_build_object('id_plan', v_plan, 'lundi', p_lundi,
                              'disciplines_sans_lieu', to_jsonb(v_sans_lieu));
END $$;

COMMENT ON FUNCTION construire_plan(INTEGER, DATE, TEXT, TEXT[], TEXT[]) IS
    'Opération C3 : crée le plan de quatre semaines, sa trame et ses rôles.
     Refuse sans profil, dépistage valide, objectif principal ou lieu, et en
     pause (PLN-1, PLN-2, OBJ-8, PRO-4 à PRO-6, LIE-6).';
