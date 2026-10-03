-- -----------------------------------------------------------------------------
-- Vue : ce qui demande une correction                                     (BIL-8)
--
-- Un courriel qu'on n'a pas su lire n'est pas une erreur à effacer, c'est la
-- seule information disponible sur un format qui a changé. On le remonte.
-- -----------------------------------------------------------------------------
CREATE VIEW v_courriel_a_revoir AS
SELECT c.id_courriel,
       c.identifiant,
       c.expediteur,
       c.sujet,
       c.recu_le,
       c.statut,
       c.motif
  FROM courriel c
 WHERE c.statut IN ('illisible', 'refuse')
 ORDER BY c.traite_le DESC;
