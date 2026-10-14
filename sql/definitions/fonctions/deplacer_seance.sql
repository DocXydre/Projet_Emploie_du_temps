-- -----------------------------------------------------------------------------
-- L'utilisateur déplace une séance, ou en change le lieu    (opération C8)
--                                          (PLN-11, PLN-12, LIE-5, SEC-4)
--
-- Le placement se vérifie en mode souple : seuls un cours, un service ou ce
-- qui est déjà annoncé interdisent. La règle des séances dures avertit et
-- laisse faire : l'avertissement est rendu tout de suite, et le coach
-- réajuste la suite à la synthèse. Une séance déplacée garde son contenu, et
-- reste épinglée si elle était validée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION deplacer_seance(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER,
    p_debut       TIMESTAMPTZ DEFAULT NULL,
    p_lieu        INTEGER     DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    s        RECORD;
    r        RECORD;
    v_debut  TIMESTAMPTZ;
    v_lieu   INTEGER;
    v_jour   DATE;
    v_bloc   TSTZRANGE;
    v_raison TEXT;
    v_avertissements JSONB := '[]';
BEGIN
    SELECT se.discipline, se.duree_minutes, se.intensite, se.groupes, se.libre,
           o.statut, o.id_lieu, o.debut_seance
      INTO s
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE se.id_occurrence = p_occurrence AND o.id_utilisateur = p_utilisateur;
    IF NOT FOUND OR s.statut NOT IN ('planifiee', 'notifiee') THEN
        PERFORM refus_coach('introuvable', 'Séance introuvable, ou déjà close');
    END IF;

    v_debut := COALESCE(p_debut, s.debut_seance);
    v_jour  := jour_de(v_debut);
    -- LIE-5 : le lieu se choisit parmi ceux de la discipline.
    v_lieu  := CASE WHEN p_lieu IS NULL THEN s.id_lieu
                    ELSE lieu_de_discipline(p_utilisateur, s.discipline, p_lieu) END;

    v_raison := obstacle_seance_coach(p_utilisateur, v_lieu, v_debut, s.duree_minutes,
                                      s.discipline, p_occurrence, FALSE);
    IF v_raison IS NOT NULL THEN
        PERFORM refus_coach('creneau_pris', v_raison);
    END IF;

    FOR r IN
        SELECT os.code, os.motif
          FROM obstacle_sportif(p_utilisateur, v_debut, s.intensite, s.groupes, NULL,
                                p_occurrence, FALSE) os
    LOOP
        v_avertissements := v_avertissements
            || jsonb_build_object('code', r.code, 'message', r.motif);
    END LOOP;

    v_bloc := bloc_seance_duree(p_utilisateur, v_lieu, v_debut, s.duree_minutes);

    UPDATE occurrence o
       SET creneau = NULL, statut = 'a_placer',
           motif = 'Déplacée par une séance de sport'
     WHERE o.id_utilisateur = p_utilisateur
       AND o.statut = 'planifiee' AND NOT o.epinglee AND NOT o.rappel_journee
       AND o.origine NOT IN ('quota', 'coach')
       AND o.id_occurrence <> p_occurrence
       AND o.creneau && v_bloc;

    UPDATE ajustement a SET statut = 'caduc'
     WHERE a.id_occurrence = p_occurrence AND a.statut = 'propose';

    UPDATE occurrence o
       SET creneau = v_bloc,
           fenetre = tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                               GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
           id_lieu = v_lieu,
           debut_seance = v_debut,
           motif = CASE WHEN jsonb_array_length(v_avertissements) > 0
                        THEN 'Déplacée par l''utilisateur, malgré un avertissement : '
                             || (v_avertissements -> 0 ->> 'message')
                        ELSE 'Déplacée par l''utilisateur' END
     WHERE o.id_occurrence = p_occurrence;

    RETURN jsonb_build_object('id_occurrence', p_occurrence, 'debut', v_debut,
                              'id_lieu', v_lieu, 'avertissements', v_avertissements);
END $$;

COMMENT ON FUNCTION deplacer_seance(INTEGER, INTEGER, TIMESTAMPTZ, INTEGER) IS
    'Opération C8 : l''utilisateur déplace une séance ou en change le lieu.
     Placement souple, séances dures en avertissement. La séance garde son
     contenu (PLN-11, PLN-12, LIE-5, SEC-4).';
