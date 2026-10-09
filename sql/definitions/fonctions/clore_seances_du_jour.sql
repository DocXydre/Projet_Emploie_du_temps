-- -----------------------------------------------------------------------------
-- 23 h : une séance du jour est faite ou pas faite                     (PLN-9)
--
-- Sans le modèle, et tous les soirs, pause ou non (PAU-5). Toute séance du
-- jour restée ouverte, validée ou seulement proposée, se juge sur ce qui a été
-- fait : une saisie, un bilan ou une séance de la montre de la même discipline
-- la font compter comme faite. Sinon elle est close comme pas faite : ne pas
-- valider n'excuse pas de ne rien faire. Une séance qui n'est pas finie à
-- cette heure attend le soir suivant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clore_seances_du_jour(p_utilisateur INTEGER,
                                                 p_jour DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    o            RECORD;
    v_jour       DATE := COALESCE(p_jour, jour_de(now()));
    v_faites     INTEGER[] := '{}';
    v_pas_faites INTEGER[] := '{}';
    v_fait       BOOLEAN;
BEGIN
    FOR o IN
        SELECT oc.id_occurrence, se.discipline, oc.debut_seance, se.duree_minutes
          FROM occurrence oc JOIN seance se ON se.id_occurrence = oc.id_occurrence
         WHERE oc.id_utilisateur = p_utilisateur
           AND oc.statut IN ('a_placer', 'planifiee', 'notifiee')
           AND jour_de(COALESCE(oc.debut_seance, lower(oc.fenetre))) <= v_jour
           AND COALESCE(oc.debut_seance, lower(oc.fenetre))
               + make_interval(mins => se.duree_minutes) <= now()
         ORDER BY oc.debut_seance
    LOOP
        v_fait := EXISTS (SELECT 1 FROM serie_saisie ss
                           WHERE ss.id_occurrence = o.id_occurrence)
               OR EXISTS (SELECT 1 FROM bilan_seance b
                           WHERE b.id_occurrence = o.id_occurrence)
               OR EXISTS (SELECT 1 FROM activite_sante a
                           WHERE a.id_occurrence = o.id_occurrence);
        IF v_fait THEN
            UPDATE occurrence SET statut = 'faite',
                   date_faite = LEAST(now(), o.debut_seance
                                              + make_interval(mins => o.duree_minutes))
             WHERE id_occurrence = o.id_occurrence;
            v_faites := v_faites || o.id_occurrence;
        ELSE
            UPDATE occurrence SET statut = 'abandonnee', motif = 'Pas faite'
             WHERE id_occurrence = o.id_occurrence;
            v_pas_faites := v_pas_faites || o.id_occurrence;
        END IF;
        UPDATE ajustement a SET statut = 'caduc'
         WHERE a.id_occurrence = o.id_occurrence AND a.statut = 'propose';
        DELETE FROM notification n
         WHERE n.id_occurrence = o.id_occurrence AND n.statut = 'a_envoyer'
           AND n.type = 'rappel';
    END LOOP;

    RETURN jsonb_build_object('jour', v_jour, 'faites', to_jsonb(v_faites),
                              'pas_faites', to_jsonb(v_pas_faites));
END $$;

COMMENT ON FUNCTION clore_seances_du_jour(INTEGER, DATE) IS
    'PLN-9, PAU-5 : juge faite ou pas faite chaque séance du jour restée
     ouverte, sur ce qui a été saisi ou enregistré par la montre.';
