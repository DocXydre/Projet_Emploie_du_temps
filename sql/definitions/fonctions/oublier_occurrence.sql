-- -----------------------------------------------------------------------------
-- Oublier une tâche ponctuelle dont la dernière date est passée        (TAC-24)
--
-- Ce n'est pas un retard abandonné (EXE-12) : c'est ce qu'on a demandé à la
-- création. Le message le dit, et ne parle donc pas de jours de retard.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION oublier_occurrence(p_occurrence INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_libelle     TEXT;
    v_utilisateur INTEGER;
BEGIN
    SELECT t.libelle,
           COALESCE(oc.id_utilisateur,
                    t.id_utilisateur_defaut,
                    t.ajoutee_par,
                    (SELECT u.id_utilisateur FROM utilisateur u
                      WHERE u.role = 'admin' AND u.actif
                      ORDER BY u.id_utilisateur LIMIT 1))
      INTO v_libelle, v_utilisateur
      FROM occurrence oc JOIN tache t ON t.id_tache = oc.id_tache
     WHERE oc.id_occurrence = p_occurrence;

    UPDATE occurrence
       SET statut  = 'abandonnee',
           creneau = NULL,
           motif   = 'Pas faite à temps : oubliée, comme demandé'
     WHERE id_occurrence = p_occurrence;

    IF v_utilisateur IS NOT NULL THEN
        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        VALUES (v_utilisateur, p_occurrence, 'alerte',
                format('%s n''a pas été faite à temps : elle est oubliée, comme demandé.',
                       v_libelle));
    END IF;
END $$;

COMMENT ON FUNCTION oublier_occurrence(INTEGER) IS
    'TAC-24 : abandonne une occurrence d''une tâche à oublier dont la fenêtre est
     passée, et prévient la personne à qui elle revenait.';
