CREATE OR REPLACE FUNCTION abandonner_occurrence(p_occurrence INTEGER,
                                                 p_jours INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_libelle      TEXT;
    v_utilisateur  INTEGER;
BEGIN
    SELECT t.libelle,
           COALESCE(oc.id_utilisateur,
                    t.id_utilisateur_defaut,
                    (SELECT u.id_utilisateur FROM utilisateur u
                      WHERE u.role = 'admin' AND u.actif
                      ORDER BY u.id_utilisateur LIMIT 1))
      INTO v_libelle, v_utilisateur
      FROM occurrence oc JOIN tache t ON t.id_tache = oc.id_tache
     WHERE oc.id_occurrence = p_occurrence;

    UPDATE occurrence
       SET statut  = 'abandonnee',
           creneau = NULL,
           motif   = format('Oubliée après %s jour(s) de retard', p_jours)
     WHERE id_occurrence = p_occurrence;

    -- Sans aucun compte actif, il n'y a personne à prévenir : l'abandon, lui,
    -- doit quand même avoir lieu.
    IF v_utilisateur IS NOT NULL THEN
        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        VALUES (v_utilisateur, p_occurrence, 'alerte',
                format('%s abandonnée : %s jour(s) de retard. La prochaine '
                       'occurrence suivra son cours.', v_libelle, p_jours));
    END IF;
END $$;
