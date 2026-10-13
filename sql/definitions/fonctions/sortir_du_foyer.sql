-- -----------------------------------------------------------------------------
-- Faire sortir un membre du foyer                                 (FOY-5, FOY-7)
--
-- Ses tâches à venir repassent aux autres : celles qui lui étaient données par
-- défaut perdent leur assigné, et ses occurrences encore à faire se replacent.
-- Ce qu'il a fait reste au journal du foyer.
--
-- Le moteur du ménage ne sépare pas encore les foyers : il compte tous les
-- comptes actifs. Le compte qui sort est donc mis en pause. Il garde son
-- planning, son HAL et son historique, et revient en rejoignant un foyer.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sortir_du_foyer(p_membre INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_foyer INTEGER := foyer_de(p_membre);
BEGIN
    IF v_foyer IS NULL THEN
        RAISE EXCEPTION 'Ce compte ne fait partie d''aucun foyer' USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE tache SET id_utilisateur_defaut = NULL WHERE id_utilisateur_defaut = p_membre;

    UPDATE occurrence o
       SET id_utilisateur = NULL, creneau = NULL, statut = 'a_placer', epinglee = FALSE,
           motif = NULL
      FROM tache t
     WHERE t.id_tache = o.id_tache
       AND t.categorie <> 'sport'
       AND o.id_utilisateur = p_membre
       AND o.statut IN ('a_placer', 'planifiee');

    UPDATE utilisateur SET id_foyer = NULL, actif = FALSE WHERE id_utilisateur = p_membre;

    -- Le dernier qui part ferme le foyer : ses tâches s'arrêtent, l'historique reste.
    IF NOT EXISTS (SELECT 1 FROM utilisateur WHERE id_foyer = v_foyer AND actif) THEN
        UPDATE foyer SET ferme_le = now() WHERE id_foyer = v_foyer;
        UPDATE invitation SET annulee_le = now()
         WHERE id_foyer = v_foyer AND servie_le IS NULL AND annulee_le IS NULL;
    ELSE
        PERFORM placer_taches();
    END IF;
END $$;

COMMENT ON FUNCTION sortir_du_foyer(INTEGER) IS
    'FOY-5 : le membre quitte le foyer, ses tâches repassent aux autres, son compte est mis en pause.';
