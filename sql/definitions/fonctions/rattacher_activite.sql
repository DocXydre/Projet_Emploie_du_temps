-- -----------------------------------------------------------------------------
-- Une séance de la montre trouve sa séance prévue              (SAN-4, LIB-5)
--
-- Même compte, même jour, même discipline, séance sans activité déjà
-- rattachée. Faute de séance prévue, elle devient une séance libre, reconnue
-- d'elle-même. Une activité d'une discipline que le module ne couvre pas
-- (natation, vélo dehors) reste sans séance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rattacher_activite(p_activite BIGINT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    a            RECORD;
    v_occurrence INTEGER;
BEGIN
    SELECT ac.*, jour_de(lower(ac.periode)) AS jour INTO a
      FROM activite_sante ac WHERE ac.id_activite = p_activite;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF a.id_occurrence IS NOT NULL OR a.discipline = 'autre' THEN
        RETURN a.id_occurrence;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.id_utilisateur = a.id_utilisateur AND u.coach_actif) THEN
        RETURN NULL;
    END IF;

    SELECT o.id_occurrence INTO v_occurrence
      FROM occurrence o JOIN seance se ON se.id_occurrence = o.id_occurrence
     WHERE o.id_utilisateur = a.id_utilisateur
       AND se.discipline = a.discipline
       AND jour_de(COALESCE(o.debut_seance, lower(o.fenetre))) = a.jour
       AND (o.statut IN ('a_placer', 'planifiee', 'notifiee', 'faite')
            OR (o.statut = 'abandonnee' AND o.motif = 'Pas faite'))
       AND NOT EXISTS (SELECT 1 FROM activite_sante x
                        WHERE x.id_occurrence = o.id_occurrence)
     ORDER BY abs(EXTRACT(EPOCH FROM (COALESCE(o.debut_seance, lower(o.fenetre))
                                      - lower(a.periode))))
     LIMIT 1;

    IF v_occurrence IS NULL THEN
        v_occurrence := creer_seance_libre(
            a.id_utilisateur, a.discipline, lower(a.periode),
            CEIL(a.duree_secondes / 60.0)::INTEGER, NULL, FALSE, NULL, left(a.type, 40));
    END IF;

    UPDATE activite_sante ac SET id_occurrence = v_occurrence
     WHERE ac.id_activite = p_activite;
    PERFORM deduire_intensite(v_occurrence);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION rattacher_activite(BIGINT) IS
    'SAN-4, LIB-5 : rattache une séance de la montre à la séance prévue du même
     jour et de la même discipline. À défaut, crée une séance libre.';
