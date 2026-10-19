CREATE VIEW v_sante_reception AS
SELECT u.id_utilisateur,
       (SELECT count(*) FROM activite_sante a
         WHERE a.id_utilisateur = u.id_utilisateur AND a.doublon_de IS NULL)  AS seances,
       (SELECT count(*) FROM activite_sante a
         WHERE a.id_utilisateur = u.id_utilisateur AND a.doublon_de IS NOT NULL)
                                                                              AS doublons,
       (SELECT min(lower(a.periode)) FROM activite_sante a
         WHERE a.id_utilisateur = u.id_utilisateur)                           AS premiere_seance,
       (SELECT count(DISTINCT s.id_activite) FROM activite_serie s
          JOIN activite_sante a ON a.id_activite = s.id_activite
         WHERE a.id_utilisateur = u.id_utilisateur)                           AS seances_detaillees,
       (SELECT count(DISTINCT g.id_activite) FROM activite_segment g
          JOIN activite_sante a ON a.id_activite = g.id_activite
         WHERE a.id_utilisateur = u.id_utilisateur)                           AS seances_decoupees,
       (SELECT count(DISTINCT t.id_activite) FROM activite_trace t
          JOIN activite_sante a ON a.id_activite = t.id_activite
         WHERE a.id_utilisateur = u.id_utilisateur)                           AS seances_avec_trace,
       (SELECT count(*) FROM echantillon_sante e
         WHERE e.id_utilisateur = u.id_utilisateur)                           AS echantillons,
       (SELECT min(lower(e.periode)) FROM echantillon_sante e
         WHERE e.id_utilisateur = u.id_utilisateur)                           AS premier_echantillon,
       (SELECT count(*) FROM sommeil_phase p
         WHERE p.id_utilisateur = u.id_utilisateur)                           AS phases_sommeil
  FROM utilisateur u
 WHERE u.actif;

COMMENT ON VIEW v_sante_reception IS
    'SAN-11 à SAN-16 : ce que le serveur a reçu de Santé, par compte. Sert à
     l''appli pour suivre l''envoi de l''historique, et à vérifier un envoi.';
